const SERVER = 'http://localhost:9876/tabs';

// Tracks the most recent splitTab for each profile: { [profileName]: { sourceWindowId,
// splitWindowId } }. Lets mergeTabs always rejoin into the actual window a tab was split *from*,
// instead of the old "whichever other window enumerates first" heuristic — which picked an
// effectively arbitrary window once a profile had more than two open (and even with exactly two,
// happened to be the source only by construction, not by design). Lives only in this service
// worker's in-memory state — if the browser restarts, or MV3 kills+respawns the worker outside of
// keepAlive()'s window, the relationship is simply forgotten and mergeTabs falls back to the
// pre-existing "one other window" heuristic below, same behavior as before this feature existed.
let splitRelations = {};

// --- URL redirect rules (tabs.onUpdated — no extra permissions needed) ---

async function applyRedirectRules(tabId, url) {
  const { redirectRules = [] } = await chrome.storage.local.get('redirectRules');
  if (!redirectRules.length) return;
  let parsed;
  try { parsed = new URL(url); } catch { return; }
  const hostname = parsed.hostname.replace(/^www\./, '');
  const rule = redirectRules.find(r => r.from === hostname);
  if (rule) chrome.tabs.update(tabId, { url: rule.to });
}

async function postTabs() {
  const { profileName = 'Default', authToken = '' } = await chrome.storage.local.get(['profileName', 'authToken']);

  const [tabs, windows] = await Promise.all([
    chrome.tabs.query({}),
    chrome.windows.getAll()
  ]);

  const data = {
    profile: profileName,
    windows: windows.map(w => ({
      id: w.id,
      focused: w.focused,
      tabs: tabs
        .filter(t => t.windowId === w.id)
        .map(t => ({
          id: t.id,
          url: (() => { const raw = t.pendingUrl || t.url; try { const u = new URL(raw); const seg = u.pathname.split('/')[1]; return u.origin + (seg ? '/' + seg : ''); } catch { return raw; } })(),
          // The full address too: `url` above is cut down to what tab-focus hotkeys match on, the
          // tab search popup matches the whole thing.
          fullUrl: t.pendingUrl || t.url,
          title: t.title,
          active: t.active,
          lastAccessed: t.lastAccessed || 0,  // ms since epoch; orders tab search most-recent-first
          pinned: t.pinned,
          index: t.index,
          audible: t.audible ?? false,
          micActive: false  // Chrome API doesn't expose microphone usage; audible is used as proxy
        }))
    }))
  };

  try {
    await fetch(SERVER, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-AltTabSucks-Token': authToken },
      body: JSON.stringify(data)
    });
  } catch {
    // server not running, will retry on next tab event
  }
}

// Coalesces bursts of tab events (e.g. a page whose title keeps changing) into one POST /tabs.
let postTabsTimer = null;
function postTabsSoon() {
  clearTimeout(postTabsTimer);
  postTabsTimer = setTimeout(postTabs, 300);
}

// --- Tab search data: recently closed tabs and a bookmark snapshot -----------------------------
// Pushed to the server whenever they change, and saved there, so the tab search popup can still
// offer them while the browser is closed. While it's open, bookmark searches go to the browser
// itself at query time (searchBookmarks below); the snapshot is only the fallback.

