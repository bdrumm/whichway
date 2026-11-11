# Post mortem: the phone kept the rider on the F at Jay St a fifth time (Nov 11, 2026)

The trip's own times and motion stay in the private review (`data/trips/trip_review.md`) and the replay fixture in the
private data repository; this file keeps what the code needs.

## What the rider saw

F to the A/C at Jay St-MetroTech, the route's own change, across the platform. The rider walked off the F, waited a
minute or so, and took the C that pulled in behind it. The phone kept the rider on the F, decided they had stayed on,
and moved the route along the F (to the L at 14 St). The trip ran on build 202611101824, which had every fix from
Nov 10 (PR #31, #32, #33).

## Why each earlier fix missed it

- **PR #12 (Oct 27)** added the one-tap "Changed to the A" and the walk-across path. It never made the automatic call
  any safer; it gave the rider a way to correct it.
- **PR #31 (Nov 10 morning)** calls the change from the route's timing once the feed has the F leaving Jay St, but
  only if **no push** has been felt since the F got there. On this trip the walk across a crowded platform jostled the
  phone hard enough to read as pushes, so the timing rule never applied.
- **PR #32 (Nov 10 evening)** counts steps in bursts at the change, but only with pauses of up to 3 s, and it counted
  jostled seconds as pauses. This walk had longer pauses, so it never reached eight seconds of steps.
- **PR #33** (presumed boarding at the platform) only applies once the rider is off the F, which never happened.

## The root cause: staying on was the default whenever anything moved

`RideContinuity.pastStop` decided a stay-on as soon as two pushes were felt by the time the F reached the stop beyond
(York St). A rider who changed to the C feels those pushes too: the C runs to High St in the same minute or two. The
only thing that stood between those pushes and "stayed on" was matching the first push to the connection's pull-away
**within 30 s of the feed's estimate**, or catching the F still standing in a poll taken after the push. The feed's
times at Jay St run a minute or more behind and off by tens of seconds; the C's estimate was 31 s off. The replay showed
the outcome hanging on the poll clock: the same trip read as the C or as the F depending on whether the phone happened to
poll 15 s sooner or later.

So the route was the prior only when the phone felt nothing. As soon as anything moved (the rider's own walking, or a
ride on the connection), the burden of proof flipped to the plan, which is backwards. Baron's standing direction is the
opposite: assume the rider took the chosen route's train.

## The fix (the class, not the trace)

- **Staying on needs the train in hand, not merely motion** (`RideContinuity.connectionExplains`). The first push after
  the stop is put to a connection leaving the change platform unless the train in hand fits it at least 30 s better
  (`planBiasSec`). Both sides are lag-tolerant windows (`DepartureLog.departureWindows`, `RideSession.leaveWindow`): a
  connection could leave from a short stand after its moment there (the feed's time less its usual lag, which can be
  off by 20 s) to the first poll that had it gone; the train in hand from a short stand to a poll after the last that
  had it standing. A tie goes to the plan. No poll's timing decides it.
- **The rider's own moving about is not the train running on.** The stay-on and change calls (`checkStayedOn`,
  `checkOffByTiming`) now count only pushes clear of steps (`TripTracker.pushRunsClear`), as PR #32's rule already did.
- **Steps in bursts count by the window, not the gap** (`TripTracker.brokenWalk`). At the route's change, while the
  train stands there by the feed, eight seconds of steps within twenty is the walk-off, whatever the pauses between.
- **The trip record keeps the route it started on** (`TripObservation.startLegs`, `startRouteLabel`, `routeChanges`).
  This trip's record kept only the route the phone moved to, so the replay had to be told where it started. The replay
  (`TripReplayTests`, `pipeline/trip_replay.py`) now starts from the recorded start route; `WHICHWAY_REPLAY_START` sets
  it by hand for older trips, and `WHICHWAY_REPLAY_POLL="interval,offset"` replays at another poll clock.

## Every way to make this change, tested end to end

`ChangeByTimingTests` keeps the Nov 10 cases and adds, each at every poll offset across the 30 s cycle:

| Way | Test |
| --- | --- |
| A right behind the F, leaving later than the feed shows, F standing until just before | the rider is on that A |
| Walking about on the platform, jostling the phone, onto the A behind | not a stay-on; the A |
| Stays on the F, pull-away felt, an A 100 s behind | still a stay-on by York St |
| Rider names the F after the phone called the A | on the F by their word; the route follows it |

Walking across, an earlier change, a train standing across, letting the first A go, the F held, and naming another A
keep their tests. Manual overrides are unchanged and unnarrowed.

## Replays

This trip and the eleven earlier F-to-Jay-St trips, started on the Jay St route and replayed at four poll clocks
(30 s and 60 s, two offsets each), before and after. This trip now gets the C at every poll clock (before: a stay-on at
two of the four). No other trip's outcome changed; two (Oct 27, Nov 10) call the change a few seconds sooner, on the
same train.

## Still open

- When the A or C leaves Jay St at the same moment as the F, and the F's pull-away is the rider's, the phone sides with
  the plan. The alighting location and the rider's word correct it.
- Calibrating the feed's lag per trip from a felt arrival would narrow the windows.
