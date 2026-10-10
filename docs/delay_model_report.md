# Delay alerts: how long they live, how long the delay lives, and the gap

Generated 2026-10-10 14:56 from data/mta.sqlite: 405 unplanned delay alerts (Staten Island Railway excluded) between 2026-09-26 and 2026-10-10, over 136 hours of polling in 84 spans; 368 ends were observed, the rest are censored where polling stopped (Kaplan–Meier throughout).

## 1. Lifetime of an alert

Still posted after 30 min: 71% · 60 min: 34% · 2 h: 14% · 4 h: 6%. Median 50 min, lower quartile 30 min; about a quarter of alerts are still up six hours later, the standing ones.

| cause | n | median min | p75 min | still up at 2 h |
|---|---|---|---|---|
| rolling_stock | 146 | 40.0 | 60.0 | 6% |
| unknown | 59 | 50.0 | 90.0 | 14% |
| medical | 43 | 40.0 | 60.0 | 6% |
| track | 35 | 70.0 | 230.0 | 34% |
| police | 32 | 40.0 | 50.0 | 4% |
| signal | 31 | 60.0 | 170.0 | 32% |
| person_on_track | 11 | 80.0 | 120.0 | 21% |
| switch | 11 | 80.0 | 120.0 | 23% |
| fire_smoke | 10 | 60.0 | 90.0 | 13% |
| planned_work | 10 | 50.0 | 80.0 | 12% |
| obstruction | 7 | 40.0 | 80.0 | 15% |
| investigation | 6 | 40.0 | 80.0 | 10% |

| line | n | median min | still up at 2 h |
|---|---|---|---|
| A | 66 | 50.0 | 14% |
| D | 50 | 60.0 | 13% |
| F | 48 | 80.0 | 30% |
| N | 40 | 50.0 | 19% |
| 4 | 36 | 50.0 | 13% |
| 6 | 35 | 50.0 | 15% |
| Q | 33 | 40.0 | 12% |
| R | 31 | 50.0 | 11% |
| 2 | 30 | 50.0 | 10% |
| E | 30 | 70.0 | 29% |
| 5 | 26 | 50.0 | 10% |
| C | 25 | 50.0 | 23% |
| 1 | 23 | 50.0 | 9% |
| 3 | 22 | 50.0 | 12% |
| M | 22 | 40.0 | 10% |
| H | 18 | 40.0 | 6% |
| B | 16 | 40.0 | 10% |
| 7 | 11 | 50.0 | 13% |
| J | 11 | 40.0 | 8% |
| 6X | 9 | 50.0 | 13% |
| L | 9 | 50.0 | 13% |
| W | 7 | 40.0 | 19% |
| G | 5 | 50.0 | 10% |

| time band | n | median min |
|---|---|---|
| am_peak | 59 | 40.0 |
| evening | 48 | 40.0 |
| midday | 76 | 50.0 |
| night | 50 | 50.0 |
| pm_peak | 84 | 40.0 |
| weekend_day | 69 | 50.0 |
| weekend_night | 19 | 50.0 |

## 2. The MTA's stated end

317 alerts carried a stated end, a median 36 min after creation (quartiles 24–57). Of the 296 whose end was observed, 42% vanished within three minutes of it, 15% were withdrawn earlier, and 43% were extended past it, by a median 8 min. So the stated end is a deadline that is kept or pushed, not a forecast of the delay: the realtime score runs on time relative to it.

Relative to the stated end, the share still posted: 30 min before 100% · at it 67% · 10 min after 17% · 30 min after 5% · 2 h after 0%.

## 3. Where and when

| station named | alerts | median min | lines | causes |
|---|---|---|---|---|
| 14 St-Union Sq | 8 | 50.0 | 4 5 6 6X N Q | rolling_stock 3, medical 2, signal 1 |
| Atlantic Av-Barclays Ctr | 8 | 50.0 | 2 3 D N Q R | rolling_stock 3, police 2, unknown 1 |
| 34 St-Herald Sq | 6 | 40.0 | B D F M | rolling_stock 3, power 1, medical 1 |
| 86 St | 6 | 50.0 | 4 5 6 N R | rolling_stock 4, signal 1, track 1 |
| Canal St | 6 | 40.0 | N Q R W | rolling_stock 4, police 1, medical 1 |
| 34 St-Penn Station | 5 | 40.0 | 2 3 A | police 3, rolling_stock 2 |
| 36 St | 5 | 70.0 | D N R | rolling_stock 3, switch 2 |
| Coney Island-Stillwell Av | 5 | 50.0 | D N Q | switch 2, obstruction 1, signal 1 |
| Hoyt-Schermerhorn Sts | 5 | 40.0 | A C | rolling_stock 2, medical 1, track 1 |
| W 4 St-Wash Sq | 5 | 40.0 | A C E F M | signal 1, medical 1, rolling_stock 1 |
| 125 St | 4 | 50.0 | 4 5 6 | rolling_stock 2, police 1, planned_work 1 |
| 145 St | 4 | 50.0 | 2 3 A B D | police 1, obstruction 1, planned_work 1 |
| 57 St/7 Av | 4 | 50.0 | N Q R W | rolling_stock 2, medical 1, police 1 |
| 59 St | 4 | 40.0 | 4 5 N R | rolling_stock 3, medical 1 |
| 9 Av | 4 | 40.0 | D | police 1, rolling_stock 1, medical 1 |

A station is named in 82% of alerts; the direction in 78%.

## 4. Staleness: the alert against the feed

405 alerts could be followed in the feed: the lateness of arrivals per 10 min on the alert's lines, at the stops within three of the station it names in the direction it names (78% of them; the whole line otherwise), against the hour before the alert less its last ten minutes. The feed showed a delay of two minutes or more over that baseline for 44% of alerts (178); the rest never registered there, a delay too local or too brief for the arrivals to carry, or one the alert overstated.

Where a delay showed and then cleared (299 alerts): the stops were back to normal a median 17 min after the alert was posted, and the alert stayed up a median 27 min after that (upper quartile 52); 14% were gone within 15 min of the feed looking normal, 55% within 30.

| cause | n | recovery after min | alert outlives by min | gone within 30 min of recovery |
|---|---|---|---|---|
| rolling_stock | 36 | 15 | 27 | 56% |
| medical | 9 | 27 | 26 | 78% |
| track | 9 | 15 | 72 | 22% |
| police | 8 | 14 | 17 | 100% |
| signal | 8 | 12 | 77 | 25% |
| unknown | 5 | 47 | 23 | 80% |

## 5. The realtime score

For a live alert the service reports when it was posted and where (the station in the text, the lines, the direction), its age, and from the curves above: the chance it is gone within 15, 30 and 60 minutes and the expected remaining minutes, taken from the curve relative to the MTA's stated end when there is one (the cause's curve, shrunk toward all alerts), else from age since creation. The feed is then read against it: the line's lateness and held trains now. A line that has looked normal for a while while the alert stands is scored stale with the table in section 4: the share of such alerts that were gone within 30 minutes of recovery.

## Limits

Two weeks of alerts from one collector; ends are only observed while it polls; the station is read from the text, which names the place of the cause rather than every stop affected; the feed's lateness is a median over the whole line, so a localised delay can read as recovered while one segment still crawls. The curves shrink toward their parents, so thin groups lean on the overall shape.
