import { chromium } from 'playwright';
const browser = await chromium.launch({ headless: true, proxy: { server: 'http://198.19.0.1:3128' }, args: ['--ignore-certificate-errors'] });
const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
const page = await ctx.newPage();
try { const r = await page.goto('https://example.com', { timeout: 20000 }); console.log('ignore-cert -> status:', r.status(), '| title:', await page.title(), '| NETWORK OK'); }
catch (e) { console.log('ignore-cert FAILED:', e.message.split('\n')[0]); }
await browser.close();