async function serverPost(path, body) {
  const { authToken = '' } = await chrome.storage.local.get('authToken');
  await fetch(`http://localhost:9876${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-AltTabSucks-Token': authToken },
    body: JSON.stringify(body)
  });
}

const openable = (url) => /^https?:\/\//i.test(url || '');

async function postRecentlyClosed() {
  if (!chrome.sessions) return;
  const { profileName = 'Default' } = await chrome.storage.local.get('profileName');
  try {
    const entries = await chrome.sessions.getRecentlyClosed({ maxResults: 25 });
    const items = [];
    for (const e of entries) {
      // A closed window restores as a whole; list it once, under its first openable tab.
      const tab = e.tab || (e.window && (e.window.tabs || []).find(t => openable(t.url)));
      if (!tab || !openable(tab.url)) continue;
      const extra = e.window && e.window.tabs.length > 1 ? ` (+${e.window.tabs.length - 1} tabs)` : '';
      items.push({
        sessionId: (e.tab || e.window).sessionId,
        title: (tab.title || tab.url) + extra,
        url: tab.url,
        closedAt: (e.lastModified || 0) * 1000,  // seconds -> ms
      });
    }
    await serverPost('/recently-closed', { profile: profileName, items });
  } catch {}
}

function flattenBookmarks(nodes, out) {
  for (const n of nodes) {
    if (n.url && openable(n.url)) out.push({ id: n.id, title: n.title || n.url, url: n.url });
    if (n.children) flattenBookmarks(n.children, out);
  }
  return out;
}

async function postBookmarks() {
  if (!chrome.bookmarks) return;
  const { profileName = 'Default' } = await chrome.storage.local.get('profileName');
  try {
    const items = flattenBookmarks(await chrome.bookmarks.getTree(), []);
    await serverPost('/bookmarks', { profile: profileName, items });
  } catch {}
}
let postBookmarksTimer = null;
function postBookmarksSoon() {
  clearTimeout(postBookmarksTimer);
  postBookmarksTimer = setTimeout(postBookmarks, 2000);
}

// True while the server is unreachable — so the first successful poll after a restart re-pushes
// the full tab state right away instead of waiting for the next tab event or keepAlive (20s).
let serverDown = false;

async function pollSwitchQueue() {
  const { profileName = 'Default', authToken = '' } = await chrome.storage.local.get(['profileName', 'authToken']);
  try {
    const res = await fetch(`http://localhost:9876/switchtab?profile=${encodeURIComponent(profileName)}`, {
      headers: { 'X-AltTabSucks-Token': authToken }
    });
    if (serverDown) { serverDown = false; postTabs(); postRecentlyClosed(); postBookmarks(); }
    if (res.status === 200) {
      const cmd = await res.json();
      if (cmd && cmd.openUrl && /^https?:\/\//i.test(cmd.openUrl)) {
        try {
          const u = new URL(cmd.openUrl);
          const seg = u.pathname.split('/')[1];
          const normalized = u.origin + (seg ? '/' + seg : '');
          const allTabs = await chrome.tabs.query({});
          const existing = allTabs.find(t => {
            const raw = t.pendingUrl || t.url;
            try {
              const tu = new URL(raw);
              const tseg = tu.pathname.split('/')[1];
              return tu.origin + (tseg ? '/' + tseg : '') === normalized;
            } catch { return false; }
          });
          if (existing) {
            await chrome.tabs.update(existing.id, { active: true });
            if (chrome.windows) await chrome.windows.update(existing.windowId, { focused: true });
          } else {
            await chrome.tabs.create({ url: cmd.openUrl });
          }
        } catch {
          await chrome.tabs.create({ url: cmd.openUrl });
        }
      } else if (cmd && cmd.mergeTabs) {
        try {
          const { profileName: mergeProfile = 'Default' } = await chrome.storage.local.get('profileName');
          const allTabs = await chrome.tabs.query({});
          const windowIds = [...new Set(allTabs.map(t => t.windowId))];
          if (windowIds.length < 2) return;
          const [focusedTab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
          if (!focusedTab) return;
          const focusedWindowId = focusedTab.windowId;

          // Prefer the tracked split relationship over the "one other window" fallback — if the
          // focused window is still one half of a still-open split pair, always collapse INTO the
          // recorded source, regardless of which half is currently focused (so hitting merge from
          // either the split-off window or after flipping back to the original both rejoin the
          // same, correct pair, instead of whatever window happens to be first in windowIds).
          const rel = splitRelations[mergeProfile];
          const relStillOpen = rel && windowIds.includes(rel.sourceWindowId) && windowIds.includes(rel.splitWindowId);
          let sourceWindowId, targetWindowId;
          if (relStillOpen && (focusedWindowId === rel.sourceWindowId || focusedWindowId === rel.splitWindowId)) {
            // Direction is fixed by the tracked pair alone, never by which half happens to be
            // focused right now — tabs always move split -> source. (An earlier version of this
            // branch made sourceWindowId depend on focusedWindowId too, which meant hitting merge
            // while focused on the split-off window computed sourceWindowId === targetWindowId —
            // both rel.sourceWindowId — a silent self-merge no-op that left the split window
            // completely untouched. Confirmed live: focus and the "maximize" call both moved to
            // the source window as expected, but the split-off window's tab never actually moved.)
            targetWindowId = rel.sourceWindowId;
            sourceWindowId = rel.splitWindowId;
          } else {
            sourceWindowId = focusedWindowId;
            targetWindowId = windowIds.find(id => id !== sourceWindowId);
          }
          if (!targetWindowId) return;

          const tabsToMove = allTabs
            .filter(t => t.windowId === sourceWindowId)
            .sort((a, b) => a.index - b.index);
          // Only the moved window's own active tab should end up active in the target — if merge
          // was triggered from the source side (sourceWindowId !== focusedWindowId), the source's
          // active tab still needs finding since focusedTab belongs to the target instead.
          const sourceActiveTab = focusedWindowId === sourceWindowId
              ? focusedTab
              : allTabs.find(t => t.windowId === sourceWindowId && t.active);
          for (const tab of tabsToMove) {
            await chrome.tabs.move(tab.id, { windowId: targetWindowId, index: -1 });
          }
          if (sourceActiveTab) await chrome.tabs.update(sourceActiveTab.id, { active: true });
          if (chrome.windows) await chrome.windows.update(targetWindowId, { focused: true, state: 'maximized' });
          delete splitRelations[mergeProfile];
        } catch {}
      } else if (cmd && cmd.splitTab) {
        try {
          const { profileName: splitProfile = 'Default' } = await chrome.storage.local.get('profileName');
          const [activeTab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
          if (activeTab) {
            if (chrome.windows) {
              const sourceWindowId = activeTab.windowId;
              const newWindow = await chrome.windows.create({ tabId: activeTab.id });
              splitRelations[splitProfile] = { sourceWindowId, splitWindowId: newWindow.id };
            } else {
              await chrome.tabs.move(activeTab.id, { windowId: -1, index: -1 });
            }
          }
        } catch {}
      } else if (cmd && typeof cmd.searchBookmarks === 'string' && chrome.bookmarks) {
        // The tab search popup's query-time bookmark search; the server waits for the reply.
        try {
          const found = (await chrome.bookmarks.search(cmd.searchBookmarks))
            .filter(n => openable(n.url)).slice(0, 50)
            .map(n => ({ id: n.id, title: n.title || n.url, url: n.url }));
          await serverPost('/bookmark-results', { requestId: cmd.requestId, profile: profileName, items: found });
        } catch {}
      } else if (cmd && typeof cmd.restoreSession === 'string' && chrome.sessions) {
        try {
          const restored = await chrome.sessions.restore(cmd.restoreSession);
          const winId = restored && (restored.window ? restored.window.id : restored.tab && restored.tab.windowId);
          if (winId && chrome.windows) await chrome.windows.update(winId, { focused: true });
        } catch {}
      } else if (cmd && openable(cmd.newTabUrl)) {
        // Always a new tab (a bookmark), unlike openUrl above, which reuses a same-site tab.
        try {
          const tab = await chrome.tabs.create({ url: cmd.newTabUrl });
          if (chrome.windows) await chrome.windows.update(tab.windowId, { focused: true });
        } catch {}
      } else if (cmd && Array.isArray(cmd.closeTabs)) {
        // Every tab closed from the tab search popup since the last poll (Ctrl+W).
        const ids = cmd.closeTabs.filter(id => Number.isInteger(id) && id > 0);
        try { if (ids.length) await chrome.tabs.remove(ids); } catch {
          for (const id of ids) { try { await chrome.tabs.remove(id); } catch {} }  // one already gone
        }
      } else if (cmd &&
          Number.isInteger(cmd.tabId)    && cmd.tabId    > 0 &&
          Number.isInteger(cmd.windowId) && cmd.windowId > 0) {
        await chrome.tabs.update(cmd.tabId, { active: true });
        if (chrome.windows) await chrome.windows.update(cmd.windowId, { focused: true });
      }
    }
  } catch {
    // server not running
    serverDown = true;
  }
}

