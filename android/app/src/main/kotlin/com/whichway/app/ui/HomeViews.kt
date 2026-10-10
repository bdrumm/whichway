// Port of ios/WhichWay/WhichWay/Views/HomeViews.swift: the Go tab's home (the countdown, the route's lines, when you
// arrive, the change and the next best ways as numbers), the journey bar, the strand view, the mini strands and the
// corner glow in the colour of the time to the train.
package com.whichway.app.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.whichway.app.trip.TripUi
import com.whichway.core.Fmt
import com.whichway.core.Itinerary
import com.whichway.core.PathOption
import com.whichway.core.RouteConfidence
import com.whichway.core.RouteHealth
import com.whichway.core.TripCandidate
import com.whichway.core.TripPhase
import com.whichway.core.journeySegments
import com.whichway.core.stopsAway
import com.whichway.core.stopsToGo
import kotlin.math.abs
import kotlin.math.max

fun RouteConfidence.color(): Color = when (level) { RouteConfidence.Level.high -> Color(0xFF30D159); RouteConfidence.Level.fair -> Color(0xFFFFD60A); RouteConfidence.Level.low -> Color(0xFFFF9E0A) }

/** The glow's colour on the time to the train: blue while there is time, yellow as it nears, red when it is about to leave. */
fun boardingUrgency(secondsLeft: Double, walkSec: Double?, accent: Color): Color {
    val yellow = Color(0xFFFFD60A); val red = Color(0xFFFF453A)
    if (walkSec != null) { val slack = secondsLeft - walkSec; return if (slack >= 180) accent else if (slack >= 60) yellow else red }
    return if (secondsLeft >= 90) accent else if (secondsLeft >= 30) yellow else red
}

/** One soft wash of colour from the page's top-left corner; the only glow on the Go tab. */
@Composable
fun GlowWash(color: Color, soft: Boolean) {
    val w = if (soft) 0.5f else 0.34f
    Box(Modifier.fillMaxSize().background(Brush.radialGradient(0f to color.copy(alpha = w), 0.4f to color.copy(alpha = w * 0.45f), 0.75f to color.copy(alpha = w * 0.12f), 1f to color.copy(alpha = 0f), center = Offset(0f, 0f), radius = 1300f)))
}

/** The route's door-to-door time as a strip. */
@Composable
fun JourneyBar(option: PathOption, height: androidx.compose.ui.unit.Dp = 14.dp) {
    val segs = journeySegments(option)
    val total = max(1.0, segs.sumOf { it.sec })
    val grey = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.22f); val dark = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f)
    Row(Modifier.fillMaxWidth().height(height).clip(CircleShape), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        segs.forEach { s -> Box(Modifier.weight((s.sec / total).toFloat().coerceAtLeast(0.004f)).fillMaxSize().background(when (s.kind) { "ride" -> routeColor(s.route); "walk" -> dark; else -> grey })) }
    }
}

private fun offAtName(option: PathOption, rideLeg: Int, destName: String) = if (option.legs.size > 1 && rideLeg == 0) (option.transfer?.station ?: "the change") else destName

