import json
import struct
import unittest

from tools.eko_harness import (
    MAX_FRAME_LENGTH,
    ChaosConfig,
    CursorAhead,
    FrameDecoder,
    IncompleteFrame,
    ProtocolError,
    ReferenceMac,
    ReferencePhone,
    canonical_json_bytes,
    decode_json_payload,
    detect_truncated_frame,
    encode_frame,
    encode_json_frame,
    run_chaos,
    run_framed_simulation,
)


class FramingTests(unittest.TestCase):
    def test_round_trip_at_every_split(self):
        message = {"type": "hello", "name": "synthetic", "value": 17}
        encoded = encode_json_frame(message)
        for split in range(len(encoded) + 1):
            decoder = FrameDecoder()
            frames = decoder.feed(encoded[:split])
            frames.extend(decoder.feed(encoded[split:]))
            decoder.finish()
            self.assertEqual(len(frames), 1)
            self.assertEqual(decode_json_payload(*frames[0]), message)

    def test_coalesced_frames(self):
        first = encode_json_frame({"type": "ping", "id": 1})
        second = encode_json_frame({"type": "pong", "id": 1})
        decoder = FrameDecoder()
        frames = decoder.feed(first + second)
        decoder.finish()
        self.assertEqual([decode_json_payload(*frame)["type"] for frame in frames], ["ping", "pong"])

    def test_rejects_zero_and_oversized_lengths_before_body(self):
        with self.assertRaises(ProtocolError):
            FrameDecoder().feed(struct.pack(">I", 0))
        with self.assertRaises(ProtocolError):
            FrameDecoder().feed(struct.pack(">I", MAX_FRAME_LENGTH + 1))
        with self.assertRaises(ProtocolError):
            encode_frame(1, b"x" * MAX_FRAME_LENGTH)

    def test_rejects_duplicate_keys_and_invalid_utf8(self):
        with self.assertRaises(ProtocolError):
            decode_json_payload(1, b'{"type":"ping","type":"pong"}')
        with self.assertRaises(ProtocolError):
            decode_json_payload(1, b'{"type":"ping","bad":"\xff"}')

    def test_truncated_prefix_and_body(self):
        encoded = encode_json_frame({"type": "hello", "value": "abc"})
        for cut in (1, 3, 4, len(encoded) - 1):
            decoder = FrameDecoder()
            decoder.feed(encoded[:cut])
            with self.assertRaises(IncompleteFrame):
                decoder.finish()
        result = detect_truncated_frame(7)
        self.assertEqual(result["status"], "pass")

    def test_canonical_json_is_stable(self):
        left = canonical_json_bytes({"type": "event", "b": 2, "a": 1})
        right = canonical_json_bytes({"a": 1, "b": 2, "type": "event"})
        self.assertEqual(left, right)
        self.assertEqual(json.loads(left), json.loads(right))


