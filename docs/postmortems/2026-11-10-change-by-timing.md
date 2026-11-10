# Post mortem: the change across the platform called a stop late, and the wrong A (Nov 10, 2026)

The trip's own times and motion stay in the private review (`data/trips/trip_review.md`); this file keeps what the code
needs.

## What the rider saw

F to the A at Jay St-MetroTech, the route's own change, across the platform. The A pulled in about a minute behind the
F and the rider took it. The countdown to Jay St ran out and the phone kept the rider on the F. The A came up later,
and it was the A after the one the rider was on. This is the fourth failure at this change (Oct 22, Oct 27, Nov 9).

## Root cause

The phone called an unfelt change (nothing felt as the train left without the rider) only when the train in hand
reached the **stop beyond** the change (`RideContinuity.pastStop`, from PR #28). At Jay St that is York St, about two
and a half minutes later. Two things followed from that one delay:

1. **The countdown ran out on the F.** Nothing moved the rider off the F until York St, so the route held the F leg and
   its arrival while the rider stood on the platform.
2. **The A was dated from the late call.** Closing the F ride stands the motion detector down. A rider already on the A
   is moving by then, so the detector calls a pull-away at once, at the moment of the call. The A leg was read
   against the trains leaving Jay St at that moment, not when the rider got on. With the A a minute behind the F, the
   call came about two minutes after the rider's A left, and the A after it was the nearer match.

Earlier fixes covered other members of this class: walking across (Oct 22), the one-tap "Changed to the A" (Oct 27),
and a train standing across with its pull-away felt (PR #28, `tookConnection`). None of them covered the timing: every
one waited for evidence that comes a stop later, or for the rider's tap.

## The fix (the class, not the trace)

- **The route's timing calls the change** (`RideContinuity.pastStop`, `trainLeavesTs`). Say the feed has the train in
  hand leaving the change (after the last poll that had it standing there, else its moment there plus a dwell), and no
  push has been felt since it arrived. Then the rider got off as planned, now, not at the stop beyond. The chosen route
  weighs most: getting off as planned needs no evidence, staying on does.
- **A stay-on felt later undoes it** (`RideSession.checkOffByTiming`, `TripTracker.resumeRide`). The train in hand is
  still followed. If it is felt running on to the stops beyond, the change is struck and the stay-on goes to the
  planner as before. That holds unless a connection the feed saw leave was boarded first (the route's prior, when the
  pushes could be either train's).
- **A connection boarded before a late call is dated from its own pull-away** (`RideSession.handleEvents`, `lateOff`,
  `TripTracker.moveDeparture`). A pull-away felt just after a late call goes to the first train of the leg that left
  after the rider got off. That is a guess, and the next push tests it (`checkMovedBack`). Still on the platform, that
  push is the rider's own train leaving there, which the feed shows, and the ride moves to it.
- **Connection pull-aways use the polls too** (`DepartureLog.pullAwaySpans`). A push between the last poll that listed
  a connection at the platform and the first that had it gone is that connection, even when its published time is a
  minute off.

## Every way to make this change, tested end to end (`ChangeByTimingTests`)

| Way | Test |
| --- | --- |
| Steps across, A a minute behind, pull-away felt | change called before the A comes; the A leg is that A |
| No steps, onto an A standing across, pull-away unfelt | dated from that A's own pull-away, not the late call |
| Lets the first A go, platform shaken as the change is called | the next push is A #2 leaving: A #2 is the ride |
| Waits on a quiet platform for a later A | its pull-away is the ride |
| Stays on, F pull-away felt | no change called; stay-on told by York St |
| Stays on, F pull-away unfelt | change called by timing, then struck when the F is felt running on |
| Rider names another A | that A, by hand |
| Rider names the F after the timing called the change | on the F by their word; the route follows it |

A walk across (`PendingBoardingTests`, `checkQuickChange`), an earlier change (`EarlyChangeTests`) and a named change
keep their own tests. Manual overrides are unchanged and unnarrowed: "On a train?" lists every train, and "Changed to
the A" and "Not on the train" work as before.

## Still open

- Replay every stored trip (`make replay`, `make trips`) on the Mac before the build. The trip in question had not
  uploaded when this was written.
- If an A leaves Jay St just as the F runs on, and the F's pull-away is not felt, the phone sides with the plan (the A).
  The alighting location and the rider's word correct it.
