// Port of the logic in ios/WhichWay/WhichWay/Views/RouteConfidence.swift: how far the model trusts a route's arrival,
// from its own figures. The colours are the app's.
package com.whichway.core

import kotlin.math.max
import kotlin.math.min

data class RouteConfidence(val score: Double, val reasons: List<String>) {
    enum class Level { high, fair, low }
    val level: Level get() = if (score >= 0.72) Level.high else if (score >= 0.45) Level.fair else Level.low
    val label: String get() = when (level) { Level.high -> "High confidence"; Level.fair -> "Fair confidence"; Level.low -> "Low confidence" }
    val summary: String get() = reasons.take(2).joinToString(", ")
}

/** `outlookArrivals`: the arrival under each hold assumption, when a hold ahead matters (else empty). */
fun routeConfidence(option: PathOption, itinerary: Itinerary?, outlookArrivals: List<Double>, model: ClientModel?, ctx: HealthContext): RouteConfidence {
    val it = itinerary
    val last = it?.legs?.lastOrNull()
    if (it == null || last == null) {
        val m = max(0.0, option.typicalSec) + option.holdRiskSec
        val reasons = arrayListOf("no train in the feeds yet")
        if (m >= 60) reasons.add("typically ${Fmt.minTxt(m)} lost at this hour")
        return RouteConfidence(0.35, reasons)
    }
    var score = 1.0
    val penalties = ArrayList<Pair<Double, String>>()
    fun take(p: Double, why: String) { score -= p; penalties.add(Pair(p, why)) }
    var windowText = ""
    val lo = last.arriveLoTs; val hi = last.arriveHiTs
    if (lo != null && hi != null) {
        val w = hi - lo
        windowText = "a ${Fmt.minTxt(w)} window"
        if (w > 180) take(min(0.4, (w - 180) / 900), windowText)
    } else take(0.15, "no window from the engine")
    if (model?.etaCalibration != null) {
        val thin = it.legs.filter { Predictor.calibrationAt(model, it.train.route, max(0.0, it.boardTs - ctx.now)).n < 30 }.map { it.train.route }
        if (thin.isNotEmpty()) take(0.08 * thin.size, "few samples on the ${thin.joinToString("/")}")
    }
    val l0 = it.legs[0].train
    if (l0.position?.holding == true) take(0.2, "your train is held")
    else if (l0.position?.stalled == true) take(0.2, "your train is overdue between stops")
    if (l0.corroboration == "feed_optimistic") take(0.1, "the feed looks optimistic for your train")
    else if (l0.corroboration == "position_unknown") take(0.1, "no position report for your train")
    val m = it.connectionMarginSec
    if (it.legs.size > 1 && m != null) { if (m < 60) take(0.25, "a tight change, ${Fmt.mmss(m)} margin") else if (m < 120) take(0.1, "a close change, ${Fmt.mmss(m)} margin") }
    val olo = outlookArrivals.minOrNull(); val ohi = outlookArrivals.maxOrNull()
    if (olo != null && ohi != null && ohi - olo >= 60) take(min(0.3, (ohi - olo) / 900), "a hold ahead could move the arrival ${Fmt.minTxt(ohi - olo)}")
    val seen = HashSet<String>(); var held = 0; var knock = 0
    for (leg in option.legs) for (k in leg.keys) if (seen.add(k)) { ctx.boards[k]?.let { held += it.nHolding + it.nStalled }; ctx.prediction(k)?.let { knock += it.nKnockOn } }
    if (held > 0) take(min(0.1, 0.05 * held), "$held train${if (held == 1) "" else "s"} held or overdue on the way")
    if (knock > 0) take(min(0.1, 0.05 * knock), "$knock held back by the train ahead")
    score = max(0.0, min(1.0, score))
    val why = penalties.filter { it.first > 0 }.sortedByDescending { it.first }.map { it.second }
    return if (why.isEmpty()) RouteConfidence(score, listOf("train in the feeds", windowText).filter { it.isNotEmpty() }) else RouteConfidence(score, why)
}

/** The route's door-to-door time as segments: wait (grey), ride (line colour), walk at the change (dark), wait, ride. `kind`: wait | ride | walk. */
data class JourneySegment(val sec: Double, val kind: String, val route: String)

fun journeySegments(option: PathOption): List<JourneySegment> {
    val out = ArrayList<JourneySegment>()
    val l0 = option.legs[0]
    out.add(JourneySegment(option.wait1Sec, "wait", ""))
    out.add(JourneySegment((l0.schedRideSec ?: 0) + (l0.typicalSec ?: 0.0) + l0.holdRiskSec, "ride", l0.primaryRoute))
    val tr = option.transfer
    if (option.legs.size > 1 && tr != null) {
        val l1 = option.legs[1]
        if (tr.walkSec > 0) out.add(JourneySegment(tr.walkSec.toDouble(), "walk", ""))
        out.add(JourneySegment(option.wait2Sec, "wait", ""))
        out.add(JourneySegment((l1.schedRideSec ?: 0) + (l1.typicalSec ?: 0.0) + l1.holdRiskSec, "ride", l1.primaryRoute))
    }
    return out.map { it.copy(sec = max(0.0, it.sec)) }
}

/** The itinerary after `ride` or the option's next one, on the same route: the train to take if this one is missed. */
fun nextItineraryAfter(ride: Itinerary?, onTrain: Boolean, option: PathOption?, boards: Map<String, LineBoard>, schedule: ClientSchedule?, now: Double): Itinerary? {
    if (ride != null) {
        if (onTrain && ride.legs.size <= 1) return null
        val s = ride.nextIfMissedSec ?: return null
        return ride.copy(boardTs = (if (onTrain) ride.legs[1].boardTs else ride.boardTs) + s, legs = if (onTrain) ride.legs.drop(1) else ride.legs)
    }
    val p = option ?: return null; val it = p.live ?: return null; val sched = schedule ?: return null
    val after = it.boardTs + 30
    return pathTrips(boards, sched, p, now, 3).firstOrNull { n -> n.boardTs > after }
}

/** On the train: how many stops are left before the rider gets off at `offAt`, from the feed's progress. */
fun stopsToGo(c: TripCandidate, option: PathOption, leg: Int, offAt: String): Pair<String, Double> {
    val ix = option.legs.getOrNull(leg)?.idx?.get(c.key) ?: return Pair("", 0.0)
    val total = max(1, ix.to - ix.from)
    val pos = c.train.position
    if (pos != null && !pos.derived && pos.status == "STOPPED_AT" && pos.stopIdx == ix.to) return Pair("At $offAt", 1.0)
    val n = ix.to - c.train.nextIdx + 1
    if (n <= 0) return Pair("Arriving at $offAt", 0.95)
    return Pair("${min(n, total)} stop${if (n == 1) "" else "s"} to go", max(0.0, 1 - min(n, total).toDouble() / total))
}

/** How far a train is from the rider's platform: the words, and a fraction along a ten-stop approach. */
fun stopsAway(c: TripCandidate, option: PathOption, leg: Int = 0): Pair<String, Double> {
    val from = option.legs.getOrNull(leg)?.idx?.get(c.key)?.from ?: return Pair("", 0.0)
    val p = c.train.position
    if (p != null && !p.derived && p.status == "STOPPED_AT" && p.stopIdx == from) return Pair("At the platform", 1.0)
    val n = from - c.train.nextIdx
    if (n <= 0) return Pair("Arriving", 0.95)
    return Pair("$n stop${if (n == 1) "" else "s"} away", max(0.0, 1 - min(n, 10).toDouble() / 10))
}