setInterval(pollSwitchQueue, 50);

// Keep service worker alive between tab events so pollSwitchQueue keeps running.
// Without this, Chrome suspends the worker and setInterval stops firing.
function keepAlive() {
  chrome.runtime.getPlatformInfo(() => {
    postTabs();
    setTimeout(keepAlive, 20000);
  });
}
keepAlive();

postTabs();
postRecentlyClosed();
postBookmarks();

if (chrome.sessions) chrome.sessions.onChanged.addListener(postRecentlyClosed);
if (chrome.bookmarks) {
  for (const ev of ['onCreated', 'onRemoved', 'onChanged', 'onMoved', 'onImportEnded']) {
    if (chrome.bookmarks[ev]) chrome.bookmarks[ev].addListener(postBookmarksSoon);
  }
}

chrome.tabs.onCreated.addListener(postTabs);
chrome.tabs.onRemoved.addListener(postTabs);
chrome.tabs.onMoved.addListener(postTabs);
chrome.tabs.onActivated.addListener(postTabs);
chrome.tabs.onAttached.addListener(postTabs);
chrome.tabs.onDetached.addListener(postTabs);
chrome.windows.onCreated.addListener(postTabs);
chrome.windows.onRemoved.addListener(postTabs);
chrome.windows.onFocusChanged.addListener(postTabs);
// Drop any tracked split relationship that references a window that's gone — closing either half
// of a split pair (source or split-off) makes that pair meaningless; leaving it in place would let
// a later, unrelated mergeTabs for the same profile wrongly treat some future window as "the
// source" via a stale id match.
chrome.windows.onRemoved.addListener((closedWindowId) => {
  for (const profile in splitRelations) {
    const rel = splitRelations[profile];
    if (rel.sourceWindowId === closedWindowId || rel.splitWindowId === closedWindowId) {
      delete splitRelations[profile];
    }
  }
});
// Re-post when an active tab's title changes so the server never holds a stale
// title that fails to match the window (e.g. Gmail unread count updating while idle).
// Also re-post on any URL change so a loading tab is findable before its title arrives,
// preventing a second hotkey press from opening a duplicate.
chrome.webNavigation.onBeforeNavigate.addListener(({ tabId, url, frameId }) => {
  if (frameId === 0) applyRedirectRules(tabId, url);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.url || (changeInfo.title && tab.active)) postTabs();
  // Any tab's title, not just the active one's: the tab search popup matches on every title.
  else if (changeInfo.title) postTabsSoon();
});

