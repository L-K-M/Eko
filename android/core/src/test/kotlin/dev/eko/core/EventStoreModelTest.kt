package dev.eko.core

import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class EventStoreModelTest {
    @Test
    fun `slow pairing cannot delete rows needed by another pairing`() {
        val model = EventStoreModel("generation-a")
        model.pair("mac-a", retentionCount = 3)
        repeat(5) { model.append() }
        model.pair("mac-b", retentionCount = 20)
        repeat(5) { model.append() }

        model.applyCountRetention("mac-a")

        assertEquals(8L, model.pairings.getValue("mac-a").serveFromSeq)
        assertEquals(1L..7L, model.gaps.single().fromSeq..model.gaps.single().toSeq)
        assertTrue((6L..10L).all(model.events::containsKey))

        model.ack("mac-b", seq = 7, highestAuthorized = 10)
        assertTrue((8L..10L).all(model.events::containsKey))
        assertTrue((1L..7L).none(model.events::containsKey))
    }

    @Test
    fun `new pair gets no pre-pair history and reset starts a separate sequence space`() {
        val model = EventStoreModel("old")
        repeat(4) { model.append() }
        model.pair("mac")
        assertEquals(4, model.pairings.getValue("mac").ackedSeq)
        assertTrue(model.events.isEmpty())

        model.reset("new")
        assertEquals(0, model.highWater)
        assertEquals(1, model.pairings.getValue("mac").serveFromSeq)
        assertEquals(1, model.append())
    }

    @Test
    fun `random pruning always retains exactly rows at least one pairing needs`() {
        val random = Random(0xE0)
        repeat(50) {
            val model = EventStoreModel("g-$it")
            model.pair("a", retentionCount = random.nextInt(1, 20))
            model.pair("b", retentionCount = random.nextInt(1, 20))
            repeat(200) {
                model.append(createdWall = it.toLong())
                if (random.nextInt(4) == 0) model.applyCountRetention("a")
                if (random.nextInt(4) == 0) model.applyCountRetention("b")
                if (random.nextInt(8) == 0) {
                    val pairing = model.pairings.getValue("a")
                    val ack = random.nextLong(pairing.ackedSeq, model.highWater + 1)
                    model.ack("a", ack, model.highWater)
                }
            }
            model.applyCountRetention("a")
            model.applyCountRetention("b")
            model.events.values.forEach { event ->
                assertTrue(model.pairings.values.any { event.seq > it.ackedSeq && event.seq >= it.serveFromSeq })
            }
        }
    }
}
