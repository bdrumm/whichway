# Subway reliability brief — Oct 24, 2026

## Lines losing the most time (30 days of observed trains)
- **Q southbound**: 34% of stop arrivals ≥5 min late, 9.6 min lost per trip, worst at W 8 St-NY Aquarium (+93 s), peak headway CV 0.72
- **Q northbound**: 36% of stop arrivals ≥5 min late, 1.7 min lost per trip, worst at Newkirk Plaza (+70 s), peak headway CV 0.69
- **N southbound**: 28% of stop arrivals ≥5 min late, 6.7 min lost per trip, worst at 36 St (+66 s), peak headway CV 0.63
- Most reliable: **GS N** (0% ≥5 min late, 0.0 min lost per trip)

## Transfers and routes
- *4 Av-9 St → 14 St-8 Av (F to W 4 St, then A/C/E)*: A trains that would reach W 4 St-Wash Sq within 180 s behind a C in the evening/night lose 315 s more there than free-running A trains (95% CI 1–933 s, p=0.000); 27% of A trips are in that situation, and when that C is itself ≥3 min late the loss is 314 s.
- *4 Av-9 St → 14 St-8 Av (F to W 4 St, then A/C/E)*: A trains that would reach W 4 St-Wash Sq within 180 s behind a E lose 129 s more there than free-running A trains (95% CI 6–368 s, p=0.001); 41% of A trips are in that situation, and when that E is itself ≥3 min late the loss is 142 s.
- *4 Av-9 St → 14 St-8 Av (F to W 4 St, then A/C/E)*: F and A/C/E lateness at W 4 St-Wash Sq move together (Spearman +0.31, p=0.000, 742 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.9× more often than chance.
- *4 Av-9 St → 14 St-8 Av (F to Jay St, cross-platform to A/C)*: A trains that would reach W 4 St-Wash Sq within 180 s behind a C in the evening/night lose 315 s more there than free-running A trains (95% CI 1–933 s, p=0.000); 27% of A trips are in that situation, and when that C is itself ≥3 min late the loss is 314 s.
- *4 Av-9 St → 14 St-8 Av (F to Jay St, cross-platform to A/C)*: A trains that would reach W 4 St-Wash Sq within 180 s behind a E lose 129 s more there than free-running A trains (95% CI 6–368 s, p=0.001); 41% of A trips are in that situation, and when that E is itself ≥3 min late the loss is 128 s.
- *4 Av-9 St → 14 St-8 Av (F to Jay St, cross-platform to A/C)*: F and A/C lateness at Jay St-MetroTech move together (Spearman +0.25, p=0.000, 784 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.8× more often than chance.

## Terminals
- 38850 terminal turns matched: 19% of trips arrive ≥5 min late at the terminal and 16% of those leave late again; median 7.5 min recovered at the terminal

## Alerts
- 732 unplanned alerts studied: trains showed the problem 25 min before the alert was posted; peak excess 2.1 min; service back to normal 45 min after posting

## Disruption climatology
- Archive since 2020: 388 unplanned disruption events per week system-wide; most on A (54.5/wk), F (42.1/wk), 2 (40.4/wk); top cause rolling_stock (34%)

## Prediction model
- Arrival model: 69 s mean error vs 84 s for the schedule and 79 s for the MTA countdown ETA (35% better); 80% range covers 80% of outcomes; trained on 1,200,000 rows

## Holds
- 2781 holds per day (trains stopped ≥ 2.5 min at a station, origin terminals excluded) over 30 days; most held minutes at H19N (H), Franklin Av (FS), Atlantic Av-Barclays Ctr (D/N/Q/R/W). Of 21656 long holds (≥ 5 min), 47% had an unplanned alert for the line, posted a median 15 min after the hold began

## Live forecast accuracy
- Live forecasts scored against 29,319 observed arrivals (636 snapshots, 14 days): MTA feed 1.6 min mean error, model 1.6 min, simulation 2.7 min; the model was closer than the feed 53% of the time

---
Generated 2026-10-24T16:17-04:00 from the published analyses; details on each page of the app.