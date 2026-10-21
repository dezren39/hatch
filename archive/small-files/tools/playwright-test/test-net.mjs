import { chromium } from 'playwright';
const mode = process.argv[2];
const opts = { headless: true };
if (mode === 'session-proxy') opts.proxy = { server: process.env.HTTPS_PROXY };
if (mode === 'plain-proxy') opts.proxy = { server: 'http://hatch-egress-proxy:3128' };
const browser = await chromium.launch(opts);
const page = await browser.newPage();
try {
  const resp = await page.goto('https://example.com', { timeout: 30000 });
  console.log(mode, '-> status:', resp.status(), '| title:', await page.title());
  console.log(mode, 'NETWORK OK');
} catch (e) {
  console.log(mode, 'NETWORK FAILED:', e.message.split('\n')[0]);
}
await browser.close();
