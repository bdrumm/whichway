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

## Under the Clock

`clock.html` (72 s) leads with the math and ends on the minute it is for. Arrivals fall through a Galton board
(`galton`) until the answer to "when?" is a curve with its 8-in-10 window; the curve becomes the city (`city`), every
train carrying its own distribution, and one train is picked out of the crowd. Then 1986, a first date under the
station clock (`hall`), his train stuck for forty minutes and a promise; forty years on the 6 holds again and the
engine graphics weigh it (`engineMarey`, `holdCurve`, `routeOdds`: stay 9% by seven, cross the platform 98%), and
tonight he is the one waiting. The score is the `clock` spec in `scores.py`, ending on the chime.

```bash
python3 scores.py clock clock.wav
./render_parts.sh clock.html clock_silent.mp4 4
ffmpeg -i clock_silent.mp4 -i clock.wav -c:v copy -c:a aac -b:a 256k -shortest whichway-under-the-clock.mp4
```

## Under the Clock, live-action cut

`clock-live.html` (87.5 s) is the same film on real footage, cut on a 96 bpm grid, with the math drawn over the
pictures. `footage.py` fetches the clips (free stock video from Mixkit, by id; they are not committed) and unpacks
each shot into `footage/<shot>/0001.jpg…`; the page's `SHOTS` table says when each plays, its grade, its push-in and,
for the two tunnels, a time map that brakes the train to a dead stop. The concourse clock is followed through its shots
(`track_clock`, written to `footage/track.js`) so the film can repaint its face to seven o'clock in 1986 and 6:56
tonight. `galton` and `city` live in `mathkit.js`, shared with `clock.html`. The score is the `clock-live` spec, with
booms on the cuts, a brake squeal, a heartbeat and a ticking clock through the hold (`Score.fx`).

```bash
pip install opencv-python-headless numpy
python3 footage.py
python3 scores.py clock-live clock-live.wav
./render_parts.sh clock-live.html clock-live_silent.mp4 6
# the grain makes the lossless-ish render huge (about 300 MB), so the deliverable is encoded again
ffmpeg -i clock-live_silent.mp4 -i clock-live.wav -c:v libx264 -preset slow -crf 23 -maxrate 5M -bufsize 10M \
  -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 256k -shortest whichway-under-the-clock-live.mp4
```

## Under the Clock, illustrated New York cut

`clock-nyc.html` (90 s) tells the same story with every scene drawn in code, no footage: the skyline in rain, the
1986 concourse in time-lapse, a Redbird braking in the tunnel, the brownstone street, the island platform, the
reunion under the constellation ceiling. It leads with the couple and the scale of the city's data ("1.7 million
signals a day, so two people can find each other") and has no charts or percentages; the only readout is the time he
will be under the clock. `nyc.js` is the illustration kit (skyline, concourse, subway cars, street, platform in
perspective, figures, crowds), `cine.js` the shared titles, grain and letterbox (also used by `clock-live.html`).
The score is the `clock-nyc` spec: every effect is made of notes from the chord under it (`Score.fx2`), no noise.

```bash
python3 scores.py clock-nyc clock-nyc.wav
./render_parts.sh clock-nyc.html clock-nyc_silent.mp4 4
ffmpeg -i clock-nyc_silent.mp4 -i clock-nyc.wav -c:v libx264 -preset slow -crf 23 -maxrate 5M -bufsize 10M \
  -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 256k -shortest whichway-under-the-clock-nyc.mp4
```

## Sound samples

The logo sound has five candidates (`Score.logo`, chosen per spec with `logo_style`: `fork`, `rails`, `chime`,
`swell`, `heart`), each timed to the icon drawing its stem, fork, dot and name. `sounds.html` plays them one after
another over the end card with a letter on screen, and with `?effects` names each score-born effect as it plays.

```bash
for s in fork rails chime swell heart; do python3 scores.py logo-$s logo-$s.wav; done   # then join in A to E order
FILM=sounds.html node render.mjs logo-sounds_silent.mp4 30
python3 scores.py effects effects.wav
FILM='sounds.html?effects' node render.mjs sound-effects_silent.mp4 30
```
