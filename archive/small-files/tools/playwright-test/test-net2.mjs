import { chromium } from 'playwright';
const mode = process.argv[2];
const opts = { headless: true };
if (mode === 'arg-plain') opts.args = ['--proxy-server=http://hatch-egress-proxy:3128'];
if (mode === 'opt-plain') opts.proxy = { server: 'http://hatch-egress-proxy:3128' };
if (mode === 'opt-session-parsed') {
  const u = new URL(process.env.HTTPS_PROXY);
  opts.proxy = { server: `${u.protocol}//${u.host}`, username: decodeURIComponent(u.username), password: decodeURIComponent(u.password) };
}
const browser = await chromium.launch(opts);
const page = await browser.newPage();
try {
  const resp = await page.goto('https://example.com', { timeout: 25000 });
  console.log(mode, '-> status:', resp.status(), '| title:', await page.title(), '| NETWORK OK');
} catch (e) { console.log(mode, 'FAILED:', e.message.split('\n')[0]); }
await browser.close();
