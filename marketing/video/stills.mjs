// Half-size JPEG stills of any film, with page errors printed: node stills.mjs sprint.html stills 4 12.5 30
import { chromium } from 'playwright';
import path from 'node:path';
import fs from 'node:fs/promises';
const [film, dir, ...ts] = process.argv.slice(2);
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
page.on('pageerror', e => console.log('PAGE ERROR', e.message));
page.on('console', m => { if (m.type() === 'error') console.log('CONSOLE', m.text()); });
await page.goto('file://' + path.resolve(film) + '?static');
await page.evaluate(() => window.ready);
await fs.mkdir(dir, { recursive: true });
for (const t of ts) {
  const t0 = Date.now();
  try { await page.evaluate(t => window.render(t), Number(t)); } catch (e) { console.log('ERR at', t, e.message.split('\n')[0]); continue; }
  await page.locator('canvas').screenshot({ type: 'jpeg', quality: 80, path: path.join(dir, `t${t}.jpg`), scale: 'css' });
  console.log(t, Date.now() - t0, 'ms');
}
await browser.close();
