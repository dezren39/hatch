import { chromium } from 'playwright';
const browser = await chromium.launch({ headless: true, proxy: { server: 'http://198.19.0.1:3128' }, args: ['--net-log=/home/hatch/tmp/netlog.json', '--log-level=0'] });
const page = await browser.newPage();
try { const r = await page.goto('https://example.com', { timeout: 20000 }); console.log('OK', r.status(), await page.title()); }
catch (e) { console.log('FAILED:', e.message.split('\n')[0]); }
await browser.close();