class ReferenceModelTests(unittest.TestCase):
    def test_multiple_pairings_floor_gap_and_global_pruning(self):
        phone = ReferencePhone()
        for index in range(3):
            phone.append_event("posted", f"before-{index}")
        self.assertEqual(phone.outbox, {})

        fast = ReferenceMac("fast")
        slow = ReferenceMac("slow")
        fast.establish_pairing(phone, retention_count=100)
        slow.establish_pairing(phone, retention_count=3)
        self.assertEqual(fast.current.initial_cursor, 3)
        self.assertEqual(slow.current.initial_cursor, 3)

        for index in range(5):
            phone.append_event("updated", f"after-{index}")
        fast_result = fast.sync(phone)
        self.assertEqual(fast_result.new_events, 5)
        self.assertEqual(phone.pairings["fast"].acked_seq, 8)
        self.assertEqual(set(phone.outbox), {4, 5, 6, 7, 8})

        phone.advance_floor("slow", 7, "retention_count")
        self.assertEqual(set(phone.outbox), {7, 8})
        slow_result = slow.sync(phone)
        self.assertEqual(slow_result.new_gap_positions, 3)
        self.assertEqual(slow_result.new_events, 2)
        self.assertEqual({slow.current.gaps[seq] for seq in (4, 5, 6)}, {"retention_count"})
        self.assertEqual(phone.outbox, {})

        fast.assert_current_complete(phone)
        slow.assert_current_complete(phone)
        phone.assert_invariants()

    def test_ack_must_be_monotonic_and_session_authorized(self):
        phone = ReferencePhone()
        mac = ReferenceMac("mac")
        mac.establish_pairing(phone, retention_count=20)
        phone.append_event("posted")
        session = phone.plan_sync("mac", phone.generation, 0)

        self.assertEqual(session.authorized_through, 0)
        with self.assertRaises(ProtocolError):
            phone.accept_ack(session, 1)
        session.mark_sent(session.frames[0])
        self.assertEqual(session.authorized_through, 1)
        with self.assertRaises(ProtocolError):
            phone.accept_ack(session, 2)
        phone.accept_ack(session, 1)
        phone.accept_ack(session, 1)

        later = phone.plan_sync("mac", phone.generation, 1)
        with self.assertRaises(ProtocolError):
            phone.accept_ack(later, 0)

    def test_empty_session_ack_at_welcome_cursor_is_valid(self):
        phone = ReferencePhone()
        mac = ReferenceMac("mac")
        mac.establish_pairing(phone, retention_count=20)
        session = phone.plan_sync("mac", phone.generation, 0)
        self.assertEqual(session.frames, [])
        self.assertEqual(session.authorized_through, 0)

        phone.accept_ack(session, 0)
        phone.accept_ack(session, 0)
        self.assertEqual(phone.pairings["mac"].acked_seq, 0)
        with self.assertRaises(ProtocolError):
            phone.accept_ack(session, 1)

    def test_lost_ack_reconnect_authorizes_committed_cursor_without_frames(self):
        phone = ReferencePhone()
        mac = ReferenceMac("mac")
        mac.establish_pairing(phone, retention_count=20)
        for _ in range(4):
            phone.append_event("posted")
        lost = mac.sync(phone, deliver_ack=False)
        self.assertTrue(lost.ack_eligible)
        self.assertFalse(lost.ack_delivered)
        self.assertEqual(mac.current.processed_through, 4)
        self.assertEqual(phone.pairings["mac"].acked_seq, 0)

        resumed = phone.plan_sync("mac", phone.generation, mac.current.processed_through)
        self.assertEqual(resumed.frames, [])
        self.assertEqual(resumed.authorized_through, 4)
        with self.assertRaises(ProtocolError):
            phone.accept_ack(resumed, 5)
        phone.accept_ack(resumed, 4)
        self.assertEqual(phone.pairings["mac"].acked_seq, 4)
        self.assertEqual(phone.outbox, {})

    def test_partial_disconnect_resumes_from_committed_cursor(self):
        phone = ReferencePhone()
        mac = ReferenceMac("mac")
        mac.establish_pairing(phone, retention_count=20)
        for _ in range(6):
            phone.append_event("posted")

        partial = mac.sync(phone, frame_limit=2, deliver_ack=False)
        self.assertFalse(partial.complete)
        self.assertEqual(mac.current.processed_through, 2)
        self.assertEqual(phone.pairings["mac"].acked_seq, 0)

        resumed = mac.sync(phone, frame_limit=None, deliver_ack=True)
        self.assertTrue(resumed.complete)
        self.assertEqual(resumed.new_events, 4)
        self.assertEqual(phone.pairings["mac"].acked_seq, 6)
        self.assertEqual(phone.outbox, {})
        mac.assert_current_complete(phone)

    def test_mac_cursor_regression_gets_explicit_gap(self):
        phone = ReferencePhone()
        mac = ReferenceMac("mac")
        mac.establish_pairing(phone, retention_count=20)
        for _ in range(10):
            phone.append_event("posted")
        mac.sync(phone)
        self.assertEqual(phone.outbox, {})

        mac.regress_current(4)
        result = mac.sync(phone)
        self.assertEqual(result.new_gap_positions, 6)
        self.assertEqual({mac.current.gaps[seq] for seq in range(5, 11)}, {"peer_cursor_regressed"})
        mac.assert_current_complete(phone)

    def test_ack_retires_delivered_gap_spans_before_cursor_regression(self):
        phone = ReferencePhone()
        mac = ReferenceMac("mac")
        mac.establish_pairing(phone, retention_count=20)
        for _ in range(10):
            phone.append_event("posted")
        phone.advance_floor("mac", 4, "retention_count")
        phone.advance_floor("mac", 7, "retention_age")
        mac.sync(phone)
        self.assertEqual(phone.pairings["mac"].acked_seq, 10)
        self.assertEqual(phone.pairings["mac"].gaps, [])

        mac.regress_current(0)
        partial = mac.sync(phone, frame_limit=1, deliver_ack=True)
        self.assertTrue(partial.ack_eligible)
        self.assertTrue(partial.ack_delivered)
        self.assertEqual(mac.current.processed_through, 10)
        self.assertEqual(phone.pairings["mac"].acked_seq, 10)
        self.assertEqual(
            {mac.current.gaps[seq] for seq in range(1, 11)},
            {"peer_cursor_regressed"},
        )
        mac.assert_current_complete(phone)

    def test_age_retention_floor_expiry_boundary_and_reason(self):
        phone = ReferencePhone()
        mac = ReferenceMac("mac")
        mac.establish_pairing(phone, retention_count=100, retention_age_ms=10_000)
        for _ in range(3):
            phone.append_event("posted")
        phone.advance_time(10_000)
        phone.append_event("posted")

        self.assertEqual(phone.retention_floors("mac"), (1, 4))
        self.assertEqual(phone.apply_retention("mac"), "retention_age")
        self.assertEqual(phone.pairings["mac"].serve_from_seq, 4)
        self.assertEqual(
            [(gap.from_seq, gap.to_seq, gap.reason) for gap in phone.pairings["mac"].gaps],
            [(1, 3, "retention_age")],
        )
        self.assertEqual(set(phone.outbox), {4})

        result = mac.sync(phone)
        self.assertEqual(result.new_events, 1)
        self.assertEqual({mac.current.gaps[seq] for seq in (1, 2, 3)}, {"retention_age"})
        mac.assert_current_complete(phone)
        phone.assert_invariants()

    def test_count_floor_wins_exact_age_tie(self):
        phone = ReferencePhone()
        mac = ReferenceMac("mac")
        mac.establish_pairing(phone, retention_count=2, retention_age_ms=10_000)
        for _ in range(3):
            phone.append_event("posted")
        phone.advance_time(10_000)
        for _ in range(2):
            phone.append_event("posted")

        self.assertEqual(phone.retention_floors("mac"), (4, 4))
        self.assertEqual(phone.apply_retention("mac"), "retention_count")
        self.assertEqual(
            [(gap.from_seq, gap.to_seq, gap.reason) for gap in phone.pairings["mac"].gaps],
            [(1, 3, "retention_count")],
        )
        mac.sync(phone)
        self.assertEqual({mac.current.gaps[seq] for seq in (1, 2, 3)}, {"retention_count"})
        mac.assert_current_complete(phone)
        phone.assert_invariants()

    def test_count_floor_wins_when_strictly_ahead_of_age(self):
        phone = ReferencePhone()
        mac = ReferenceMac("mac")
        mac.establish_pairing(phone, retention_count=2, retention_age_ms=10_000)
        phone.append_event("posted")
        phone.advance_time(10_000)
        for _ in range(4):
            phone.append_event("posted")

        self.assertEqual(phone.retention_floors("mac"), (4, 2))
        self.assertEqual(phone.apply_retention("mac"), "retention_count")
        self.assertEqual(
            [(gap.from_seq, gap.to_seq, gap.reason) for gap in phone.pairings["mac"].gaps],
            [(1, 3, "retention_count")],
        )
        mac.sync(phone)
        mac.assert_current_complete(phone)
        phone.assert_invariants()

    def test_retention_spans_preserve_distinct_reasons(self):
        phone = ReferencePhone()
        mac = ReferenceMac("mac")
        mac.establish_pairing(phone, retention_count=100, retention_age_ms=10_000)
        for _ in range(3):
            phone.append_event("posted")
        phone.advance_time(10_000)
        self.assertEqual(phone.apply_retention("mac"), "retention_age")

        for _ in range(3):
            phone.append_event("posted")
        phone.pairings["mac"].retention_count = 1
        self.assertEqual(phone.apply_retention("mac"), "retention_count")

        self.assertEqual(
            [(gap.from_seq, gap.to_seq, gap.reason) for gap in phone.pairings["mac"].gaps],
            [(1, 3, "retention_age"), (4, 5, "retention_count")],
        )
        result = mac.sync(phone)
        self.assertEqual(result.new_events, 1)
        self.assertEqual({mac.current.gaps[seq] for seq in (1, 2, 3)}, {"retention_age"})
        self.assertEqual({mac.current.gaps[seq] for seq in (4, 5)}, {"retention_count"})
        self.assertEqual(phone.pairings["mac"].gaps, [])
        mac.assert_current_complete(phone)
        phone.assert_invariants()

    def test_retention_noop_within_limits_and_time_validation(self):
        phone = ReferencePhone()
        mac = ReferenceMac("mac")
        mac.establish_pairing(phone, retention_count=100, retention_age_ms=60_000)
        for _ in range(3):
            phone.append_event("posted")
        phone.advance_time(30_000)
        self.assertIsNone(phone.apply_retention("mac"))
        self.assertEqual(phone.pairings["mac"].serve_from_seq, 1)
        self.assertEqual(phone.pairings["mac"].gaps, [])
        self.assertEqual(set(phone.outbox), {1, 2, 3})
        with self.assertRaises(ValueError):
            phone.advance_time(-1)
        with self.assertRaises(ValueError):
            ReferencePhone().add_pairing("bad", 5, 0)

    def test_generation_reset_separates_sequence_spaces(self):
        phone = ReferencePhone()
        mac = ReferenceMac("mac")
        mac.establish_pairing(phone, retention_count=20)
        phone.append_event("posted")
        mac.sync(phone)
        old_generation = phone.generation

        phone.reset_generation()
        phone.append_event("updated")
        result = mac.sync(phone)
        self.assertEqual(result.generation_transitions, 1)
        self.assertNotEqual(old_generation, phone.generation)
        self.assertEqual(mac.generations[old_generation].events[1].kind, "posted")
        self.assertEqual(mac.current.events[1].kind, "updated")
        mac.assert_current_complete(phone)

    def test_cursor_ahead_forces_new_generation(self):
        phone = ReferencePhone()
        mac = ReferenceMac("mac")
        mac.establish_pairing(phone, retention_count=20)
        for _ in range(5):
            phone.append_event("posted")
        mac.sync(phone)
        old_generation = phone.generation

        phone.simulate_same_generation_rollback(2)
        result = mac.sync(phone)
        self.assertTrue(result.cursor_ahead_reset)
        self.assertNotEqual(phone.generation, old_generation)
        self.assertEqual(phone.highwater, 0)
        self.assertEqual(mac.current.processed_through, 0)

    def test_plan_sync_rejects_cursor_ahead(self):
        phone = ReferencePhone()
        mac = ReferenceMac("mac")
        mac.establish_pairing(phone, retention_count=20)
        with self.assertRaises(CursorAhead):
            phone.plan_sync("mac", phone.generation, 1)


