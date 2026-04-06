const profileInput  = document.getElementById('profile-name');
const tokenInput    = document.getElementById('auth-token');
const profilesList  = document.getElementById('profiles-list');
const fetchBtn      = document.getElementById('fetch-profiles');
const status        = document.getElementById('status');

async function fetchProfiles(token) {
  if (!token) return;
  try {
    const res = await fetch('http://localhost:9876/profiles', {
      headers: { 'X-AltTabSucks-Token': token }
    });
    if (!res.ok) return;
    const profiles = await res.json();
    profilesList.innerHTML = '';
    for (const p of profiles) {
      const opt = document.createElement('option');
      opt.value = p;
      profilesList.appendChild(opt);
    }
    // Pre-select the first profile if the field is still empty
    if (profiles.length > 0 && !profileInput.value)
      profileInput.value = profiles[0];
  } catch {
    // server not running — user can still type the profile name manually
  }
}

chrome.storage.local.get(['profileName', 'authToken'], ({ profileName, authToken }) => {
  profileInput.value = profileName ?? '';
  tokenInput.value   = authToken  ?? '';
  fetchProfiles(authToken);
});

fetchBtn.addEventListener('click', () => fetchProfiles(tokenInput.value.trim()));

document.getElementById('save').addEventListener('click', () => {
  const name  = profileInput.value.trim();
  const token = tokenInput.value.trim();
  if (!name) return;
  chrome.storage.local.set({ profileName: name, authToken: token }, () => {
    status.textContent = 'Saved.';
    setTimeout(() => status.textContent = '', 2000);
  });
});
