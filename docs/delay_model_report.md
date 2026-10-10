# Delay alerts: how long they live, how long the delay lives, and the gap

Generated 2026-10-10 15:31 from data/mta.sqlite: 407 unplanned delay alerts (Staten Island Railway excluded) between 2026-09-26 and 2026-10-10, over 137 hours of polling in 84 spans; 369 ends were observed, the rest are censored where polling stopped (Kaplan–Meier throughout).

## 1. Lifetime of an alert

Still posted after 30 min: 71% · 60 min: 34% · 2 h: 14% · 4 h: 6%. Median 50 min, lower quartile 30 min; about a quarter of alerts are still up six hours later, the standing ones.

| cause | n | median min | p75 min | still up at 2 h |
|---|---|---|---|---|
| rolling_stock | 147 | 40.0 | 60.0 | 6% |
| unknown | 60 | 50.0 | 90.0 | 14% |
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
| A | 67 | 50.0 | 14% |
| D | 50 | 60.0 | 13% |
| F | 48 | 80.0 | 30% |
| N | 40 | 50.0 | 19% |
| 4 | 36 | 50.0 | 13% |
| 6 | 35 | 50.0 | 15% |
| Q | 33 | 40.0 | 12% |
| R | 32 | 50.0 | 11% |
| 2 | 30 | 50.0 | 10% |
| E | 30 | 70.0 | 29% |
| 5 | 26 | 50.0 | 10% |
| C | 25 | 60.0 | 23% |
| 1 | 23 | 50.0 | 9% |
| 3 | 22 | 50.0 | 12% |
| M | 22 | 40.0 | 10% |
| H | 19 | 40.0 | 6% |
| B | 16 | 40.0 | 10% |
| 7 | 11 | 50.0 | 13% |
| J | 11 | 50.0 | 8% |
| 6X | 9 | 50.0 | 14% |
| L | 9 | 50.0 | 13% |
| W | 7 | 50.0 | 19% |
| G | 5 | 50.0 | 10% |

| time band | n | median min |
|---|---|---|
| am_peak | 59 | 40.0 |
| evening | 48 | 40.0 |
| midday | 76 | 50.0 |
| night | 50 | 50.0 |
| pm_peak | 84 | 40.0 |
| weekend_day | 71 | 50.0 |
| weekend_night | 19 | 50.0 |

## 2. The MTA's stated end

318 alerts carried a stated end, a median 36 min after creation (quartiles 24–57). Of the 296 whose end was observed, 42% vanished within three minutes of it, 15% were withdrawn earlier, and 43% were extended past it, by a median 8 min. So the stated end is a deadline that is kept or pushed, not a forecast of the delay: the realtime score runs on time relative to it.

Relative to the stated end, the share still posted: 30 min before 100% · at it 67% · 10 min after 17% · 30 min after 5% · 2 h after 0%.

## 3. Where and when

| station named | alerts | median min | lines | causes |
|---|---|---|---|---|
| 14 St-Union Sq | 8 | 50.0 | 4 5 6 6X N Q | rolling_stock 3, medical 2, signal 1 |
| Atlantic Av-Barclays Ctr | 8 | 50.0 | 2 3 D N Q R | rolling_stock 3, police 2, unknown 1 |
| 34 St-Herald Sq | 6 | 40.0 | B D F M | rolling_stock 3, power 1, medical 1 |
| 86 St | 6 | 50.0 | 4 5 6 N R | rolling_stock 4, signal 1, track 1 |
| Canal St | 6 | 40.0 | N Q R W | rolling_stock 4, police 1, medical 1 |
| 34 St-Penn Station | 5 | 50.0 | 2 3 A | police 3, rolling_stock 2 |
| 36 St | 5 | 70.0 | D N R | rolling_stock 3, switch 2 |
| Coney Island-Stillwell Av | 5 | 50.0 | D N Q | switch 2, obstruction 1, signal 1 |
| Hoyt-Schermerhorn Sts | 5 | 50.0 | A C | rolling_stock 2, medical 1, track 1 |
| W 4 St-Wash Sq | 5 | 40.0 | A C E F M | signal 1, medical 1, rolling_stock 1 |
| 125 St | 4 | 50.0 | 4 5 6 | rolling_stock 2, police 1, planned_work 1 |
| 145 St | 4 | 50.0 | 2 3 A B D | police 1, obstruction 1, planned_work 1 |
| 57 St/7 Av | 4 | 50.0 | N Q R W | rolling_stock 2, medical 1, police 1 |
| 59 St | 4 | 40.0 | 4 5 N R | rolling_stock 3, medical 1 |
| 9 Av | 4 | 40.0 | D | police 1, rolling_stock 1, medical 1 |

