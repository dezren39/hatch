import { chromium } from 'playwright';
const browser = await chromium.launch({ headless: true, proxy: { server: 'http://127.0.0.1:18081' } });
const page = await browser.newPage();
const r = await page.goto('https://example.com', { timeout: 25000 });
console.log('via loopback relay -> status:', r.status(), '| title:', await page.title(), '| NETWORK OK');
await page.screenshot({ path: '/home/hatch/workspace/library-build/playwright-test/example-com.png' });
console.log('screenshot saved');
await browser.close();
