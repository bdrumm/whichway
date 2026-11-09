# Post mortem: the route jumps trains and holds on to the first one (Oct 28 to Nov 9, 2026)

As with the Jay St post mortem, the trips' own times and motion stay in the private review (`data/trips/trip_review.md`);
this file keeps what the code needs.

## What the rider saw

- **Nov 9, F from 4 Av-9 St planned to change at W 4 St.** The rider changed early at Jay St-MetroTech, across the
  platform, and waited for the C. The phone kept them on the F. They tapped "Not on train"; the phone put them back on
  the 4 Av-9 St platform, took the C's pull-away at Jay St for a G leaving 4 Av-9 St, and switched the whole route to
  the G. The trip review shows the third "missed change" (Oct 22, Oct 27, Nov 9).
- **Nov 4, the F home from W 4 St.** The ride was called right (F, 0.90) until the walk-off, then flipped to the D
  (0.88) on the stop count: 5 station stops felt, the F makes 10, the D about 5.
- **Oct 28 to 30 (TestFlight feedback, three screenshots):** "line breakdown is wrong", "visual of train route is not
  correct", "totally wrong". The last was a route started by GPS as the C *uptown* to 42 St, then the R down to
  Brooklyn, on build 202610281218.

## Root cause

1. **"Not on train" meant only one thing.** It withdrew the felt departure and sent the leg back to the platform the
   rider boarded at, unless the train had already reached the route's own change (`unfeltAlighting`). A rider who says
   they are off a train that has been running for minutes has almost always changed trains at a station on the route.
   They are rarely still at the platform they started from, and rarely still on the train.
2. **Felt stops were scored as an exact count.** Each stop too many *or too few* cost a factor 0.35. The phone misses
   most stops: 0 of 31 legs felt the train's own count, and every miss was short. So every short count read as the
   express beside the local (the D for the F, the R for the F). The review's standing warning had said so for weeks.
3. **Lines that lead nowhere kept a real share of the prior.** A line at the platform that is not on the leg kept a
   quarter of a leg line's weight even when it leads away from the trip. It kept 0.6 if it reached any station where a
   line to the destination calls, even one the leg's own line calls at (the D reaches Broadway-Lafayette, where the F
   calls too). The rider has never taken such a line with a route in hand.

## What changed

- `readNotOnTrain` (`Core/EarlyChange.swift`) reads the tap in order:
  1. the train has reached the route's change: the rider got off there unfelt;
  2. it has reached a station where another route changes toward the destination (`changeReached` over
     `changesOnTheWay`): the rider changed there, at the latest such station;
  3. neither: the pull-away was not a train they boarded, and the leg starts over at the platform.

  `TripRecorder.notOnTrain` is a thin caller, for the app and the Live Activity alike (`changesOnTheWay` is handed in
  by the planner). A change read from the tap leaves the rider *waiting* at the change (`ChangedEarly.waiting`): the
  next pull-away felt names the connection, not a train that already left.
- Felt stops are a floor (`LineInference.stopMiscountFactor`): only stops felt beyond those a train made count against
  it, and a short count leaves "none of these" alone too.
- `platformLineFit`'s `noUseFit` is 0.05 (was 0.25), and its change stations come from `sensibleChangeStations`:
  stations where a line to the destination calls and the leg's own lines do not.
- A position fix kilometres from a train's stop rules it out more firmly (`locationFloor` 0.01): the "one candidate
  that fits nothing" case relied on the old stop count to be overturned.

Tests (`EarlyChangeTests`, `LineInferenceTests`, `RideEvidenceTests`) cover each way the tap is made: off at a change
short of the plan and waiting (end to end, from the tracker's motion to the connection's walk-off ending the trip);
off at the route's own change; tapped before the train reached any change; no train in hand; a train of another line.

## Still open

- **No automatic reading of an early change.** Nothing yet notices that the believed train left a change station and
  the phone has felt no train motion since. It would need the stored motion traces replayed first (CLAUDE.md step 4):
  motion is felt sparsely on real rides, and a wrong automatic change is worse than none.
- **An off-route train at the walk-off is judged at its own stop nearest that moment** (`LineInference.alightingStop`),
  and with a stop every two or three minutes some stop always fits. This favours trains off the route. In
  `withLocation`, a train whose stop has no position keeps its full weight while the plan's train is measured.
- **The planner can start a detour.** The Oct 29 route went uptown to come back down. Recent builds have changed the
  ranking, but nothing yet rules out a route that leaves in the wrong direction or takes far longer than the best one
  by the timetable.
- **Complex names tie by dictionary order.** "Park Place", "Chambers St" and "Cortlandt St" are equal in
  `StationIndex`, so the name shown for that change can vary from one launch to the next (Android breaks the tie
  alphabetically).
