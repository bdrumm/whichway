# Subway reliability brief — Oct 10, 2026

## Lines losing the most time (16 days of observed trains)
- **F southbound**: 29% of stop arrivals ≥5 min late, 11.6 min lost per trip, worst at W 8 St-NY Aquarium (+107 s), peak headway CV 0.72
- **F northbound**: 26% of stop arrivals ≥5 min late, 12.0 min lost per trip, worst at 36 St (+52 s), peak headway CV 0.63
- **A northbound**: 25% of stop arrivals ≥5 min late, 10.0 min lost per trip, worst at Beach 60 St (+49 s), peak headway CV 0.67
- Most reliable: **GS N** (0% ≥5 min late, 0.0 min lost per trip)

## Transfers and routes
- *4 Av-9 St → 14 St-8 Av (F to W 4 St, then A/C/E)*: F and A/C/E lateness at W 4 St-Wash Sq move together (Spearman +0.21, p=0.000, 786 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.5× more often than chance.
- *4 Av-9 St → 14 St-8 Av (F to Jay St, cross-platform to A/C)*: F and A/C lateness at Jay St-MetroTech move together (Spearman +0.16, p=0.000, 792 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.1× more often than chance.
- *4 Av-9 St → 14 St-8 Av (R to Jay St, then A/C)*: R and A/C lateness at Jay St-MetroTech move together (Spearman +0.07, p=0.041, 755 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.8× more often than chance. The correlation peaks when R leads by 15 min, so R delays precede A/C delays.
- *14 St-8 Av → 4 Av-9 St (A/C/E to W 4 St, then F)*: A/C/E and F lateness at W 4 St-Wash Sq move together (Spearman +0.53, p=0.000, 777 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.8× more often than chance.
- *14 St-8 Av → 4 Av-9 St (A/C to Jay St, cross-platform to F)*: A trains that would reach High St within 180 s behind a C in the weekend lose 391 s more there than free-running A trains (95% CI 2–1164 s, p=0.007); 20% of A trips are in that situation, and when that C is itself ≥3 min late the loss is 392 s; across 2 shared stops the expected loss is 152 s per A trip.
- *14 St-8 Av → 4 Av-9 St (A/C to Jay St, cross-platform to F)*: A/C and F lateness at Jay St-MetroTech move together (Spearman +0.39, p=0.000, 780 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.5× more often than chance.

## Terminals
- 42258 terminal turns matched: 21% of trips arrive ≥5 min late at the terminal and 15% of those leave late again; median 7.6 min recovered at the terminal

## Alerts
- 380 unplanned alerts studied: trains showed the problem 25 min before the alert was posted; peak excess 2.6 min; service back to normal 50 min after posting

## Disruption climatology
- Archive since 2020: 387 unplanned disruption events per week system-wide; most on A (54.4/wk), F (42.0/wk), 2 (40.1/wk); top cause rolling_stock (34%)

## Prediction model
- Arrival model: 66 s mean error vs 77 s for the schedule and 79 s for the MTA countdown ETA (39% better); 80% range covers 80% of outcomes; trained on 1,200,000 rows

## Holds
- 2057 holds per day (trains stopped ≥ 2.5 min at a station, origin terminals excluded) over 16 days; most held minutes at H19N (H), Franklin Av (FS), Canal St (N/Q/R). Of 9047 long holds (≥ 5 min), 46% had an unplanned alert for the line, posted a median 14 min after the hold began

## Live forecast accuracy
- Live forecasts scored against 24,941 observed arrivals (530 snapshots, 14 days): MTA feed 1.6 min mean error, model 1.5 min, simulation 3.1 min; the model was closer than the feed 52% of the time

---
Generated 2026-10-10T18:56-04:00 from the published analyses; details on each page of the app.