A station is named in 82% of alerts; the direction in 79%.

## 4. Staleness: the alert against the feed

407 alerts could be followed in the feed: the lateness of arrivals per 10 min on the alert's lines, at the stops within three of the station it names in the direction it names (78% of them; the whole line otherwise), against the hour before the alert less its last ten minutes. The feed showed a delay of two minutes or more over that baseline for 44% of alerts (179); the rest never registered there, a delay too local or too brief for the arrivals to carry, or one the alert overstated.

Where a delay showed and then cleared (88 alerts): the stops were back to normal a median 17 min after the alert was posted, and the alert stayed up a median 27 min after that (upper quartile 52); 14% were gone within 15 min of the feed looking normal, 55% within 30.

| cause | n | recovery after min | alert outlives by min | gone within 30 min of recovery |
|---|---|---|---|---|
| rolling_stock | 36 | 15 | 27 | 56% |
| medical | 9 | 27 | 26 | 78% |
| track | 9 | 15 | 72 | 22% |
| police | 8 | 14 | 17 | 100% |
| signal | 8 | 12 | 77 | 25% |
| unknown | 5 | 47 | 23 | 80% |

## 5. Before the alert: slowdowns the feed sees first

A slowdown episode is a segment where, over a trailing 20 minutes, at least two trains and at least 60% of them lost two minutes or more between the same two stops (the detector in realtime/incidents.py). 4863 episodes were found over 14 days, about 36 an hour across the network while polling; 34% began while a delay alert on the line was already posted. Of the 3215 with no alert yet, a delay alert on the line followed within 30 min for 11% and within 60 min for 20%, a median 37 min after the slowdown began. Chance alone, a random half hour on those lines, gives 10.3% and an hour 19.2%: a slowdown multiplies the odds of an alert by 1.1 over 30 min and 1.0 over 60. Most slowdowns still lead to nothing the MTA posts, so the pre-warning is a raised chance, not a forecast.

| trains lost | how many | n | alert within 30 min | within 60 min |
|---|---|---|---|---|
| 2-3 min | 2 trains | 1074 | 10% | 20% |
| 2-3 min | 3+ trains | 87 | 9% | 19% |
| 3-5 min | 2 trains | 1149 | 11% | 19% |
| 3-5 min | 3+ trains | 146 | 15% | 24% |
| 5 min+ | 2 trains | 610 | 9% | 18% |
| 5 min+ | 3+ trains | 51 | 17% | 25% |

| line | slowdowns | alert within 30 min |
|---|---|---|
| 4 | 251 | 9% |
| 7 | 237 | 3% |
| D | 226 | 14% |
| A | 218 | 23% |
| F | 212 | 21% |
| R | 212 | 10% |
| N | 174 | 11% |
| 2 | 172 | 12% |
| Q | 171 | 12% |
| M | 163 | 8% |
| 5 | 149 | 12% |
| B | 120 | 11% |

Seen from the alerts: of 407 delay alerts, a slowdown on their lines began in the 30 minutes before 59% of them, where chance alone would put one there for 64% (lift 0.9); within the hour before, 72% against 84% by chance (lift 0.9). Where the feed was ahead, the nearest slowdown began a median 11 min before the alert (lower quartile 3). Slowdowns are so common that a slowdown in the hour before an alert is only weak evidence the feed saw that incident coming; the half-hour figure is the one to read.

