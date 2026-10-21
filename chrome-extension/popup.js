/* Purpose: Open the Lanvi receiver dashboard and expose local bridge status. Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294 */
'use strict';
const CONTROL = 'http://127.0.0.1:8788';
const statusEl = document.getElementById('bridgeStatus');
const detailEl = document.getElementById('bridgeDetail');
const dotEl = document.getElementById('statusDot');
const brandDot = document.querySelector('.brand-status-dot');

document.getElementById('openDashboard').addEventListener('click', async () => {
  const button = document.getElementById('openDashboard');
  button.disabled = true;
  button.style.opacity = '.8';
  try {
    await chrome.tabs.create({ url: chrome.runtime.getURL('dashboard.html') });
    window.close();
  } catch (error) {
    button.disabled = false;
    button.style.opacity = '';
    statusEl.textContent = 'Could not open the dashboard';
    detailEl.textContent = error.message || 'Try opening dashboard.html from the extension details page.';
  }
});

(async () => {
  try {
    const response = await fetch(`${CONTROL}/api/status`, { cache: 'no-store' });
    if (!response.ok) throw new Error(`Bridge returned HTTP ${response.status}`);
    const status = await response.json();
    statusEl.textContent = 'PC bridge is online';
    detailEl.textContent = `${status.addresses.length} local network address${status.addresses.length === 1 ? '' : 'es'} available. Open the dashboard to pair your phone.`;
    dotEl.classList.add('online');
    brandDot.classList.add('online');
  } catch {
    statusEl.textContent = 'PC bridge is offline';
    detailEl.textContent = 'Start pc-bridge/bridge.js, then reopen this popup.';
    dotEl.classList.add('offline');
    brandDot.classList.add('offline');
  }
})();
