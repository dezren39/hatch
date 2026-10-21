import { chromium, request } from 'playwright';
// A) plain HTTP page through proxy (absolute-form GET, no CONNECT)
{
  const browser = await chromium.launch({ headless: true, proxy: { server: 'http://hatch-egress-proxy:3128' } });
  const page = await browser.newPage();
  try { const r = await page.goto('http://example.com', { timeout: 20000 }); console.log('A http-via-proxy ->', r.status(), await page.title()); }
  catch (e) { console.log('A http-via-proxy FAILED:', e.message.split('\n')[0]); }
  await browser.close();
}
// B) Node-side request context through same proxy (no browser net stack)
{
  const ctx = await request.newContext({ proxy: { server: 'http://hatch-egress-proxy:3128' } });
  try { const r = await ctx.get('https://example.com', { timeout: 20000 }); console.log('B node-request-via-proxy ->', r.status()); }
  catch (e) { console.log('B node-request FAILED:', String(e).split('\n')[0]); }
  await ctx.dispose();
}
