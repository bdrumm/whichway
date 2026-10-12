# Delay alerts: how long they live, how long the delay lives, and the gap

Generated 2026-10-12 17:17 from data/mta.sqlite: 549 unplanned delay alerts (Staten Island Railway excluded) between 2026-09-26 and 2026-10-12, over 186 hours of polling in 84 spans; 510 ends were observed, the rest are censored where polling stopped (Kaplan–Meier throughout).

## 1. Lifetime of an alert

Still posted after 30 min: 70% · 60 min: 31% · 2 h: 13% · 4 h: 6%. Median 50 min, lower quartile 30 min; about a quarter of alerts are still up six hours later, the standing ones.

| cause | n | median min | p75 min | still up at 2 h |
|---|---|---|---|---|
| rolling_stock | 215 | 40.0 | 60.0 | 5% |
| unknown | 71 | 50.0 | 80.0 | 13% |
| medical | 55 | 40.0 | 60.0 | 4% |
| signal | 47 | 70.0 | 180.0 | 32% |
| track | 47 | 70.0 | 230.0 | 34% |
| police | 44 | 40.0 | 50.0 | 3% |
| switch | 15 | 70.0 | 120.0 | 23% |
| person_on_track | 13 | 60.0 | 120.0 | 19% |
| planned_work | 12 | 50.0 | 80.0 | 15% |
| fire_smoke | 11 | 60.0 | 90.0 | 16% |
| investigation | 8 | 40.0 | 70.0 | 9% |
| obstruction | 7 | 40.0 | 70.0 | 15% |

| line | n | median min | still up at 2 h |
|---|---|---|---|
| A | 83 | 50.0 | 15% |
| F | 64 | 70.0 | 26% |
| D | 62 | 50.0 | 16% |
| N | 54 | 50.0 | 18% |
| 4 | 51 | 50.0 | 10% |
| Q | 49 | 40.0 | 11% |
| 2 | 46 | 40.0 | 7% |
| 6 | 45 | 50.0 | 16% |
| R | 41 | 50.0 | 11% |
| 5 | 36 | 40.0 | 8% |
| C | 33 | 50.0 | 25% |
| 3 | 32 | 40.0 | 9% |
| E | 32 | 60.0 | 28% |
| 1 | 31 | 50.0 | 7% |
| M | 30 | 40.0 | 8% |
| H | 23 | 40.0 | 5% |
| B | 19 | 50.0 | 15% |
| G | 17 | 50.0 | 16% |
| 7 | 16 | 50.0 | 14% |
| J | 14 | 40.0 | 7% |
| L | 12 | 50.0 | 15% |
| 6X | 11 | 50.0 | 16% |
| W | 9 | 40.0 | 17% |
| FS | 5 | 50.0 | 20% |

| time band | n | median min |
|---|---|---|
| am_peak | 78 | 40.0 |
| evening | 48 | 40.0 |
| midday | 93 | 60.0 |
| night | 60 | 50.0 |
| pm_peak | 90 | 40.0 |
| weekend_day | 134 | 50.0 |
| weekend_night | 46 | 50.0 |

## 2. The MTA's stated end

433 alerts carried a stated end, a median 35 min after creation (quartiles 23–54). Of the 408 whose end was observed, 46% vanished within three minutes of it, 11% were withdrawn earlier, and 43% were extended past it, by a median 7 min. So the stated end is a deadline that is kept or pushed, not a forecast of the delay: the realtime score runs on time relative to it.

Relative to the stated end, the share still posted: 30 min before 100% · at it 71% · 10 min after 16% · 30 min after 4% · 2 h after 0%.

## 3. Where and when

