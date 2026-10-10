package com.whichway.core

import kotlin.test.Test
import kotlin.test.assertEquals

/** The wire decoder on a tiny hand-built feed (the same bytes as the Swift test). */
class DecoderTest {
    private fun varint(v: Long): List<Byte> {
        val out = ArrayList<Byte>(); var x = v
        do { var b = (x and 0x7f).toInt(); x = x ushr 7; if (x != 0L) b = b or 0x80; out.add(b.toByte()) } while (x != 0L)
        return out
    }
    private fun bytes(n: Int, b: List<Byte>) = varint((n shl 3 or 2).toLong()) + varint(b.size.toLong()) + b
    private fun vfield(n: Int, v: Long) = varint((n shl 3).toLong()) + varint(v)
    private fun str(n: Int, s: String) = bytes(n, s.toByteArray().toList())

    @Test
    fun decoderRoundTrip() {
        val trip = str(1, "010000_6..N") + str(3, "20260101") + str(5, "6")
        val stu1 = str(4, "635N") + bytes(2, vfield(2, 1_000_100))
        val stu2 = str(4, "634N") + bytes(2, vfield(2, 1_000_220))
        val tu = bytes(1, trip) + bytes(2, stu1) + bytes(2, stu2)
        val veh = bytes(1, trip) + vfield(4, 2) + vfield(5, 999_980) + str(7, "635N")
        val msg = bytes(1, vfield(3, 1_000_000)) + bytes(2, str(1, "e1") + bytes(3, tu)) + bytes(2, str(1, "e2") + bytes(4, veh))
        val feed = GtfsRealtime.parse(msg.toByteArray())
        assertEquals(1_000_000.0, feed.timestamp)
        assertEquals(1, feed.trips.size)
        assertEquals(listOf("635N", "634N"), feed.trips[0].stops.map { it.stopId })
        assertEquals(1_000_220.0, feed.trips[0].stops[1].arrival)
        assertEquals("IN_TRANSIT_TO", feed.vehicles.first().status)
        assertEquals("010000_6..N", tripStem("010000_6..N01R"))

        // the feed through the board: one started train on 6_N, two stops ahead
        val sched = ClientSchedule.parse("""{"lines": {"6_N": {"stops": ["635N", "634N"], "names": ["14 St", "23 St"], "run_sec": [90], "dist_m": [700]}}}""")
        val board = lineBoard(sched, emptyList(), mapOf("x" to feed), "6_N", 1_000_000.0, VehicleHistory())!!
        assertEquals(1, board.trains.size)
        assertEquals(0, board.trains[0].nextIdx)
        assertEquals("→ 14 St", board.trains[0].position?.text)
        // a trip with no vehicle report at all, assigned and at its first stop: placed by its trip update, at the terminal
        val tu2 = bytes(1, str(1, "020000_6..N") + str(3, "20260101") + str(5, "6") + bytes(1001, str(1, "06 0200 PEL/BBR") + vfield(2, 1))) + bytes(2, str(4, "635N") + bytes(2, vfield(2, 1_000_300)))
        val feed2 = GtfsRealtime.parse((bytes(1, vfield(3, 1_000_000)) + bytes(2, str(1, "e3") + bytes(3, tu2))).toByteArray())
        val b2 = lineBoard(sched, emptyList(), mapOf("x" to feed2), "6_N", 1_000_000.0, VehicleHistory())!!
        assertEquals(1, b2.trains.size)
        val pos = b2.trains[0].position!!
        assertEquals(true, pos.derived); assertEquals("STOPPED_AT", pos.status); assertEquals("at 14 St · not yet departed", pos.text)
        assertEquals("unknown", trainProgress(b2.trains[0], 0.0, sched.lines["6_N"]!!).state)
    }
}
