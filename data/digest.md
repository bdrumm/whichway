# Subway reliability brief — Nov 14, 2026

## Lines losing the most time (14 days of observed trains)
- **N northbound**: 100% of stop arrivals ≥5 min late, 6.7 min lost per trip, worst at Astoria Blvd (+114 s), peak headway CV 0.53
- **N southbound**: 34% of stop arrivals ≥5 min late, 9.8 min lost per trip, worst at 36 St (+69 s), peak headway CV 0.60
- **Q southbound**: 33% of stop arrivals ≥5 min late, 10.2 min lost per trip, worst at W 8 St-NY Aquarium (+62 s), peak headway CV 0.64
- Most reliable: **GS S** (0% ≥5 min late, 0.1 min lost per trip)

## Transfers and routes
- *4 Av-9 St → 14 St-8 Av (F to W 4 St, then A/C/E)*: F and A/C/E lateness at W 4 St-Wash Sq move together (Spearman +0.26, p=0.000, 798 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 2.1× more often than chance.
- *4 Av-9 St → 14 St-8 Av (F to Jay St, cross-platform to A/C)*: A trains that would reach Jay St-MetroTech within 180 s behind a C in the evening/night lose 293 s more there than free-running A trains (95% CI 6–854 s, p=0.039); 24% of A trips are in that situation, and when that C is itself ≥3 min late the loss is 320 s; across 2 shared stops the expected loss is 96 s per A trip.
- *4 Av-9 St → 14 St-8 Av (F to Jay St, cross-platform to A/C)*: F and A/C lateness at Jay St-MetroTech move together (Spearman +0.25, p=0.000, 775 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.8× more often than chance.
- *4 Av-9 St → 14 St-8 Av (R to Jay St, then A/C)*: R and A/C lateness at Jay St-MetroTech move together (Spearman +0.25, p=0.000, 759 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 3.1× more often than chance.
- *4 Av-9 St → 14 St-8 Av (R to Jay St, then A/C)*: A trains that would reach Jay St-MetroTech within 180 s behind a C in the evening/night lose 293 s more there than free-running A trains (95% CI 6–854 s, p=0.039); 24% of A trips are in that situation, and when that C is itself ≥3 min late the loss is 320 s; across 2 shared stops the expected loss is 96 s per A trip.
- *14 St-8 Av → 4 Av-9 St (A/C/E to W 4 St, then F)*: A/C/E and F lateness at W 4 St-Wash Sq move together (Spearman +0.42, p=0.000, 797 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 2.3× more often than chance.

## Terminals
- 35510 terminal turns matched: 16% of trips arrive ≥5 min late at the terminal and 18% of those leave late again; median 7.0 min recovered at the terminal

## Alerts
- 228 unplanned alerts studied: trains showed the problem 20 min before the alert was posted; peak excess 3.1 min; service back to normal 45 min after posting

## Disruption climatology
- Archive since 2020: 392 unplanned disruption events per week system-wide; most on A (55.0/wk), F (42.7/wk), 2 (40.4/wk); top cause rolling_stock (34%)

## Prediction model
- Arrival model: 63 s mean error vs 76 s for the schedule and 84 s for the MTA countdown ETA (34% better); 80% range covers 80% of outcomes; trained on 1,200,000 rows

## Holds
- 3064 holds per day (trains stopped ≥ 2.5 min at a station, origin terminals excluded) over 30 days; most held minutes at H19N (H), 59 St-Columbus Circle (A/B/C/D/E), Atlantic Av-Barclays Ctr (D/N/Q/R/W). Of 22386 long holds (≥ 5 min), 43% had an unplanned alert for the line, posted a median 16 min after the hold began

## Live forecast accuracy
- Live forecasts scored against 20,932 observed arrivals (457 snapshots, 14 days): MTA feed 1.7 min mean error, model 1.7 min, simulation 2.7 min; the model was closer than the feed 46% of the time

---
Generated 2026-11-14T12:51-05:00 from the published analyses; details on each page of the app.