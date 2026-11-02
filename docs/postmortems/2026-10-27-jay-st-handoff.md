# Post mortem: the Live Activity never handed off at Jay St (Oct 22 and Oct 27, 2026)

The detailed timeline (the trip's own times and motion) stays out of this public repository with the rest of the
trip data; it is in the private review (`data/trips/trip_review.md`) and the post mortem shared with the owner. This
file keeps what the code and the process need.

## What happened

The route was the F from 4 Av-9 St, changing at W 4 St-Wash Sq to the A/C/E for 14 St. At Jay St-MetroTech the rider
stepped across the platform onto an A that was standing there, with the trains running as the app predicted. The
Live Activity never handed off: it kept the rider on the F, counting stops to W 4 St, until the trip ended at 14 St.
The rider's walk-off at 14 St happened to land when the F was due at W 4 St, so the record shows a clean F ride to
W 4 St and no second leg. Oct 22 was the same ride and the same failure.

## Root cause

1. **No way to see a change made before the planned one.** The recorder ends a ride at a change in two ways: steps
   while the believed train stands at a station (`alightWalking`), or, at the planned change only, standing still for
   90 s after the believed train has moved on (`checkSamePlatformChange`). Stepping across the platform onto a train
   already standing there gives neither: two or three steps, then a train that moves like the one left. Line inference
   only weighs the first leg's trains, so "now on the second leg's line" was never a hypothesis.
2. **No way for the rider to say so either.** The On-train sheet offered lines at the planned change only, the Live
   Activity offered only "Not on the train", and naming a connection between trains (`setOnTrain`) never boarded it:
   `beginRiding` returned early because the tracker's phase was already `.riding` after the first leg.
3. **The Oct 22 fix treated the symptom.** On Oct 22 the rider walked a few seconds across the platform and a
   one-second pause split the steps under the 8 s walk-off; the fix let one still second inside a walk count. That
   fixed that day's trace, not the class of failure: a change with too few steps to feel. On Oct 27 there were none.
4. **Stop detection was blind on both trips.** A station stop is 12 s of shake under 0.02 g; on these rides the
   phone's shake stayed around 0.04 g at rest (the median second), so one stop was felt out of ten. The stop pattern
   (the A runs express, the F local) could otherwise have told the trains apart. The review had said so for weeks:
   "Stops felt matched the train's stops exactly on 0 of 18 legs."

## Why it reached a TestFlight build and the rider twice

- Each fix was tested against the one trace that failed, never against the other ways the same change happens
  (walk, step across, standing train, stay on, change early, change late).
- The parts that decide a hand-off (`TripRecorder`, the planner view's ride itinerary and Live Activity state) are
  outside the `WhichWayCore` package, so no unit test drives a whole transfer from motion and feed to the activity.
- The trip review did not flag a trip that reached its destination on fewer rides than legs: both failures were found
  only because the rider noticed and said so.
- The trip record carried no build number, so which build a trip ran on had to be inferred from its fields.

## What changed (this PR)

- `Core/EarlyChange.swift`: the changes short of the route's own on the line being ridden (Jay St for an F planned to
  change at W 4 St), and the one to offer from the train's position in the feed, from a minute before it pulls in to
  ten minutes after.
- One tap hands the trip over: "Changed to the A at Jay St-MetroTech" in the Live Activity (`ChangedTrainIntent`),
  the trip bar and the On-train sheet. The recorder closes the ride at the change (`takeEarlyChange`), the planner
  adopts the route that changes there and boards the rider on the first connection to leave after the step across.
- `TripTracker.beginRiding` boards a connection named between trains (it was a no-op after the first leg).
- Trips record `appBuild` and `changedEarlyTaps`; the review flags "missed change" trips at the top of its findings.

## Still open

- Stop detection's fixed shake threshold (0.02 g). A baseline relative to the ride's own quiet seconds found seven
  stops on the Oct 27 trace where the fixed threshold found one; it changes every inference that reads stops, so it
  needs a replay of every stored trace before it ships.
- An automatic early change. With stops felt, the felt stops after the station can be scored against the connection's
  stops as well as the believed train's (`LineInference.withRide`); until then the rider's tap is the hand-off.
- `checkStayedOn` reads any motion after the change as staying on; at a planned change across the platform, riding the
  connection moves the phone just the same.

## Process

The rules that came out of this are in `CLAUDE.md` under "Transfers and trip sensing".
