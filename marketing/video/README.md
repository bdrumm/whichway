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
Each scene gets the effects that belong to it; the station clock ticks in key wherever the clock or the wait is the
scene, always on the 96 bpm grid, and stays on quietly as the band's hi-hat (`ticktock`). The app's notification
sounds once when it speaks and again as the logo sound that ends the film (`logo_style='notify'`).

```bash
python3 scores.py clock-nyc clock-nyc.wav
./render_parts.sh clock-nyc.html clock-nyc_silent.mp4 4
ffmpeg -i clock-nyc_silent.mp4 -i clock-nyc.wav -c:v libx264 -preset slow -crf 23 -maxrate 5M -bufsize 10M \
  -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 256k -shortest whichway-under-the-clock-nyc.mp4
# a 720p copy of about 15 MB for watching on a phone
ffmpeg -i clock-nyc_silent.mp4 -i clock-nyc.wav -vf scale=1280:720:flags=lanczos -c:v libx264 -profile:v main -crf 25 \
  -maxrate 1800k -bufsize 3600k -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 160k -shortest \
  whichway-under-the-clock-nyc-phone.mp4
```

## Know When to Run

`sprint.html` (48 s) is the commute as a race: a man whose record from his front door to the doors of the 8:14 is
2:08, and an app that tells him to the second when those doors open. Out of the door at dawn, down the block (`chase`:
the camera runs with him along the brownstone row, which repeats and smears with speed), across the side streets,
down the stairs (`stairs`), through the turnstile, along the passage (`sCorridor`, from where he is) and through the
closing doors, with two clocks on screen all the way (`hud`: the app's count to the doors, and his own with splits).
The next morning the train is four minutes late, the app says so, and he walks. It is cut to techno at 150 bpm: a
beat is 0.4 s, a bar 1.6 s, cuts fall on bars and he lands a foot on every eighth note. The score is the `sprint`
spec (`Score.techno`: kick, rolling bass, an acid line whose filter keeps opening, claps, stabs, rolls and risers,
in B minor so the app's notification sits inside it), and it ends on the notification as the logo sound.

```bash
python3 scores.py sprint sprint.wav
./render_parts.sh sprint.html sprint_silent.mp4 4
ffmpeg -i sprint_silent.mp4 -i sprint.wav -c:v libx264 -preset slow -crf 23 -maxrate 5M -bufsize 10M \
  -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 256k -shortest whichway-know-when-to-run.mp4
node stills.mjs sprint.html stills 4 12.5 30     # half-size stills of any film, with page errors printed
```

## Every Day at 3:30

`threethirty.html` (67 s) is school pickup told by the one who is picked up. A six-year-old draws her mom in crayon:
she comes at 3:30, every day, on the F train, which is never late. Then the paper is gone and we are under the city
on the day the F is held: twenty-one minutes to the gate, the app says the hold will run fourteen more and that the Q
across the platform still makes it, and she crosses. Back on the paper the drawing ends the way it always does. She
never knew. `crayon.js` is the drawing kit: `page` (a sheet of paper and a camera over it), `mark` (one wax stroke that
draws itself, skips on the paper's tooth, wanders and boils six times a second), `scribble` (the zigzag a child fills a
shape with), and `write` (a ball-and-stick alphabet, no two letters the same size). The tunnel is `nyc.js`. The score
is the `threethirty` spec (`Score.box`: a music box in D major that is cut off dead when the train stops, then the
station clock and a heartbeat, the app's notification, the band as she crosses, and the music box again).

```bash
python3 scores.py threethirty threethirty.wav
./render_parts.sh threethirty.html threethirty_silent.mp4 4
ffmpeg -i threethirty_silent.mp4 -i threethirty.wav -c:v libx264 -preset slow -crf 23 -maxrate 5M -bufsize 10M \
  -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 256k -shortest whichway-every-day-at-3-30.mp4
```

## What It Does

`whatitdoes.html` (49.5 s) is the plain one: no story and almost no pictures. Six numbered lines, each one thing the
app does, each with one small diagram that moves (`ITEMS`: the line, what is under it, and the function that draws its
diagram), then all six together and the one tap that corrects it. Every line is a function the app has, and the cards
use the app's own wording (the hold choices, the time to make a change, the notification before a usual trip), so
check the app before changing a line. The score is the `whatitdoes` spec: a felt piano over a soft pulse, a struck
note as each line lands, the notification where the notification is on screen.

```bash
python3 scores.py whatitdoes whatitdoes.wav
./render_parts.sh whatitdoes.html whatitdoes_silent.mp4 4
ffmpeg -i whatitdoes_silent.mp4 -i whatitdoes.wav -c:v libx264 -preset slow -crf 23 -maxrate 5M -bufsize 10M \
  -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 256k -shortest whichway-what-it-does.mp4
```

## First Breath

`firstbreath.html` (74 s) is the one about being late to something that happens once. 2:47 AM, a message: "It's
time." Three weeks early, and he is across the river on the night shift, when the trains run twenty minutes apart.
The app picks the 7 to the 6; he runs for the 7 in the rain; the 7 is held under the river while his time to spare
for the 6 drains from 2:40 to 0:40; he makes the 6 with two seconds left, runs the hospital corridor, and the door
opens on the first cry. A heart monitor is the pulse of the film (`trace`, `pulseLines`): her line and his along the
bottom of every shot, his doubling when he runs, and a third that starts at 3:21 AM. A beat is 0.6 s, a bar 2.4 s, and
every cut is on a bar (`SCENES`). The clock in one corner and the count in the other (`CLOCK`, `counts`) tell one
consistent story, so change them together. What the app says on screen is what the app does: it ranks the ways there
by when they arrive, shows the time to spare at a change, and says what a hold will do.

The score is the `firstbreath` spec: the monitor is one pure A a beat (`beeps`), alone at the start and loudest in
the bar of near silence at the door; the first cry is the notification's own rise, slowed and sung twice (`cries`),
with a third, faster heart on the glass F sharp that ends the logo sound. `pulse_body` gives the heartbeat overtones
so a phone's speaker can play it.

```bash
python3 scores.py firstbreath firstbreath.wav
./render_parts.sh firstbreath.html firstbreath_silent.mp4 4
ffmpeg -i firstbreath_silent.mp4 -i firstbreath.wav -c:v libx264 -preset slow -crf 23 -maxrate 5M -bufsize 10M \
  -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 256k -shortest whichway-first-breath.mp4
```

## Sound samples

The logo sound has seven candidates (`Score.logo`, chosen per spec with `logo_style`: `fork`, `rails`, `chime`,
`swell`, `heart`, `clock`, `notify`), each timed to the icon drawing itself. `notify` is the one in use: the app's
own notification sound (a quick rise of a fifth and a glass note), landing where the dot does, so the phone and the
logo make the same sound. `sounds.html` plays them one after
another over the end card with a letter on screen, and with `?effects` names each score-born effect as it plays.

```bash
for s in fork rails chime swell heart clock notify; do python3 scores.py logo-$s logo-$s.wav; done   # then join in A to G order
FILM=sounds.html node render.mjs logo-sounds_silent.mp4 30
python3 scores.py effects effects.wav
FILM='sounds.html?effects' node render.mjs sound-effects_silent.mp4 30
```