/** The home: the countdown, the lines, when it boards, the walk, the bar, the arrival with its confidence, the change, the other ways. */
@Composable
fun HomeCard(option: PathOption, itinerary: Itinerary?, next: Itinerary?, now: Double, originName: String, destName: String, trip: TripUi,
             walk: Pair<String, Boolean>?, alternatives: List<PathOption>, moreCount: Int, confidence: RouteConfidence?, health: RouteHealth, altHealth: (PathOption) -> RouteHealth,
             feedsEmpty: Boolean, onPick: (PathOption) -> Unit, onMore: () -> Unit) {
    val onTrain = trip.onTrain; val rideLeg = trip.currentLeg
    val offAt = offAtName(option, rideLeg, destName)
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    Column(Modifier.fillMaxWidth()) {
        // the countdown
        val l0 = itinerary?.legs?.firstOrNull()
        when {
            onTrain && l0 != null -> {
                Text(Fmt.mmss(max(0.0, l0.arriveTs - now)), fontSize = 96.sp, fontWeight = FontWeight.Black, letterSpacing = (-3).sp, maxLines = 1)
                Text("${if (trip.ridePresumed) "presumably on the" else "on the"} ${trip.ridingRoute ?: l0.train.route} · off at $offAt ${Fmt.hhmm(l0.arriveTs)}", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            itinerary != null -> Text(Fmt.mmss(max(0.0, itinerary.boardTs - now)), fontSize = 96.sp, fontWeight = FontWeight.Black, letterSpacing = (-3).sp, maxLines = 1)
            else -> { Text(Fmt.minTxt(option.expectedSec), fontSize = 64.sp, fontWeight = FontWeight.Black, letterSpacing = (-2).sp, maxLines = 1); Text("expected door to door", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = secondary) }
        }
        // the indicator: the route's lines, the train's own where one is in the feeds
        Spacer(Modifier.height(14.dp))
        val legs = option.legs
        val first: TripCandidate? = if (rideLeg == 0) itinerary?.legs?.firstOrNull() else null
        val second: TripCandidate? = if (legs.size > 1) (if (rideLeg == 0) itinerary?.legs?.getOrNull(1) else itinerary?.legs?.firstOrNull()) else null
        val r0 = first?.let { listOf(if (onTrain) (trip.ridingRoute ?: it.train.route) else it.train.route) } ?: legs[0].routes
        val r1 = if (legs.size > 1) (second?.let { listOf(it.train.route) } ?: legs[1].routes) else null
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.alpha(if (rideLeg > 0) 0.45f else 1f)) { RouteBullets(r0, 32.dp) }
            val tr = option.transfer
            if (r1 != null && tr != null) {
                Text("→", color = secondary, fontWeight = FontWeight.SemiBold)
                RouteBullets(r1, 32.dp)
                Text(buildString { append(if (rideLeg > 0) "changed at " else "change at "); append(tr.station) }, maxLines = 1, overflow = TextOverflow.Ellipsis)
            } else Text("direct · ${legs[0].nStops} stops", color = secondary)
        }
        // when it boards and where the train is now; on the train, the stops left
        Spacer(Modifier.height(8.dp))
        if (itinerary != null && l0 != null) {
            val whereNow = if (onTrain) stopsToGo(l0, option, rideLeg, offAt) else stopsAway(l0, option, rideLeg)
            val pos = l0.train.position?.text?.let { " · $it" } ?: ""
            if (onTrain) Text(whereNow.first + pos, color = secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            else Text("boards ${Fmt.hhmm(itinerary.boardTs)} · ${whereNow.first}$pos", color = secondary, maxLines = 2)
        } else Text(if (feedsEmpty) "waiting for the live feeds" else "no train for this route in the feeds yet", color = secondary)
        if (walk != null && (trip.phase == null || trip.phase == TripPhase.approaching)) {
            Spacer(Modifier.height(6.dp))
            Text((if (walk.second) "⚠ " else "🚶 ") + walk.first, style = MaterialTheme.typography.bodyMedium, fontWeight = if (walk.second) FontWeight.SemiBold else FontWeight.Normal, color = if (walk.second) Color(0xFFEF6C00) else secondary, maxLines = 1)
        }
        Spacer(Modifier.height(14.dp)); JourneyBar(option)
        HorizontalDivider(Modifier.padding(vertical = 22.dp), color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.1f))
        // arrive
        if (itinerary != null) {
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(Fmt.hhmm(itinerary.arriveTs), fontSize = 42.sp, fontWeight = FontWeight.Bold, letterSpacing = (-1).sp)
                Text("arrive · ${Fmt.minTxt(itinerary.totalSec)}", style = MaterialTheme.typography.bodyMedium, color = secondary, modifier = Modifier.padding(bottom = 6.dp))
                if (health.extraSec >= 90) Text(health.label, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = health.textColor(), modifier = Modifier.padding(bottom = 6.dp))
            }
            val last = itinerary.legs.last()
            Text(if (last.arriveLoTs != null && last.arriveHiTs != null) "likely ${Fmt.hhmm(last.arriveLoTs)} to ${Fmt.hhmm(last.arriveHiTs)}" else "engine estimate", style = MaterialTheme.typography.bodyMedium, color = secondary)
        } else {
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(Fmt.minTxt(option.expectedSec), fontSize = 42.sp, fontWeight = FontWeight.Bold, letterSpacing = (-1).sp)
                Text("expected to $destName", style = MaterialTheme.typography.bodyMedium, color = secondary, maxLines = 1, modifier = Modifier.padding(bottom = 6.dp))
            }
            Text("${Fmt.minTxt(option.schedSec.toDouble())} scheduled · with the waits and typical losses", style = MaterialTheme.typography.bodyMedium, color = secondary, maxLines = 1)
        }
        if (confidence != null) {
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Surface(shape = CircleShape, color = confidence.color(), modifier = Modifier.size(7.dp)) {}
                Text(buildString { append(confidence.label); append(" · "); append(confidence.summary) }, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        // the change
        Spacer(Modifier.height(20.dp))
        val tr = option.transfer
        if (legs.size > 1 && tr != null) {
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(tr.station, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(when { rideLeg > 0 -> "changed"; itinerary != null && itinerary.legs.size > 1 -> "off ${Fmt.hhmm(itinerary.legs[0].arriveTs)} · on ${Fmt.hhmm(itinerary.legs[1].boardTs)}"; else -> "change" }, style = MaterialTheme.typography.bodyMedium, color = secondary, modifier = Modifier.padding(bottom = 3.dp))
            }
            val walkText = if (tr.walkSec > 0) "${Fmt.mmss(tr.walkSec.toDouble())} walk" else "same platform"
            val m = itinerary?.connectionMarginSec
            val detail = when {
                rideLeg > 0 && l0 != null -> "on the ${l0.train.route} · ${Fmt.minTxt(l0.rideSec)} ride"
                itinerary != null && itinerary.legs.size > 1 && m != null -> "${Fmt.mmss(m)} margin · $walkText" + (itinerary.nextIfMissedSec?.let { " · +${Fmt.mmss(it)} if missed" } ?: "")
                onTrain -> "connection not in the feeds yet · $walkText"
                else -> "$walkText between platforms"
            }
            Text(detail, style = MaterialTheme.typography.bodyMedium, color = if (rideLeg == 0 && (m ?: 999.0) < 60) Color(0xFFD32F2F) else secondary, maxLines = 1)
        } else {
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Direct", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                Text("${legs[0].nStops} stops", style = MaterialTheme.typography.bodyMedium, color = secondary, modifier = Modifier.padding(bottom = 3.dp))
            }
            Text("${Fmt.minTxt(legs[0].schedRideSec?.toDouble())} scheduled ride" + (legs[0].typicalSec?.let { if (abs(it) >= 30) " · typically ${Fmt.signed(it)}" else "" } ?: ""), style = MaterialTheme.typography.bodyMedium, color = secondary, maxLines = 1)
        }
        HorizontalDivider(Modifier.padding(vertical = 22.dp), color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.1f))
        // the other ways
        if (alternatives.isEmpty()) Text("the only route with at most one change", style = MaterialTheme.typography.bodyMedium, color = secondary)
        alternatives.forEach { p ->
            Row(Modifier.fillMaxWidth().clickable { onPick(p) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                RouteBullets(p.legs[0].routes, 18.dp)
                if (p.legs.size > 1) { Text("→", color = secondary, modifier = Modifier.padding(horizontal = 2.dp)); RouteBullets(p.legs[1].routes, 18.dp) }
                Text(p.transfer?.let { "at ${it.station}" } ?: "direct", color = secondary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(start = 6.dp).weight(1f))
                val h = altHealth(p)
                Text(Fmt.minTxt(p.live?.totalSec ?: p.expectedSec), fontWeight = FontWeight.SemiBold, color = if (h.level == RouteHealth.Level.smooth) MaterialTheme.colorScheme.onSurface else h.textColor())
            }
        }
        if (alternatives.isNotEmpty()) Text((if (moreCount > 0) "$moreCount more way${if (moreCount == 1) "" else "s"}" else "all the ways") + " ›", style = MaterialTheme.typography.bodyMedium, color = secondary, modifier = Modifier.clickable(onClick = onMore).padding(vertical = 6.dp))
    }
}

