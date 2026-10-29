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

## The short films

`kit.js` holds the shared drawing (palette, text, the phone, line bullets, the icon and end card); each film is a
page that loads it and defines `render(t)`: `minutes.html` ("Minutes", 47 s), `livingmap.html` ("The Living Map",
48 s) and `newyorker.html` ("Every New Yorker was new once", 47 s). `scores.py` writes each one's score.

```bash
python3 scores.py minutes minutes.wav
./render_parts.sh minutes.html minutes_silent.mp4 4      # 4 renderers in parallel, joined
ffmpeg -i minutes_silent.mp4 -i minutes.wav -c:v copy -c:a aac -b:a 256k -shortest minutes.mp4
FILM=minutes.html node render.mjs --stills stills 3 20 44  # stills from one film
```

## Engine cuts

`engine.js` draws the prediction engine as graphics instead of phone screens: a stringline of every train on the
line with the hold and the trains stuck behind it (`engineMarey`), how long holds on a stretch last (`holdCurve`),
the arrival window tightening against a deadline (`arrivalWindow`), the odds of each route (`routeOdds`), the
local and express race to a cross-platform change (`expressLocal`), and the moving network behind the logo
(`endCardData`). `maya-engine.html` and `curtain-engine.html` are the Maya and Curtain films told with them, and
their scores (`maya-engine`, `curtain-engine`) end on the signature chime: three FM bells timed to the icon
drawing its stem, branch and dot.
