import { chromium } from 'playwright';
const server = process.argv[2];
const browser = await chromium.launch({ headless: true, proxy: { server } });
const page = await browser.newPage();
try {
  const resp = await page.goto('https://example.com', { timeout: 25000 });
  console.log(server, '-> status:', resp.status(), '| title:', await page.title(), '| NETWORK OK');
} catch (e) { console.log(server, 'FAILED:', e.message.split('\n')[0]); }
await browser.close();
