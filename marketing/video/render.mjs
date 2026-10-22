// Render video.html to frames piped into ffmpeg, or to stills.
//   node render.mjs out.mp4 [fps] [from to] the whole film, or frames [from, to) (silent; mux the music in afterwards)
//   node render.mjs --stills dir t1 t2 ...  PNG stills at those seconds
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
await page.goto('file://' + path.join(here, 'video.html') + '?static');
await page.evaluate(() => window.ready);
const shot = async t => {
  await page.evaluate(t => window.render(t), t);
  return page.locator('canvas').screenshot({ type: 'png' });
};

const args = process.argv.slice(2);
if (args[0] === '--stills') {
  const fs = await import('node:fs/promises');
  await fs.mkdir(args[1], { recursive: true });
  for (const t of args.slice(2)) await fs.writeFile(path.join(args[1], `t${t}.png`), await shot(Number(t)));
} else {
  const out = args[0], fps = Number(args[1] || 30);
  const duration = await page.evaluate(() => window.DURATION);
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-i', '-',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '17', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out], { stdio: ['pipe', 'inherit', 'inherit'] });
  const n = Math.round(duration * fps);
  const from = Number(args[2] || 0), to = Math.min(n, Number(args[3] || n));
  for (let i = from; i < to; i++) {
    const buf = await shot(i / fps);
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
    if (i % 150 === 0) console.log(`frame ${i}/${n}`);
  }
  ff.stdin.end();
  await new Promise(r => ff.on('close', r));
}
await browser.close();
