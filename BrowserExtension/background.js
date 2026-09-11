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
          title: t.title,
          active: t.active,
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

async function pollSwitchQueue() {
  const { profileName = 'Default', authToken = '' } = await chrome.storage.local.get(['profileName', 'authToken']);
  try {
    const res = await fetch(`http://localhost:9876/switchtab?profile=${encodeURIComponent(profileName)}`, {
      headers: { 'X-AltTabSucks-Token': authToken }
    });
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
      } else if (cmd &&
          Number.isInteger(cmd.tabId)    && cmd.tabId    > 0 &&
          Number.isInteger(cmd.windowId) && cmd.windowId > 0) {
        await chrome.tabs.update(cmd.tabId, { active: true });
        if (chrome.windows) await chrome.windows.update(cmd.windowId, { focused: true });
      }
    }
  } catch {
    // server not running
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
});

