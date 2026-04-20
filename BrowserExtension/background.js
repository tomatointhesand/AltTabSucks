const SERVER = 'http://localhost:9876/tabs';

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
          url: (() => { try { const u = new URL(t.url); const seg = u.pathname.split('/')[1]; return u.origin + (seg ? '/' + seg : ''); } catch { return t.url; } })(),
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
        await chrome.tabs.create({ url: cmd.openUrl });
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
  chrome.runtime.getPlatformInfo(() => setTimeout(keepAlive, 20000));
}
keepAlive();

postTabs();

chrome.tabs.onCreated.addListener(postTabs);
chrome.tabs.onRemoved.addListener(postTabs);
chrome.tabs.onMoved.addListener(postTabs);
chrome.tabs.onAttached.addListener(postTabs);
chrome.tabs.onDetached.addListener(postTabs);
chrome.windows.onCreated.addListener(postTabs);
chrome.windows.onRemoved.addListener(postTabs);
chrome.windows.onFocusChanged.addListener(postTabs);
// Re-post when an active tab's title changes so the server never holds a stale
// title that fails to match the window (e.g. Gmail unread count updating while idle).
// Also re-post on any URL change so a loading tab is findable before its title arrives,
// preventing a second hotkey press from opening a duplicate.
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.url || (changeInfo.title && tab.active)) postTabs();
});