| station named | alerts | median min | lines | causes |
|---|---|---|---|---|
| 14 St-Union Sq | 11 | 50.0 | 4 5 6 6X N Q | rolling_stock 5, medical 2, signal 2 |
| Atlantic Av-Barclays Ctr | 11 | 50.0 | 2 3 B D N Q R | rolling_stock 6, police 2, unknown 1 |
| 34 St-Herald Sq | 8 | 40.0 | B D F M Q | rolling_stock 3, power 1, medical 1 |
| Coney Island-Stillwell Av | 8 | 50.0 | D N Q | signal 3, switch 2, rolling_stock 2 |
| Prospect Park | 8 | 50.0 | B FS Q R | rolling_stock 6, signal 2 |
| 96 St | 7 | 40.0 | 1 2 3 C | rolling_stock 5, medical 1, police 1 |
| Grand Central-42 St | 7 | 50.0 | 4 5 6 | police 5, rolling_stock 1, investigation 1 |
| Hoyt-Schermerhorn Sts | 7 | 40.0 | A C | rolling_stock 2, medical 2, track 1 |
| W 4 St-Wash Sq | 7 | 40.0 | A C E F M | medical 2, police 2, signal 1 |
| 14 St | 6 | 50.0 | 1 2 3 A E F M | rolling_stock 3, fire_smoke 1, track 1 |
| 36 St | 6 | 60.0 | D N R | rolling_stock 4, switch 2 |
| 57 St/7 Av | 6 | 50.0 | N Q R W | rolling_stock 3, medical 1, police 1 |
| 59 St | 6 | 40.0 | 4 5 N R | rolling_stock 5, medical 1 |
| 59 St-Columbus Circle | 6 | 40.0 | A B C D | medical 2, person_on_track 1, switch 1 |
| 86 St | 6 | 50.0 | 4 5 6 N R | rolling_stock 4, signal 1, track 1 |

A station is named in 84% of alerts; the direction in 78%.

## 4. Staleness: the alert against the feed

549 alerts could be followed in the feed: the lateness of arrivals per 10 min on the alert's lines, at the stops within three of the station it names in the direction it names (80% of them; the whole line otherwise), against the hour before the alert less its last ten minutes. The feed showed a delay of two minutes or more over that baseline for 40% of alerts (220); the rest never registered there, a delay too local or too brief for the arrivals to carry, or one the alert overstated.

Where a delay showed and then cleared (122 alerts): the stops were back to normal a median 16 min after the alert was posted, and the alert stayed up a median 26 min after that (upper quartile 50); 13% were gone within 15 min of the feed looking normal, 58% within 30.

| cause | n | recovery after min | alert outlives by min | gone within 30 min of recovery |
|---|---|---|---|---|
| rolling_stock | 54 | 15 | 25 | 67% |
| medical | 14 | 16 | 26 | 71% |
| track | 12 | 9 | 50 | 33% |
| signal | 11 | 15 | 85 | 27% |
| police | 8 | 14 | 17 | 100% |
| unknown | 7 | 47 | 22 | 86% |
| switch | 5 | 23 | 84 | 20% |
| person_on_track | 4 | 41 | 24 | 50% |

## 5. Before the alert: slowdowns the feed sees first

A slowdown episode is a segment where, over a trailing 20 minutes, at least two trains and at least 60% of them lost two minutes or more between the same two stops (the detector in realtime/incidents.py). 5269 episodes were found over 14 days, about 28 an hour across the network while polling; 36% began while a delay alert on the line was already posted. Of the 3371 with no alert yet, a delay alert on the line followed within 30 min for 12% and within 60 min for 21%, a median 37 min after the slowdown began. Chance alone, a random half hour on those lines, gives 9.8% and an hour 18.4%: a slowdown multiplies the odds of an alert by 1.2 over 30 min and 1.1 over 60. Most slowdowns still lead to nothing the MTA posts, so the pre-warning is a raised chance, not a forecast.

| trains lost | how many | n | alert within 30 min | within 60 min |
|---|---|---|---|---|
| 2-3 min | 2 trains | 1073 | 11% | 22% |
| 2-3 min | 3+ trains | 94 | 12% | 22% |
| 3-5 min | 2 trains | 1258 | 12% | 21% |
| 3-5 min | 3+ trains | 171 | 15% | 23% |
| 5 min+ | 2 trains | 615 | 9% | 18% |
| 5 min+ | 3+ trains | 53 | 17% | 26% |

| line | slowdowns | alert within 30 min |
|---|---|---|
| 7 | 285 | 5% |
| 4 | 245 | 10% |
| A | 219 | 24% |
| R | 214 | 12% |
| F | 213 | 23% |
| D | 209 | 16% |
| 2 | 180 | 13% |
| N | 176 | 12% |
| M | 174 | 8% |
| Q | 165 | 14% |
| 5 | 159 | 12% |
| B | 133 | 14% |

