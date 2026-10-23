async function render() {
  const { authToken = '' } = await chrome.storage.local.get('authToken');

  const status = document.getElementById('status');
  try {
    const r = await fetch('http://localhost:9876/tabs', { headers: { 'X-AltTabSucks-Token': authToken } });
    status.textContent = r.ok ? 'server: connected' : `server: error (${r.status})`;
    status.className = r.ok ? 'ok' : 'err';
  } catch {
    status.textContent = 'server: not running';
    status.className = 'err';
  }

  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (!tab) return;

  document.getElementById('tab-title').textContent =
    (tab.title ?? '').slice(0, 30) || '(no title)';
}

// The Hotkeys config page (served by the AltTabSucks server): switch to it if it's already open,
// otherwise open it in a new tab.
document.getElementById('hotkeys-page').addEventListener('click', async (e) => {
  e.preventDefault();
  const url = e.currentTarget.href;
  const tabs = await chrome.tabs.query({});
  const open = tabs.find(t => (t.url || t.pendingUrl || '').startsWith(url));
  if (open) {
    await chrome.tabs.update(open.id, { active: true });
    if (chrome.windows) await chrome.windows.update(open.windowId, { focused: true });
  } else {
    await chrome.tabs.create({ url });
  }
  window.close();
});

render();
