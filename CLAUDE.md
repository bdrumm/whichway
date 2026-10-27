# Working in this repository

The README covers the project, the Makefile targets (`make help`) and the layout. This file is the working rules for
Claude sessions.

## Trip data stays private

This repository is public. The rider's trips, motion traces and rider notes live in `data/trips/` (gitignored) and the
private `bdrumm/whichway-data` repository. Never commit trip times, traces or trip-derived fixtures; tests use
synthetic data. Station names already in code comments are fine; a trip's own timeline is not.

## Transfers and trip sensing

A change between trains is where the app has failed the rider most (post mortems in `docs/postmortems/`). Before a
change to trip sensing, line inference, the planner's ride itinerary or the Live Activity goes into a TestFlight build:

1. **Fix the class, not the trace.** Name the kind of change that failed and list every way a rider makes it: a walk
   between platforms, steps across the platform, a step onto a train already standing there (no steps at all),
   staying on past the change, changing at an earlier or a later station than planned, a train named by hand. Check
   the fix against each one. A threshold tuned to one trace (Oct 22: one still second inside a walk) leaves the rest
   of the class open (Oct 27: no steps at all).
2. **Test the hand-off end to end, per scenario.** Each scenario above needs a test that goes from the tracker's events
   to the leg in hand: `legsRidden`, `onTrain`, the train named for the next leg. `WhichWayCore` covers `Core/` only;
   when the decision lives in `TripRecorder` or `PlannerView`, move the deciding logic into `Core/` (as
   `Core/EarlyChange.swift` does) so it can be tested, and keep the view a thin caller.
3. **Every automatic decision has a manual override that works.** If the sensors cannot see it, the rider must be able
   to say it in one tap from the Live Activity, and that path needs its own test (a train named between trains was
   never boarded until Oct 27).
4. **Replay the stored trips before building.** Run `make trips` and read the top of `data/trips/trip_review.md`: no
   trip may newly show "missed change", and the felt-stops line should not get worse. When the change touches motion
   thresholds, replay every stored trace in `data/trips/github/traces/` (env-gated, never committed) and compare the
   events and stop spans before and after.
5. **Confirm the build a trip ran on** from the trip's `appBuild` before saying a fix was or was not on the phone.
6. **Read the review's standing warnings.** A line that has said the same thing for weeks (stops felt matching on
   0 of 18 legs) is a defect, not background.

Run before pushing iOS changes: `make ios-test` (the core package) and `make ios-build` (the app and the Live
Activity extension). Python: `.venv/bin/python -m pytest -q`.

## Builds and deploys

TestFlight uploads (`make ios-testflight`) only when the owner asks for one in their own words.