Seen from the alerts: of 549 delay alerts, a slowdown on their lines began in the 30 minutes before 54% of them, where chance alone would put one there for 54% (lift 1.0); within the hour before, 64% against 77% by chance (lift 0.8). Where the feed was ahead, the nearest slowdown began a median 11 min before the alert (lower quartile 4). Slowdowns are so common that a slowdown in the hour before an alert is only weak evidence the feed saw that incident coming; the half-hour figure is the one to read.

| cause | alerts | slowdown in the 30 min before | median lead min |
|---|---|---|---|
| rolling_stock | 215 | 51% | 11 |
| unknown | 71 | 59% | 16 |
| medical | 55 | 53% | 9 |
| signal | 47 | 53% | 5 |
| track | 47 | 51% | 14 |
| police | 44 | 59% | 13 |
| switch | 15 | 47% | 11 |
| person_on_track | 13 | 62% | 5 |
| planned_work | 12 | 75% | 5 |
| fire_smoke | 11 | 55% | 8 |
| investigation | 8 | 62% | 5 |

**Station-local.** The line-level test is too coarse, so the same two questions within 3 stops of the station an alert names (385 alerts name one the schedule knows). Seen from those alerts: a slowdown on that stretch was under way when the alert was posted for 22%, and one began in the 30 min before for 24%, against 17% by chance (lift 1.4); where it did, it began a median 9 min before the alert. Seen from the slowdowns: of 4783 with no alert naming a nearby station yet, one followed within 30 min for 2.4% against 1.4% by chance (lift 1.8), and within 60 min for 4.1% against 2.7% (lift 1.5).

| trains lost | how many | n | alert nearby within 30 min | by chance | lift | within 60 min | lift |
|---|---|---|---|---|---|---|---|
| 2-3 min | 2 trains | 1431 | 1.6% | 1.4% | 1.2 | 3.4% | 1.2 |
| 2-3 min | 3+ trains | 132 | 1.5% | 1.4% | 1.1 | 2.3% | 0.8 |
| 3-5 min | 2 trains | 1770 | 2.5% | 1.3% | 1.9 | 3.8% | 1.5 |
| 3-5 min | 3+ trains | 225 | 1.3% | 1.4% | 1.0 | 4.0% | 1.5 |
| 5 min+ | 2 trains | 983 | 3.5% | 1.5% | 2.3 | 5.4% | 1.8 |
| 5 min+ | 3+ trains | 87 | 8.0% | 1.5% | 5.3 | 11.5% | 3.9 |

| cause | alerts | slowdown under way at posting | began in the 30 min before | by chance |
|---|---|---|---|---|
| rolling_stock | 176 | 19% | 21% | 15% |
| medical | 47 | 13% | 17% | 17% |
| police | 38 | 21% | 18% | 18% |
| signal | 33 | 42% | 42% | 17% |
| track | 22 | 27% | 36% | 19% |
| switch | 14 | 14% | 14% | 18% |
| unknown | 12 | 8% | 25% | 17% |
| person_on_track | 11 | 18% | 18% | 24% |
| fire_smoke | 10 | 40% | 40% | 20% |
| investigation | 8 | 25% | 25% | 18% |
| planned_work | 8 | 38% | 50% | 22% |

The pre-warning: a slowdown holding now on a line with no delay alert is reported with where it is, how long it has held and what the trains lost. It is a slowdown notice, not an alert forecast: the alert clause ("an alert nearby follows N% of such slowdowns within 30 min, L× the usual") is added only where the station-local severity row shows a real lift over chance, which is the heaviest slowdowns. Read the other way, the feed sees signal, track and fire trouble coming about half the time, a few minutes ahead; police, switch and person-on-track alerts it does not.


## 6. The realtime score

For a live alert the service reports when it was posted and where (the station in the text, the lines, the direction), its age, and from the curves above: the chance it is gone within 15, 30 and 60 minutes and the expected remaining minutes, taken from the curve relative to the MTA's stated end when there is one (the cause's curve, shrunk toward all alerts), else from age since creation. The feed is then read against it: the line's lateness and held trains now. A line that has looked normal for a while while the alert stands is scored stale with the table in section 4: the share of such alerts that were gone within 30 minutes of recovery.


