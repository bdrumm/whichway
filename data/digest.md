# Subway reliability brief — Nov 07, 2026

## Lines losing the most time (6 days of observed trains)
- **N southbound**: 39% of stop arrivals ≥5 min late, 9.8 min lost per trip, worst at Court St (+65 s), peak headway CV 0.62
- **F southbound**: 32% of stop arrivals ≥5 min late, 14.8 min lost per trip, worst at Avenue N (+187 s), peak headway CV 0.71
- **Q southbound**: 36% of stop arrivals ≥5 min late, 9.6 min lost per trip, worst at W 8 St-NY Aquarium (+71 s), peak headway CV 0.67
- Most reliable: **L S** (4% ≥5 min late, 4.7 min lost per trip)

## Transfers and routes
- *4 Av-9 St → 14 St-8 Av (F to W 4 St, then A/C/E)*: F and A/C/E lateness at W 4 St-Wash Sq move together (Spearman +0.49, p=0.000, 421 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 2.4× more often than chance.
- *4 Av-9 St → 14 St-8 Av (F to W 4 St, then A/C/E)*: A trains that would reach W 4 St-Wash Sq within 180 s behind a C lose 617 s more there than free-running A trains (95% CI 48–1372 s, p=0.000); 40% of A trips are in that situation, and when that C is itself ≥3 min late the loss is 610 s.
- *4 Av-9 St → 14 St-8 Av (F to W 4 St, then A/C/E)*: A trains that would reach W 4 St-Wash Sq within 180 s behind a E lose 600 s more there than free-running A trains (95% CI 36–1351 s, p=0.000); 40% of A trips are in that situation, and when that E is itself ≥3 min late the loss is 519 s.
- *4 Av-9 St → 14 St-8 Av (F to Jay St, cross-platform to A/C)*: F and A/C lateness at Jay St-MetroTech move together (Spearman +0.42, p=0.000, 407 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 2.3× more often than chance.
- *4 Av-9 St → 14 St-8 Av (F to Jay St, cross-platform to A/C)*: A trains that would reach W 4 St-Wash Sq within 180 s behind a C lose 617 s more there than free-running A trains (95% CI 48–1372 s, p=0.000); 40% of A trips are in that situation, and when that C is itself ≥3 min late the loss is 610 s; across 2 shared stops the expected loss is 270 s per A trip.
- *4 Av-9 St → 14 St-8 Av (F to Jay St, cross-platform to A/C)*: A trains that would reach W 4 St-Wash Sq within 180 s behind a E lose 600 s more there than free-running A trains (95% CI 36–1351 s, p=0.000); 40% of A trips are in that situation, and when that E is itself ≥3 min late the loss is 519 s.

## Terminals
- 22546 terminal turns matched: 26% of trips arrive ≥5 min late at the terminal and 53% of those leave late again; median 5.2 min recovered at the terminal

## Alerts
- 102 unplanned alerts studied: trains showed the problem 38 min before the alert was posted; peak excess 3.6 min; service back to normal 50 min after posting

## Disruption climatology
- Archive since 2020: 391 unplanned disruption events per week system-wide; most on A (54.9/wk), F (42.7/wk), 2 (40.4/wk); top cause rolling_stock (34%)

## Prediction model
- Arrival model: 68 s mean error vs 83 s for the schedule and 84 s for the MTA countdown ETA (32% better); 80% range covers 80% of outcomes; trained on 1,200,000 rows

## Holds
- 3197 holds per day (trains stopped ≥ 2.5 min at a station, origin terminals excluded) over 30 days; most held minutes at H19N (H), 59 St-Columbus Circle (A/B/C/D/E), Atlantic Av-Barclays Ctr (D/N/Q/R/W). Of 23475 long holds (≥ 5 min), 46% had an unplanned alert for the line, posted a median 15 min after the hold began

## Live forecast accuracy
- Live forecasts scored against 24,440 observed arrivals (508 snapshots, 14 days): MTA feed 1.6 min mean error, model 1.5 min, simulation 3.9 min; the model was closer than the feed 51% of the time

---
Generated 2026-11-07T05:47-05:00 from the published analyses; details on each page of the app.