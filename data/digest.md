# Subway reliability brief — Nov 21, 2026

## Lines losing the most time (20 days of observed trains)
- **N northbound**: 84% of stop arrivals ≥5 min late, 5.7 min lost per trip, worst at Astoria Blvd (+90 s)
- **N southbound**: 30% of stop arrivals ≥5 min late, 7.4 min lost per trip, worst at 86 St (+59 s), peak headway CV 0.64
- **Q southbound**: 26% of stop arrivals ≥5 min late, 8.8 min lost per trip, worst at W 8 St-NY Aquarium (+78 s), peak headway CV 0.69
- Most reliable: **GS S** (0% ≥5 min late, 0.1 min lost per trip)

## Transfers and routes
- *4 Av-9 St → 14 St-8 Av (F to W 4 St, then A/C/E)*: F and A/C/E lateness at W 4 St-Wash Sq move together (Spearman +0.26, p=0.000, 716 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 2.0× more often than chance. The correlation peaks when F leads by 15 min, so F delays precede A/C/E delays.
- *4 Av-9 St → 14 St-8 Av (F to Jay St, cross-platform to A/C)*: A trains that would reach High St within 180 s behind a C in the evening/night lose 378 s more there than free-running A trains (95% CI 0–1131 s, p=0.042); 24% of A trips are in that situation, and when that C is itself ≥3 min late the loss is 377 s.
- *4 Av-9 St → 14 St-8 Av (F to Jay St, cross-platform to A/C)*: F and A/C lateness at Jay St-MetroTech move together (Spearman +0.22, p=0.000, 643 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.9× more often than chance.
- *4 Av-9 St → 14 St-8 Av (R to Jay St, then A/C)*: A trains that would reach High St within 180 s behind a C in the evening/night lose 378 s more there than free-running A trains (95% CI 0–1131 s, p=0.042); 24% of A trips are in that situation, and when that C is itself ≥3 min late the loss is 377 s.
- *4 Av-9 St → 14 St-8 Av (R to Jay St, then A/C)*: R and A/C lateness at Jay St-MetroTech move together (Spearman +0.09, p=0.032, 632 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 2.6× more often than chance.
- *14 St-8 Av → 4 Av-9 St (A/C/E to W 4 St, then F)*: A/C/E and F lateness at W 4 St-Wash Sq move together (Spearman +0.51, p=0.000, 731 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 2.2× more often than chance.

## Terminals
- 29368 terminal turns matched: 16% of trips arrive ≥5 min late at the terminal and 23% of those leave late again; median 6.8 min recovered at the terminal

## Alerts
- 325 unplanned alerts studied: trains showed the problem 20 min before the alert was posted; peak excess 2.1 min; service back to normal 52 min after posting

## Disruption climatology
- Archive since 2020: 393 unplanned disruption events per week system-wide; most on A (55.3/wk), F (43.1/wk), 2 (40.5/wk); top cause rolling_stock (34%)

## Prediction model
- Arrival model: 64 s mean error vs 78 s for the schedule and 75 s for the MTA countdown ETA (34% better); 80% range covers 80% of outcomes; trained on 1,200,000 rows

## Holds
- 2654 holds per day (trains stopped ≥ 2.5 min at a station, origin terminals excluded) over 30 days; most held minutes at H19N (H), Astor Pl (6), 59 St-Columbus Circle (A/B/C/D/E). Of 19201 long holds (≥ 5 min), 40% had an unplanned alert for the line, posted a median 14 min after the hold began

## Live forecast accuracy
- Live forecasts scored against 19,267 observed arrivals (409 snapshots, 14 days): MTA feed 1.7 min mean error, model 1.7 min, simulation 2.6 min; the model was closer than the feed 50% of the time

---
Generated 2026-11-21T05:30-05:00 from the published analyses; details on each page of the app.