| cause | alerts | slowdown in the 30 min before | median lead min |
|---|---|---|---|
| rolling_stock | 147 | 61% | 10 |
| unknown | 60 | 65% | 15 |
| medical | 43 | 58% | 6 |
| track | 35 | 54% | 16 |
| police | 32 | 50% | 18 |
| signal | 31 | 58% | 5 |
| person_on_track | 11 | 64% | 4 |
| switch | 11 | 45% | 14 |
| fire_smoke | 10 | 70% | 6 |
| planned_work | 10 | 70% | 5 |

**Station-local.** The line-level test is too coarse, so the same two questions within 3 stops of the station an alert names (309 alerts name one the schedule knows). Seen from those alerts: a slowdown on that stretch was under way when the alert was posted for 22%, and one began in the 30 min before for 26%, against 20% by chance (lift 1.3); where it did, it began a median 9 min before the alert. Seen from the slowdowns: of 4414 with no alert naming a nearby station yet, one followed within 30 min for 2.3% against 1.5% by chance (lift 1.6), and within 60 min for 3.8% against 2.9% (lift 1.3).

| trains lost | how many | n | alert nearby within 30 min | by chance | lift | within 60 min | lift |
|---|---|---|---|---|---|---|---|
| 2-3 min | 2 trains | 1372 | 1.5% | 1.5% | 1.0 | 3.1% | 1.1 |
| 2-3 min | 3+ trains | 119 | 1.7% | 1.3% | 1.3 | 1.7% | 0.6 |
| 3-5 min | 2 trains | 1581 | 2.5% | 1.4% | 1.7 | 3.5% | 1.2 |
| 3-5 min | 3+ trains | 191 | 1.0% | 1.4% | 0.7 | 4.2% | 1.5 |
| 5 min+ | 2 trains | 928 | 3.2% | 1.5% | 2.1 | 4.7% | 1.6 |
| 5 min+ | 3+ trains | 82 | 6.1% | 1.6% | 3.9 | 8.5% | 2.8 |

| cause | alerts | slowdown under way at posting | began in the 30 min before | by chance |
|---|---|---|---|---|
| rolling_stock | 138 | 20% | 25% | 18% |
| medical | 39 | 18% | 21% | 20% |
| police | 30 | 13% | 13% | 21% |
| signal | 25 | 52% | 48% | 27% |
| track | 15 | 27% | 47% | 22% |
| switch | 11 | 9% | 9% | 22% |
| fire_smoke | 10 | 40% | 40% | 20% |
| person_on_track | 10 | 10% | 10% | 25% |
| unknown | 10 | 10% | 20% | 20% |

The pre-warning: a slowdown holding now on a line with no delay alert is reported with where it is, how long it has held and what the trains lost. It is a slowdown notice, not an alert forecast: the alert clause ("an alert nearby follows N% of such slowdowns within 30 min, L× the usual") is added only where the station-local severity row shows a real lift over chance, which is the heaviest slowdowns. Read the other way, the feed sees signal, track and fire trouble coming about half the time, a few minutes ahead; police, switch and person-on-track alerts it does not.


## 6. The realtime score

For a live alert the service reports when it was posted and where (the station in the text, the lines, the direction), its age, and from the curves above: the chance it is gone within 15, 30 and 60 minutes and the expected remaining minutes, taken from the curve relative to the MTA's stated end when there is one (the cause's curve, shrunk toward all alerts), else from age since creation. The feed is then read against it: the line's lateness and held trains now. A line that has looked normal for a while while the alert stands is scored stale with the table in section 4: the share of such alerts that were gone within 30 minutes of recovery.

## Limits

Two weeks of alerts from one collector; ends are only observed while it polls; the station is read from the text, which names the place of the cause rather than every stop affected; the feed's lateness is a median over the whole line, so a localised delay can read as recovered while one segment still crawls. The curves shrink toward their parents, so thin groups lean on the overall shape.