/** A route as a faded thread the height of its rides, with its lines at the top and its time below. */
@Composable
fun MiniStrand(option: PathOption, total: String, onClick: () -> Unit) {
    val l0 = option.legs[0]
    val r0 = (l0.schedRideSec ?: 0) + (l0.typicalSec ?: 0.0)
    val r1 = if (option.legs.size > 1) (option.legs[1].schedRideSec ?: 0) + (option.legs[1].typicalSec ?: 0.0) else 0.0
    val scale = 90 / max(60.0, r0 + r1)
    Column(Modifier.width(60.dp).alpha(0.7f).clickable(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        RouteBullets(l0.routes.take(2), 14.dp)
        Box(Modifier.width(4.dp).height(max(10.0, r0 * scale).dp).clip(CircleShape).background(routeColor(l0.primaryRoute)))
        if (option.legs.size > 1) Box(Modifier.width(4.dp).height(max(10.0, r1 * scale).dp).clip(CircleShape).background(routeColor(option.legs[1].primaryRoute)))
        Text(total, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

/** The route as a thread down the screen: the train coming, the origin with the countdown, the change, the destination. */
@Composable
fun StrandView(option: PathOption, itinerary: Itinerary?, next: Itinerary?, now: Double, originName: String, destName: String, trip: TripUi,
               alternatives: List<PathOption>, confidence: RouteConfidence?, feedsEmpty: Boolean, onPick: (PathOption) -> Unit, onDetails: () -> Unit, onInsights: () -> Unit) {
    val onTrain = trip.onTrain; val rideLeg = trip.currentLeg
    val leg0 = if (rideLeg == 0) itinerary?.legs?.firstOrNull() else null
    val leg1 = if (option.legs.size > 1) (if (rideLeg == 0) itinerary?.legs?.getOrNull(1) else itinerary?.legs?.firstOrNull()) else null
    val route0 = leg0?.let { if (onTrain) (trip.ridingRoute ?: it.train.route) else it.train.route } ?: option.legs[0].primaryRoute
    val route1 = if (option.legs.size > 1) (leg1?.train?.route ?: option.legs[1].primaryRoute) else null
    val c0 = routeColor(route0); val c1 = route1?.let { routeColor(it) }
    val offAt = offAtName(option, rideLeg, destName)
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant; val bg = MaterialTheme.colorScheme.surface

    @Composable fun row(node: Color?, filled: Boolean = false, small: Boolean = false, line: Color?, dotted: Boolean = false, minHeight: androidx.compose.ui.unit.Dp, content: @Composable () -> Unit) {
        Row(Modifier.fillMaxWidth().height(androidx.compose.ui.unit.Dp.Unspecified).padding(0.dp), verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Canvas(Modifier.width(36.dp).height(minHeight)) {
                val cx = size.width / 2
                if (line != null) drawLine(line, Offset(cx, if (node == null) 0f else 10.dp.toPx()), Offset(cx, size.height), (if (dotted) 2.dp else 6.dp).toPx(), cap = StrokeCap.Round,
                    pathEffect = if (dotted) PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 6.dp.toPx())) else null)
                if (node != null) {
                    if (small) drawCircle(node, 5.dp.toPx(), Offset(cx, 10.dp.toPx()))
                    else if (filled) drawCircle(node, 10.dp.toPx(), Offset(cx, 10.dp.toPx()))
                    else { drawCircle(bg, 10.dp.toPx(), Offset(cx, 10.dp.toPx())); drawCircle(node, 7.5f.dp.toPx(), Offset(cx, 10.dp.toPx()), style = Stroke(5.dp.toPx())) }
                }
            }
            Box(Modifier.weight(1f)) { content() }
        }
    }

    Column(Modifier.fillMaxWidth()) {
        val l0 = itinerary?.legs?.firstOrNull()
        if (l0 != null) {
            val whereNow = if (onTrain) stopsToGo(l0, option, rideLeg, offAt) else stopsAway(l0, option, rideLeg)
            val pos = l0.train.position?.text?.let { " · $it" } ?: ""
            row(c0.copy(alpha = 0.8f), small = true, line = c0.copy(alpha = 0.6f), dotted = true, minHeight = 44.dp) { Caption("${if (onTrain) "on the" else "the"} ${l0.train.route} · ${whereNow.first}$pos") }
        } else row(null, line = null, minHeight = 24.dp) { Caption(if (feedsEmpty) "waiting for the live feeds" else "no train for this route in the feeds yet") }
        row(c0, line = c0, minHeight = 116.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(originName, style = MaterialTheme.typography.titleMedium, maxLines = 1)
                    if (rideLeg > 0) Caption("ridden") else if (itinerary != null) Caption(if (onTrain) "left ${Fmt.hhmm(itinerary.boardTs)}" else "board ${Fmt.hhmm(itinerary.boardTs)}")
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (rideLeg == 0 && itinerary != null && l0 != null) {
                        Text(Fmt.mmss(max(0.0, (if (onTrain) l0.arriveTs else itinerary.boardTs) - now)), fontSize = 50.sp, fontWeight = FontWeight.Black, letterSpacing = (-2).sp, maxLines = 1)
                        RouteBullet(route0, 28.dp)
                    } else {
                        Box(Modifier.alpha(if (rideLeg > 0) 0.45f else 1f)) { RouteBullets(if (rideLeg > 0) listOf(route0) else option.legs[0].routes, 28.dp) }
                        if (rideLeg == 0) Text("no train yet", style = MaterialTheme.typography.titleMedium, color = secondary)
                    }
                }
                if (onTrain && rideLeg == 0) Caption("off at $offAt")
                else if (rideLeg == 0 && next != null && next.legs.isNotEmpty()) Caption("then ${next.legs[0].train.route} ${Fmt.hhmm(next.boardTs)}" + (itinerary?.nextIfMissedSec?.let { " · +${Fmt.mmss(it)} if missed" } ?: ""))
            }
        }
        if (option.legs.size > 1) {
            val tr = option.transfer
            val walkText = if ((tr?.walkSec ?: 0) > 0) "${Fmt.mmss(tr!!.walkSec.toDouble())} walk" else "same platform"
            val margin = if (rideLeg == 0) itinerary?.connectionMarginSec else null
            row(c0, line = secondary.copy(alpha = 0.8f), dotted = true, minHeight = 58.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(tr?.station ?: "the change", style = MaterialTheme.typography.titleMedium, maxLines = 1)
                        if (rideLeg > 0) Caption("changed") else if (l0 != null) Caption("off ${Fmt.hhmm(l0.arriveTs)}")
                    }
                    Caption(walkText + (margin?.let { " · ${Fmt.mmss(it)} margin" } ?: ""), if ((margin ?: 999.0) < 60) Color(0xFFD32F2F) else secondary)
                }
            }
            val riding = onTrain && rideLeg > 0
            row(c1 ?: c0, line = c1 ?: c0, minHeight = if (riding) 100.dp else 58.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        RouteBullets(leg1?.let { listOf(it.train.route) } ?: option.legs[1].routes, 22.dp)
                        if (riding && leg1 != null) Text(Fmt.mmss(max(0.0, leg1.arriveTs - now)), fontSize = 38.sp, fontWeight = FontWeight.Black, letterSpacing = (-1).sp)
                        else if (leg1 != null) Text("at ${Fmt.hhmm(leg1.boardTs)}", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                        else Caption("connection not in the feeds yet")
                    }
                    if (riding) Caption("off at $destName") else if (leg1 != null) Caption("${Fmt.minTxt(leg1.rideSec)} ride")
                }
            }
        }
        row(c1 ?: c0, filled = true, line = null, minHeight = 60.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(if (itinerary != null) Fmt.hhmm(itinerary.arriveTs) else Fmt.minTxt(option.expectedSec), fontSize = 30.sp, fontWeight = FontWeight.Bold)
                    Text(destName, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(bottom = 4.dp))
                }
                val bits = ArrayList<String>()
                if (itinerary != null) { val last = itinerary.legs.last(); if (last.arriveLoTs != null && last.arriveHiTs != null) bits.add("likely ${Fmt.hhmm(last.arriveLoTs)} to ${Fmt.hhmm(last.arriveHiTs)}"); bits.add("${Fmt.minTxt(itinerary.totalSec)} door to door") }
                else bits.add("expected · ${Fmt.minTxt(option.expectedSec)} door to door")
                confidence?.let { bits.add(it.label.lowercase()) }
                Caption(bits.joinToString(" · "))
            }
        }
        if (alternatives.isNotEmpty()) {
            Spacer(Modifier.height(24.dp))
            Text("Other ways", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = secondary)
            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.Top) { alternatives.take(4).forEach { p -> MiniStrand(p, Fmt.minTxt(p.live?.totalSec ?: p.expectedSec)) { onPick(p) } } }
        }
        Spacer(Modifier.height(24.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(onClick = onDetails) { Text("Track · Time · Board · Map · Hours", style = MaterialTheme.typography.labelMedium) }
            OutlinedButton(onClick = onInsights) { Text("Insights", style = MaterialTheme.typography.labelMedium) }
        }
    }
}
