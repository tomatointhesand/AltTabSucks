const SERVER = 'http://localhost:9876/tabs';

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
          const allTabs = await chrome.tabs.query({});
          const windowIds = [...new Set(allTabs.map(t => t.windowId))];
          if (windowIds.length < 2) return;
          const [focusedTab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
          if (!focusedTab) return;
          const sourceWindowId = focusedTab.windowId;
          const targetWindowId = windowIds.find(id => id !== sourceWindowId);
          if (!targetWindowId) return;
          const tabsToMove = allTabs
            .filter(t => t.windowId === sourceWindowId)
            .sort((a, b) => a.index - b.index);
          const activeTabId = focusedTab.id;
          for (const tab of tabsToMove) {
            await chrome.tabs.move(tab.id, { windowId: targetWindowId, index: -1 });
          }
          await chrome.tabs.update(activeTabId, { active: true });
          if (chrome.windows) await chrome.windows.update(targetWindowId, { focused: true, state: 'maximized' });
        } catch {}
      } else if (cmd && cmd.splitTab) {
        try {
          const [activeTab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
          if (activeTab) {
            if (chrome.windows) {
              await chrome.windows.create({ tabId: activeTab.id });
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

