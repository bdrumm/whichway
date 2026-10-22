# WhichWay product film

A 62-second film (1920×1080, 30 fps) drawn in code: `video.html` draws any frame with `render(t)` (open it in a
browser to watch it play), `render.mjs` steps through it with Playwright into ffmpeg, and `music.py` synthesises
the score.

```bash
cd marketing/video
ln -s "$(npm root -g)" node_modules        # Playwright from the global install
python3 music.py score.wav
node render.mjs film_silent.mp4 30         # or: node render.mjs part.mp4 30 <from> <to> for a frame range
ffmpeg -i film_silent.mp4 -i score.wav -c:v copy -c:a aac -b:a 256k -shortest whichway-film.mp4
node render.mjs --stills stills 3 18 29 52 59   # PNG stills at those seconds
```
