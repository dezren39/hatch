import { chromium } from 'playwright';
const browser = await chromium.launch({ headless: true, proxy: { server: 'http://127.0.0.1:18080' } });
const page = await browser.newPage();
try { await page.goto('https://example.com', { timeout: 12000 }); console.log('unexpected success'); }
catch (e) { console.log('goto error:', e.message.split('\n')[0]); }
await browser.close();
