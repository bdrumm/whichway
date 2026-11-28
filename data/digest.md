# Subway reliability brief — Nov 28, 2026

## Lines losing the most time (27 days of observed trains)
- **N northbound**: 70% of stop arrivals ≥5 min late, 5.5 min lost per trip, worst at Astoria Blvd (+103 s)
- **Q northbound**: 36% of stop arrivals ≥5 min late, 5.7 min lost per trip, worst at Parkside Av (+161 s)
- **SI southbound**: 21% of stop arrivals ≥5 min late, 14.8 min lost per trip, worst at Stapleton (+121 s), peak headway CV 0.45
- Most reliable: **GS S** (0% ≥5 min late, 0.0 min lost per trip)

## Transfers and routes
- *4 Av-9 St → 14 St-8 Av (F to W 4 St, then A/C/E)*: A F arriving ≥3 min late at W 4 St-Wash Sq (mean 8.0 min late, n=76) costs riders 1.5 min more downstream than an on-time arrival: 1.0 min at the transfer and 0.5 min on the A/C/E ride.
- *4 Av-9 St → 14 St-8 Av (F to W 4 St, then A/C/E)*: When the F arrives ≥3 min late, the connection wait is +1.0 min vs an on-time arrival (95% CI +0.2 to +1.8, p=0.047, n=76 late / 137 on time); missed connections 77% vs 7%; each minute of F lateness adds about 6 s of A/C/E wait.
- *4 Av-9 St → 14 St-8 Av (F to W 4 St, then A/C/E)*: F and A/C/E lateness at W 4 St-Wash Sq move together (Spearman +0.37, p=0.000, 715 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.9× more often than chance.
- *4 Av-9 St → 14 St-8 Av (F to Jay St, cross-platform to A/C)*: F and A/C lateness at Jay St-MetroTech move together (Spearman +0.36, p=0.000, 666 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.7× more often than chance.
- *4 Av-9 St → 14 St-8 Av (R to Jay St, then A/C)*: R and A/C lateness at Jay St-MetroTech move together (Spearman +0.16, p=0.000, 635 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.3× more often than chance.
- *14 St-8 Av → 4 Av-9 St (A/C/E to W 4 St, then F)*: A/C/E and F lateness at W 4 St-Wash Sq move together (Spearman +0.31, p=0.000, 691 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 2.5× more often than chance.

## Terminals
- 24309 terminal turns matched: 15% of trips arrive ≥5 min late at the terminal and 22% of those leave late again; median 6.9 min recovered at the terminal

## Alerts
- 419 unplanned alerts studied: trains showed the problem 25 min before the alert was posted; peak excess 2.5 min; service back to normal 50 min after posting

## Disruption climatology
- Archive since 2020: 395 unplanned disruption events per week system-wide; most on A (55.3/wk), F (43.5/wk), 2 (40.9/wk); top cause rolling_stock (34%)

## Prediction model
- Arrival model: 61 s mean error vs 77 s for the schedule and 70 s for the MTA countdown ETA (37% better); 80% range covers 80% of outcomes; trained on 1,200,000 rows

## Holds
- 2253 holds per day (trains stopped ≥ 2.5 min at a station, origin terminals excluded) over 30 days; most held minutes at H19N (H), Astor Pl (6), Atlantic Av-Barclays Ctr (D/N/Q/R/W). Of 16290 long holds (≥ 5 min), 40% had an unplanned alert for the line, posted a median 12 min after the hold began

## Live forecast accuracy
- Live forecasts scored against 16,826 observed arrivals (360 snapshots, 14 days): MTA feed 1.7 min mean error, model 1.7 min, simulation 2.6 min; the model was closer than the feed 55% of the time

---
Generated 2026-11-28T06:05-05:00 from the published analyses; details on each page of the app.