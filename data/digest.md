# Subway reliability brief — Oct 17, 2026

## Lines losing the most time (23 days of observed trains)
- **Q southbound**: 24% of stop arrivals ≥5 min late, 8.5 min lost per trip, worst at W 8 St-NY Aquarium (+85 s), peak headway CV 0.83
- **N southbound**: 24% of stop arrivals ≥5 min late, 6.7 min lost per trip, worst at 86 St (+73 s), peak headway CV 0.80
- **F northbound**: 19% of stop arrivals ≥5 min late, 9.7 min lost per trip, worst at 36 St (+51 s), peak headway CV 0.61
- Most reliable: **GS S** (0% ≥5 min late, 0.1 min lost per trip)

## Transfers and routes
- *4 Av-9 St → 14 St-8 Av (F to W 4 St, then A/C/E)*: F and A/C/E lateness at W 4 St-Wash Sq move together (Spearman +0.27, p=0.000, 826 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.7× more often than chance.
- *4 Av-9 St → 14 St-8 Av (F to Jay St, cross-platform to A/C)*: F and A/C lateness at Jay St-MetroTech move together (Spearman +0.22, p=0.000, 800 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.6× more often than chance. The correlation peaks when A/C leads by 15 min, so A/C delays precede F delays.
- *4 Av-9 St → 14 St-8 Av (R to Jay St, then A/C)*: R and A/C lateness at Jay St-MetroTech move together (Spearman +0.02, p=0.664, 769 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.8× more often than chance. The correlation peaks when A/C leads by 15 min, so A/C delays precede R delays.
- *14 St-8 Av → 4 Av-9 St (A/C/E to W 4 St, then F)*: A/C/E and F lateness at W 4 St-Wash Sq move together (Spearman +0.41, p=0.000, 833 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 2.1× more often than chance.
- *14 St-8 Av → 4 Av-9 St (A/C/E to W 4 St, then F)*: F trains that would reach Smith-9 Sts within 180 s behind a G in the weekend lose 45 s more there than free-running F trains (95% CI 13–95 s, p=0.000); 30% of F trips are in that situation, and when that G is itself ≥3 min late the loss is 28 s.
- *14 St-8 Av → 4 Av-9 St (A/C to Jay St, cross-platform to F)*: A/C and F lateness at Jay St-MetroTech move together (Spearman +0.20, p=0.000, 793 bins). Both lines are disrupted (mean lateness ≥4 min) in the same 15 min 1.5× more often than chance. The correlation peaks when A/C leads by 15 min, so A/C delays precede F delays.

## Terminals
- 41750 terminal turns matched: 18% of trips arrive ≥5 min late at the terminal and 18% of those leave late again; median 7.2 min recovered at the terminal

## Alerts
- 545 unplanned alerts studied: trains showed the problem 20 min before the alert was posted; peak excess 2.2 min; service back to normal 50 min after posting

## Disruption climatology
- Archive since 2020: 387 unplanned disruption events per week system-wide; most on A (54.6/wk), F (42.0/wk), 2 (40.2/wk); top cause rolling_stock (34%)

## Prediction model
- Arrival model: 65 s mean error vs 79 s for the schedule and 87 s for the MTA countdown ETA (34% better); 80% range covers 80% of outcomes; trained on 1,200,000 rows

## Holds
- 2469 holds per day (trains stopped ≥ 2.5 min at a station, origin terminals excluded) over 23 days; most held minutes at H19N (H), Atlantic Av-Barclays Ctr (D/N/R/W), Canal St (N/Q/R). Of 14989 long holds (≥ 5 min), 45% had an unplanned alert for the line, posted a median 13 min after the hold began

## Live forecast accuracy
- Live forecasts scored against 26,376 observed arrivals (564 snapshots, 14 days): MTA feed 1.6 min mean error, model 1.6 min, simulation 2.8 min; the model was closer than the feed 52% of the time

---
Generated 2026-10-17T19:04-04:00 from the published analyses; details on each page of the app.