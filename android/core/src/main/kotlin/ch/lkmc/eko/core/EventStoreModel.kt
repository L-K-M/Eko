package dev.eko.core

import java.util.UUID

class EventStoreModel(generation: String = UUID.randomUUID().toString()) {
    data class Event(val seq: Long, val createdWall: Long)
    data class Pairing(var ackedSeq: Long, var serveFromSeq: Long, val retentionCount: Int)
    data class Gap(val pairingId: String, val generation: String, val fromSeq: Long, val toSeq: Long, val reason: String)

    var generation: String = generation
        private set
    var highWater: Long = 0
        private set
    val events = sortedMapOf<Long, Event>()
    val pairings = mutableMapOf<String, Pairing>()
    val gaps = mutableListOf<Gap>()

    fun append(createdWall: Long = highWater + 1): Long {
        val seq = ++highWater
        events[seq] = Event(seq, createdWall)
        return seq
    }

    fun pair(id: String, retentionCount: Int = 2_000) {
        require(retentionCount > 0)
        pairings.putIfAbsent(id, Pairing(highWater, highWater + 1, retentionCount))
        prune()
    }

    fun ack(id: String, seq: Long, highestAuthorized: Long) {
        val pairing = pairings.getValue(id)
        require(seq >= pairing.ackedSeq) { "ACK regressed" }
        require(seq <= highestAuthorized) { "ACK exceeds authorized sequence" }
        pairing.ackedSeq = seq
        gaps.removeAll { it.pairingId == id && it.toSeq <= seq }
        prune()
    }

    fun applyCountRetention(id: String) {
        val pairing = pairings.getValue(id)
        val effectiveFloor = maxOf(pairing.serveFromSeq, pairing.ackedSeq + 1)
        val needed = events.values.filter { it.seq >= effectiveFloor }
        if (needed.size <= pairing.retentionCount) return
        advanceFloor(id, needed[needed.size - pairing.retentionCount].seq, "retention_count")
    }

    fun applyAgeRetention(id: String, oldestAllowedWall: Long) {
        val pairing = pairings.getValue(id)
        val effectiveFloor = maxOf(pairing.serveFromSeq, pairing.ackedSeq + 1)
        val expired = events.values.filter { it.seq >= effectiveFloor && it.createdWall < oldestAllowedWall }
        if (expired.isNotEmpty()) advanceFloor(id, expired.last().seq + 1, "retention_age")
    }

    fun unpair(id: String) {
        pairings.remove(id)
        gaps.removeAll { it.pairingId == id }
        prune()
    }

    fun reset(newGeneration: String = UUID.randomUUID().toString()) {
        generation = newGeneration
        highWater = 0
        events.clear()
        gaps.clear()
        pairings.replaceAll { _, value -> value.copy(ackedSeq = 0, serveFromSeq = 1) }
    }

    private fun advanceFloor(id: String, newFloor: Long, reason: String) {
        val pairing = pairings.getValue(id)
        if (newFloor <= pairing.serveFromSeq) return
        val from = maxOf(pairing.serveFromSeq, pairing.ackedSeq + 1)
        val to = newFloor - 1
        if (from <= to) mergeGap(Gap(id, generation, from, to, reason))
        pairing.serveFromSeq = newFloor
        prune()
    }

    private fun mergeGap(newGap: Gap) {
        val adjacent = gaps.filter {
            it.pairingId == newGap.pairingId && it.generation == newGap.generation &&
                it.reason == newGap.reason && it.fromSeq <= newGap.toSeq + 1 && it.toSeq + 1 >= newGap.fromSeq
        }
        gaps.removeAll(adjacent.toSet())
        gaps += newGap.copy(
            fromSeq = minOf(newGap.fromSeq, adjacent.minOfOrNull(Gap::fromSeq) ?: newGap.fromSeq),
            toSeq = maxOf(newGap.toSeq, adjacent.maxOfOrNull(Gap::toSeq) ?: newGap.toSeq),
        )
    }

    private fun prune() {
        events.entries.removeIf { (_, event) ->
            pairings.values.none { pairing ->
                event.seq > pairing.ackedSeq && event.seq >= pairing.serveFromSeq
            }
        }
    }
}