class ChaosAndSimulatorTests(unittest.TestCase):
    def test_chaos_is_deterministic(self):
        config = ChaosConfig(seed=12345, steps=400, pairing_count=3, max_retention_count=19)
        first = run_chaos(config)
        second = run_chaos(config)
        self.assertEqual(first, second)
        self.assertEqual(first["status"], "pass")

    def test_multiple_chaos_seeds(self):
        age_advances = 0
        count_advances = 0
        for seed in range(10):
            with self.subTest(seed=seed):
                result = run_chaos(
                    ChaosConfig(
                        seed=seed,
                        steps=250,
                        pairing_count=3,
                        max_retention_count=17,
                    )
                )
                self.assertEqual(result["status"], "pass")
                self.assertGreater(result["invalid_acks_rejected"], 0)
                self.assertEqual(
                    result["retention_advances"],
                    result["retention_age_advances"] + result["retention_count_advances"],
                )
                age_advances += result["retention_age_advances"]
                count_advances += result["retention_count_advances"]
        self.assertGreater(age_advances, 0)
        self.assertGreater(count_advances, 0)

    def test_fragmented_fake_phone_mac_exchange(self):
        result = run_framed_simulation(event_count=12, gap_through=3)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["phone"]["ack"], 12)
        self.assertEqual(result["mac"]["cursor"], 12)
        self.assertEqual(result["mac"]["events"], 9)
        self.assertEqual(result["mac"]["gap_positions"], 3)
        self.assertEqual(result["mac"]["skipped_frame_types"], [0x7F])
        self.assertIn("active_chunk", result["phone"]["sent_types"])


if __name__ == "__main__":
    unittest.main()
