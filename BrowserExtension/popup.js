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

render();
