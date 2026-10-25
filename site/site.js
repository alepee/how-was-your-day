const themeButton = document.querySelector('#theme');
function setTheme(theme) {
  document.documentElement.dataset.theme = theme;
  const next = theme === 'dark' ? 'light' : 'dark';
  themeButton.textContent = `${next === 'light' ? 'Light' : 'Dark'} mode`;
  themeButton.setAttribute('aria-label', `Switch to ${next} theme`);
  document.querySelector('#app-shot').src = `assets/transcript-${theme}.png`;
  document.querySelector('meta[name="theme-color"]').content = theme === 'dark' ? '#1b2025' : '#f4f6f3';
}
const systemTheme = window.matchMedia('(prefers-color-scheme: light)');
let manualTheme = false;
setTheme(systemTheme.matches ? 'light' : 'dark');
systemTheme.addEventListener('change', event => { if (!manualTheme) setTheme(event.matches ? 'light' : 'dark'); });
themeButton.addEventListener('click', () => {
  manualTheme = true;
  setTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark');
});
document.querySelector('#copy').addEventListener('click', async () => {
  const status = document.querySelector('#copy-status');
  try {
    await navigator.clipboard.writeText(document.querySelector('#brew-command').textContent);
    status.textContent = 'Copied. Paste it into Terminal.';
  } catch {
    status.textContent = 'Select the command above and copy it manually.';
  }
});
