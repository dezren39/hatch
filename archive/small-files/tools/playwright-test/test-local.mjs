import { chromium } from 'playwright';
const browser = await chromium.launch({ headless: true });
console.log('browser version:', browser.version());
const page = await browser.newPage();
await page.goto('data:text/html,<title>Local Test Page</title><h1>Hello from headless chromium</h1>');
console.log('title:', await page.title());
console.log('h1 text:', await page.textContent('h1'));
await browser.close();
console.log('LOCAL TEST OK');