## 7. The phases: starting, in effect, waning, stale

The same alerts followed at 5-minute bins, as the excess of the arrivals' lateness over the hour before the alert, at the stops within three of the station named (79% of the 464 followed; the whole line otherwise). The feed showed the delay (two minutes or more over the baseline) at posting for 55%, within 10 min for 53%, within 20 for 60%, within 30 for 63%, and at some point for 67%. Among alerts that showed, the first evidence came a median 3 min after posting (upper quartile 8). So the score reads a fresh alert as *starting* until 20 min with nothing in the feed, and *unconfirmed* past that: an alert that was going to register has, by then.

Where the feed showed it (313 alerts), the delay peaked a median 14 min after posting, at 5.9 min over the baseline; the stops came back under the margin a median 20 min after posting (5 after the peak), with the alert still up for 76% of them.

Each bin of each alert's life labeled with what was knowable then, and how the alert went from there:

| phase | share of alert-minutes | alerts | median age min | gone within 15 min | within 30 | within 60 |
|---|---|---|---|---|---|---|
| starting | 14% | 248 | 9 | 21% | 49% | 75% |
| in effect | 25% | 317 | 25 | 16% | 33% | 57% |
| waning | 17% | 263 | 38 | 21% | 43% | 65% |
| stale | 29% | 206 | 81 | 25% | 41% | 58% |
| unconfirmed | 15% | 140 | 44 | 29% | 47% | 66% |

What a rider sees at each point of an alert's life (share of bins in each phase):

| age | starting | in effect | waning | stale | unconfirmed |
|---|---|---|---|---|---|
| 0-10 min | 50% | 42% | 8% | 0% | 0% |
| 10-20 min | 39% | 30% | 24% | 6% | 0% |
| 20-30 min | 0% | 23% | 19% | 24% | 34% |
| 30-60 min | 0% | 23% | 16% | 35% | 27% |
| 60-120 min | 0% | 19% | 19% | 43% | 19% |
| 120+ min | 0% | 17% | 19% | 53% | 11% |

| cause | alerts | feed shows it | first evidence min | gone within 30: in effect | waning | stale | unconfirmed |
|---|---|---|---|---|---|---|---|
| rolling_stock | 178 | 69% | 2 | 46% | 63% | 67% | 76% |
| unknown | 65 | 49% | 5 | 32% | 21% | 59% | 62% |
| medical | 43 | 77% | 4 | 57% | 64% | 70% | 68% |
| track | 42 | 76% | 6 | 16% | 34% | 22% | 18% |
| police | 39 | 62% | 2 | 65% | 81% | 88% | 75% |
| signal | 35 | 63% | 6 | 16% | 27% | 24% | 36% |
| switch | 15 | 93% | 4 | 9% | 11% | 35% | 0% |
| person_on_track | 13 | 85% | 3 | 18% | 29% | 29% | 24% |
| planned_work | 11 | 64% | 4 | 40% | 42% | 11% | 76% |
| fire_smoke | 10 | 60% | 4 | 37% | 20% | 56% | 73% |
| investigation | 7 | 57% | 10 | 83% | – | 21% | – |

A new alert, by what the trains showed when it was posted:

| trains at posting | alerts | feed ever shows it | median lifetime min | gone within 30 min of posting | within 60 |
|---|---|---|---|---|---|
| already late near the station | 253 | 93% | 40 | 39% | 74% |
| on time | 211 | 36% | 41 | 40% | 72% |

The realtime score (delay_service.assess_alert, the app's DelayModel.assess) reads each live alert this way: a status of *active* or *stale*, and the interpretation, starting / in effect / waning / unconfirmed / stale, from the alert's age, the feed's excess lateness near its station now, the peak so far and how long the stops have read normal, with the chance it is gone within 30 minutes from the phase's own record above. The server reads the trajectory from the store's arrivals since posting; the phone from its boards and the lateness it has seen while open.

## Limits

Two weeks of alerts from one collector; ends are only observed while it polls; the station is read from the text, which names the place of the cause rather than every stop affected; the feed's lateness is a median over the whole line, so a localised delay can read as recovered while one segment still crawls. The curves shrink toward their parents, so thin groups lean on the overall shape.
