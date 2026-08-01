#!/usr/bin/env python3
"""Deterministic Eko store-and-forward reference model and framed simulator.

The model is intentionally independent from Android Room and macOS GRDB. It is an
executable oracle for sequence generations, per-pairing cursors and floors,
retention gaps, cumulative acknowledgements, pruning, reconnects, and Mac cursor
regression. The loopback simulator exercises v1 application framing, not TLS.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import queue
import random
import socket
import struct
import sys
import threading
from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


MAX_FRAME_LENGTH = 1_048_576
MAX_JSON_DEPTH = 64
JSON_FRAME_TYPE = 0x01
BINARY_FRAME_TYPE = 0x02

DEFAULT_RETENTION_AGE_MS = 48 * 60 * 60 * 1_000
PHONE_CLOCK_EPOCH_MS = 1_700_000_000_000
STORED_GAP_REASONS = ("retention_count", "retention_age")


class ProtocolError(ValueError):
    """A peer or model operation violated the protocol contract."""


class IncompleteFrame(ProtocolError):
    """The byte stream ended in a frame prefix or body."""


class CursorAhead(ProtocolError):
    """A Mac cursor is ahead of the phone's durable high-water."""


def canonical_json_bytes(message: Mapping[str, Any]) -> bytes:
    """Encode deterministic JSON suitable for a type-0x01 frame."""

    try:
        text = json.dumps(
            message,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    except (TypeError, ValueError) as exc:
        raise ProtocolError(f"message is not canonical JSON: {exc}") from exc
    return text.encode("utf-8")


def encode_frame(frame_type: int, payload: bytes) -> bytes:
    """Encode `[u32 length][u8 type][payload]` with the v1 size limit."""

    if not isinstance(frame_type, int) or not 0 <= frame_type <= 0xFF:
        raise ProtocolError("frame type must be an unsigned byte")
    if not isinstance(payload, bytes):
        raise ProtocolError("frame payload must be bytes")
    length = 1 + len(payload)
    if length > MAX_FRAME_LENGTH:
        raise ProtocolError(
            f"frame length {length} exceeds maximum {MAX_FRAME_LENGTH}"
        )
    return struct.pack(">I", length) + bytes((frame_type,)) + payload


def encode_json_frame(message: Mapping[str, Any]) -> bytes:
    return encode_frame(JSON_FRAME_TYPE, canonical_json_bytes(message))


def _object_without_duplicates(pairs: Iterable[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _enforce_json_depth_limit(value: Any) -> None:
    """Reject nesting deeper than the protocol's hard bound.

    Iterative on purpose: a recursive walk would itself be limited by the
    interpreter's recursion limit. Levels count enclosing arrays/objects, so
    a member of the top-level object is at level 1 — matching both app
    implementations.
    """
    stack: List[Tuple[Any, int]] = [(value, 0)]
    while stack:
        node, level = stack.pop()
        if level > MAX_JSON_DEPTH:
            raise ProtocolError(f"JSON nesting exceeds {MAX_JSON_DEPTH} levels")
        if isinstance(node, dict):
            stack.extend((item, level + 1) for item in node.values())
        elif isinstance(node, list):
            stack.extend((item, level + 1) for item in node)


def decode_json_payload(frame_type: int, payload: bytes) -> Dict[str, Any]:
    if frame_type != JSON_FRAME_TYPE:
        raise ProtocolError(f"expected JSON frame, received type 0x{frame_type:02x}")
    try:
        text = payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise ProtocolError("JSON payload is not valid UTF-8") from exc
    try:
        message = json.loads(text, object_pairs_hook=_object_without_duplicates)
    except ProtocolError:
        raise
    except RecursionError as exc:
        raise ProtocolError(f"JSON nesting exceeds {MAX_JSON_DEPTH} levels") from exc
    except (json.JSONDecodeError, ValueError) as exc:
        raise ProtocolError(f"invalid JSON payload: {exc}") from exc
    if not isinstance(message, dict):
        raise ProtocolError("JSON frame root must be an object")
    _enforce_json_depth_limit(message)
    if not isinstance(message.get("type"), str):
        raise ProtocolError("JSON message must have a string type")
    return message


class FrameDecoder:
    """Incrementally decode arbitrarily fragmented or coalesced frames."""

    def __init__(self) -> None:
        self._buffer = bytearray()
        self._expected_length: Optional[int] = None

    @property
    def buffered_bytes(self) -> int:
        return len(self._buffer)

    def feed(self, data: bytes) -> List[Tuple[int, bytes]]:
        if not isinstance(data, bytes):
            raise ProtocolError("decoder input must be bytes")
        self._buffer.extend(data)
        frames: List[Tuple[int, bytes]] = []

        while True:
            if self._expected_length is None:
                if len(self._buffer) < 4:
                    break
                self._expected_length = struct.unpack(">I", self._buffer[:4])[0]
                del self._buffer[:4]
                if self._expected_length == 0:
                    raise ProtocolError("frame length cannot be zero")
                if self._expected_length > MAX_FRAME_LENGTH:
                    raise ProtocolError(
                        f"frame length {self._expected_length} exceeds maximum "
                        f"{MAX_FRAME_LENGTH}"
                    )

            if len(self._buffer) < self._expected_length:
                break

            body = bytes(self._buffer[: self._expected_length])
            del self._buffer[: self._expected_length]
            self._expected_length = None
            frames.append((body[0], body[1:]))

        return frames

    def finish(self) -> None:
        if self._expected_length is not None or self._buffer:
            expected = self._expected_length
            if expected is None:
                detail = f"partial length prefix ({len(self._buffer)} bytes)"
            else:
                detail = f"partial frame body ({len(self._buffer)}/{expected} bytes)"
            raise IncompleteFrame(detail)


class FramedSocketReader:
    """Read complete frames from a stream socket without losing coalesced data."""

    def __init__(self, sock: socket.socket, read_size: int = 4096) -> None:
        self.sock = sock
        self.read_size = read_size
        self.decoder = FrameDecoder()
        self.pending: List[Tuple[int, bytes]] = []
        self.skipped_frame_types: List[int] = []

    def receive(self) -> Tuple[int, bytes]:
        while not self.pending:
            data = self.sock.recv(self.read_size)
            if not data:
                self.decoder.finish()
                raise EOFError("peer closed a clean framed stream")
            self.pending.extend(self.decoder.feed(data))
        return self.pending.pop(0)

    def receive_json(self) -> Dict[str, Any]:
        while True:
            frame_type, payload = self.receive()
            if frame_type == JSON_FRAME_TYPE:
                return decode_json_payload(frame_type, payload)
            self.skipped_frame_types.append(frame_type)


def send_fragmented(
    sock: socket.socket,
    encoded: bytes,
    chunk_pattern: Sequence[int] = (1, 2, 3, 5, 8, 13),
) -> None:
    """Send one encoded frame using a deterministic fragmentation pattern."""

    if not chunk_pattern or any(size <= 0 for size in chunk_pattern):
        raise ValueError("chunk pattern must contain positive sizes")
    offset = 0
    index = 0
    while offset < len(encoded):
        size = chunk_pattern[index % len(chunk_pattern)]
        sock.sendall(encoded[offset : offset + size])
        offset += size
        index += 1


def send_json_fragmented(sock: socket.socket, message: Mapping[str, Any]) -> None:
    send_fragmented(sock, encode_json_frame(message))


@dataclass(frozen=True)
class Event:
    generation: str
    seq: int
    kind: str
    key: str
    token: int
    posted_at_ms: int

    def as_dict(self) -> Dict[str, Any]:
        return {
            "generation": self.generation,
            "key": self.key,
            "kind": self.kind,
            "posted_at_ms": self.posted_at_ms,
            "seq": self.seq,
            "token": self.token,
        }


@dataclass(frozen=True)
class GapSpan:
    generation: str
    from_seq: int
    to_seq: int
    reason: str

    def __post_init__(self) -> None:
        if self.from_seq < 1 or self.to_seq < self.from_seq:
            raise ValueError("invalid gap span")


@dataclass
class PairingState:
    pairing_id: str
    generation: str
    acked_seq: int
    serve_from_seq: int
    retention_count: int
    retention_age_ms: int
    gaps: List[GapSpan] = field(default_factory=list)

    @property
    def effective_floor(self) -> int:
        return max(self.serve_from_seq, self.acked_seq + 1)


@dataclass(frozen=True)
class SyncFrame:
    kind: str
    from_seq: int
    to_seq: int
    reason: Optional[str] = None
    event: Optional[Event] = None

    @classmethod
    def for_event(cls, event: Event) -> "SyncFrame":
        return cls("event", event.seq, event.seq, event=event)

    @classmethod
    def for_gap(cls, start: int, end: int, reason: str) -> "SyncFrame":
        return cls("gap", start, end, reason=reason)


@dataclass
class ReferenceSession:
    pairing_id: str
    generation: str
    requested_cursor: int
    replay_to_seq: int
    frames: List[SyncFrame]
    next_to_send: int
    authorized_through: int

    def mark_sent(self, frame: SyncFrame) -> None:
        if frame.from_seq != self.next_to_send:
            raise AssertionError(
                f"session coverage skipped from {self.next_to_send} to {frame.from_seq}"
            )
        self.authorized_through = frame.to_seq
        self.next_to_send = frame.to_seq + 1


class ReferencePhone:
    """Small durable-phone oracle with one shared log and per-Mac availability."""

    EVENT_KINDS = ("posted", "updated", "removed", "capture_gap")

    def __init__(self) -> None:
        self.generation_index = 1
        self.generation = self._generation_name(self.generation_index)
        self.highwater = 0
        self.now_ms = PHONE_CLOCK_EPOCH_MS
        self.outbox: Dict[int, Event] = {}
        self.ledgers: Dict[str, Dict[int, Event]] = {self.generation: {}}
        self.retired_generations: List[str] = []
        self.pairings: Dict[str, PairingState] = {}
        self.total_events_assigned = 0
        self.total_rows_pruned = 0
        self.total_generation_resets = 0

    @staticmethod
    def _generation_name(index: int) -> str:
        return f"gen-{index:04d}"

    def advance_time(self, delta_ms: int) -> None:
        if delta_ms < 0:
            raise ValueError("time advance cannot be negative")
        self.now_ms += delta_ms

    def append_event(self, kind: str, key: Optional[str] = None) -> Event:
        if kind not in self.EVENT_KINDS:
            raise ValueError(f"unknown event kind: {kind}")
        self.highwater += 1
        self.total_events_assigned += 1
        event = Event(
            generation=self.generation,
            seq=self.highwater,
            kind=kind,
            key=key or f"notification-{self.total_events_assigned % 17:02d}",
            token=self.total_events_assigned,
            posted_at_ms=self.now_ms,
        )
        self.ledgers[self.generation][event.seq] = event
        self.outbox[event.seq] = event
        self.prune()
        return event

    def add_pairing(
        self,
        pairing_id: str,
        retention_count: int,
        retention_age_ms: int = DEFAULT_RETENTION_AGE_MS,
    ) -> int:
        if pairing_id in self.pairings:
            raise ProtocolError(f"pairing already exists: {pairing_id}")
        if retention_count < 1:
            raise ValueError("retention count must be positive")
        if retention_age_ms < 1:
            raise ValueError("retention age must be positive")
        initial_cursor = self.highwater
        self.pairings[pairing_id] = PairingState(
            pairing_id=pairing_id,
            generation=self.generation,
            acked_seq=initial_cursor,
            serve_from_seq=initial_cursor + 1,
            retention_count=retention_count,
            retention_age_ms=retention_age_ms,
        )
        self.prune()
        return initial_cursor

    def remove_pairing(self, pairing_id: str) -> None:
        if pairing_id not in self.pairings:
            raise ProtocolError(f"unknown pairing: {pairing_id}")
        del self.pairings[pairing_id]
        self.prune()

    def _append_gap(self, pairing: PairingState, gap: GapSpan) -> None:
        if pairing.gaps:
            previous = pairing.gaps[-1]
            if previous.to_seq >= gap.from_seq:
                raise AssertionError("retention gap spans overlap")
            if previous.reason == gap.reason and previous.to_seq + 1 == gap.from_seq:
                pairing.gaps[-1] = GapSpan(
                    generation=self.generation,
                    from_seq=previous.from_seq,
                    to_seq=gap.to_seq,
                    reason=gap.reason,
                )
                return
        pairing.gaps.append(gap)

    def advance_floor(self, pairing_id: str, new_floor: int, reason: str) -> None:
        pairing = self.pairings[pairing_id]
        if new_floor < pairing.serve_from_seq:
            raise ProtocolError("serve floor cannot regress")
        if new_floor > self.highwater + 1:
            raise ProtocolError("serve floor cannot exceed high-water plus one")
        if not reason:
            raise ValueError("gap reason cannot be empty")

        skipped_from = max(pairing.serve_from_seq, pairing.acked_seq + 1)
        skipped_to = new_floor - 1
        if skipped_from <= skipped_to:
            self._append_gap(
                pairing,
                GapSpan(self.generation, skipped_from, skipped_to, reason),
            )
        pairing.serve_from_seq = new_floor
        self.prune()

    def retention_floors(self, pairing_id: str) -> Tuple[int, int]:
        """Independently computed count and age floors for one pairing.

        The count floor keeps the newest `retention_count` pending events; the
        age floor expires the pending prefix whose age at the phone clock is at
        least `retention_age_ms`. Both are clamped below by the effective floor.
        """

        pairing = self.pairings[pairing_id]
        effective_floor = pairing.effective_floor
        ledger = self.ledgers[self.generation]

        age_floor = effective_floor
        for seq in range(effective_floor, self.highwater + 1):
            event = ledger.get(seq)
            if event is None:
                raise AssertionError(
                    f"pending sequence {seq} missing from generation ledger"
                )
            if self.now_ms - event.posted_at_ms >= pairing.retention_age_ms:
                age_floor = seq + 1
            else:
                break

        pending_size = self.highwater - effective_floor + 1
        if pending_size > pairing.retention_count:
            count_floor = self.highwater - pairing.retention_count + 1
        else:
            count_floor = effective_floor
        return count_floor, age_floor

    def apply_retention(self, pairing_id: str) -> Optional[str]:
        """Apply the combined count/age retention transaction for one pairing.

        Returns the recorded gap reason when the floor advanced, otherwise
        None. The count reason wins an exact floor tie, matching protocol v1.
        """

        pairing = self.pairings[pairing_id]
        effective_floor = pairing.effective_floor
        count_floor, age_floor = self.retention_floors(pairing_id)
        new_floor = max(count_floor, age_floor)
        if new_floor <= effective_floor:
            return None
        reason = "retention_count" if count_floor >= age_floor else "retention_age"
        self.advance_floor(pairing_id, new_floor, reason)
        return reason

    def prune(self) -> None:
        removable = []
        for seq in self.outbox:
            needed = any(
                seq > pairing.acked_seq and seq >= pairing.serve_from_seq
                for pairing in self.pairings.values()
            )
            if not needed:
                removable.append(seq)
        for seq in removable:
            del self.outbox[seq]
        self.total_rows_pruned += len(removable)

    def reset_generation(self) -> str:
        old_generation = self.generation
        self.retired_generations.append(old_generation)
        self.generation_index += 1
        self.generation = self._generation_name(self.generation_index)
        self.highwater = 0
        self.outbox = {}
        self.ledgers[self.generation] = {}
        for pairing in self.pairings.values():
            pairing.generation = self.generation
            pairing.acked_seq = 0
            pairing.serve_from_seq = 1
            pairing.gaps = []
        self.total_generation_resets += 1
        return self.generation

    def simulate_same_generation_rollback(self, restored_highwater: int) -> None:
        """Create the transient corruption state detected by a cursor-ahead welcome.

        This method must be followed immediately by a connection from a Mac whose cursor
        exceeds `restored_highwater`; that connection journals a generation reset. The
        immutable ledger is retained as test ground truth for the retired generation.
        """

        if not 0 <= restored_highwater < self.highwater:
            raise ValueError("rollback high-water must be lower than the current high-water")
        self.highwater = restored_highwater
        self.outbox = {
            seq: event for seq, event in self.outbox.items() if seq <= restored_highwater
        }

    @staticmethod
    def _coalesce_sync_gaps(frames: List[SyncFrame]) -> List[SyncFrame]:
        result: List[SyncFrame] = []
        for frame in frames:
            if (
                result
                and result[-1].kind == "gap"
                and result[-1].reason == frame.reason
                and result[-1].to_seq + 1 == frame.from_seq
            ):
                previous = result[-1]
                result[-1] = SyncFrame.for_gap(
                    previous.from_seq, frame.to_seq, frame.reason or "unknown"
                )
            else:
                result.append(frame)
        return result

    def _gaps_for_range(
        self, pairing: PairingState, start: int, end: int
    ) -> List[SyncFrame]:
        if start > end:
            return []
        frames: List[SyncFrame] = []
        cursor = start
        for gap in pairing.gaps:
            if gap.to_seq < cursor:
                continue
            if gap.from_seq > end:
                break
            if gap.from_seq > cursor:
                frames.append(
                    SyncFrame.for_gap(
                        cursor, min(end, gap.from_seq - 1), "peer_cursor_regressed"
                    )
                )
                cursor = gap.from_seq
            clipped_start = max(cursor, gap.from_seq)
            clipped_end = min(end, gap.to_seq)
            if clipped_start <= clipped_end:
                frames.append(
                    SyncFrame.for_gap(clipped_start, clipped_end, gap.reason)
                )
                cursor = clipped_end + 1
            if cursor > end:
                break
        if cursor <= end:
            frames.append(
                SyncFrame.for_gap(cursor, end, "peer_cursor_regressed")
            )
        return self._coalesce_sync_gaps(frames)

    def plan_sync(self, pairing_id: str, mac_generation: str, cursor: int) -> ReferenceSession:
        pairing = self.pairings[pairing_id]
        if mac_generation != self.generation:
            raise ProtocolError("Mac must transition to the current generation before sync")
        if cursor < 0:
            raise ProtocolError("cursor cannot be negative")
        if cursor > self.highwater:
            raise CursorAhead(
                f"Mac cursor {cursor} exceeds durable high-water {self.highwater}"
            )

        replay_to = self.highwater
        requested = cursor + 1
        unavailable_to = min(pairing.effective_floor - 1, replay_to)
        frames = self._gaps_for_range(pairing, requested, unavailable_to)

        replay_from = max(requested, pairing.effective_floor)
        for seq in range(replay_from, replay_to + 1):
            event = self.outbox.get(seq)
            if event is None:
                raise AssertionError(
                    f"pairing {pairing_id} needs sequence {seq}, but it was pruned"
                )
            frames.append(SyncFrame.for_event(event))

        return ReferenceSession(
            pairing_id=pairing_id,
            generation=self.generation,
            requested_cursor=cursor,
            replay_to_seq=replay_to,
            frames=frames,
            next_to_send=requested,
            authorized_through=cursor,
        )

    def accept_ack(self, session: ReferenceSession, seq: int) -> None:
        if session.generation != self.generation:
            raise ProtocolError("ack belongs to a retired generation")
        pairing = self.pairings.get(session.pairing_id)
        if pairing is None:
            raise ProtocolError("ack belongs to an unknown pairing")
        if seq < pairing.acked_seq:
            raise ProtocolError("ack is non-monotonic")
        if seq > session.authorized_through or seq > self.highwater:
            raise ProtocolError("ack exceeds sequence authorized in this session")
        if seq == pairing.acked_seq:
            return
        pairing.acked_seq = seq
        retained_gaps: List[GapSpan] = []
        for gap in pairing.gaps:
            if gap.to_seq <= seq:
                continue
            if gap.from_seq <= seq:
                gap = GapSpan(
                    generation=gap.generation,
                    from_seq=seq + 1,
                    to_seq=gap.to_seq,
                    reason=gap.reason,
                )
            retained_gaps.append(gap)
        pairing.gaps = retained_gaps
        self.prune()

    def assert_invariants(self) -> None:
        current_ledger = self.ledgers[self.generation]
        expected_sequences = set(range(1, self.highwater + 1))
        if set(current_ledger) != expected_sequences:
            raise AssertionError("current generation ledger is not contiguous")

        for seq, event in self.outbox.items():
            if current_ledger.get(seq) != event:
                raise AssertionError("outbox diverged from immutable generation ledger")

        expected_outbox = {
            seq
            for seq in expected_sequences
            if any(
                seq > pairing.acked_seq and seq >= pairing.serve_from_seq
                for pairing in self.pairings.values()
            )
        }
        if set(self.outbox) != expected_outbox:
            raise AssertionError(
                f"physical pruning mismatch: expected {sorted(expected_outbox)}, "
                f"found {sorted(self.outbox)}"
            )

        for pairing_id, pairing in self.pairings.items():
            if pairing.pairing_id != pairing_id or pairing.generation != self.generation:
                raise AssertionError("pairing identity/generation mismatch")
            if not 0 <= pairing.acked_seq <= self.highwater:
                raise AssertionError("pairing ack outside current generation")
            if not 1 <= pairing.serve_from_seq <= self.highwater + 1:
                raise AssertionError("pairing floor outside current generation")
            if pairing.retention_count < 1:
                raise AssertionError("invalid retention count")
            if pairing.retention_age_ms < 1:
                raise AssertionError("invalid retention age")

            previous_end = 0
            gap_positions = set()
            for gap in pairing.gaps:
                if gap.generation != self.generation:
                    raise AssertionError("gap belongs to wrong generation")
                if gap.reason not in STORED_GAP_REASONS:
                    raise AssertionError("stored gap has a non-retention reason")
                if gap.from_seq <= previous_end or gap.to_seq >= pairing.serve_from_seq:
                    raise AssertionError("gap ordering/floor mismatch")
                previous_end = gap.to_seq
                gap_positions.update(range(gap.from_seq, gap.to_seq + 1))

            required_gap_positions = set(
                range(pairing.acked_seq + 1, pairing.serve_from_seq)
            )
            if not required_gap_positions.issubset(gap_positions):
                missing = sorted(required_gap_positions - gap_positions)
                raise AssertionError(
                    f"pairing {pairing_id} floor has unreported positions: {missing}"
                )


@dataclass
class GenerationCoverage:
    generation: str
    initial_cursor: int
    processed_through: int
    events: Dict[int, Event] = field(default_factory=dict)
    gaps: Dict[int, str] = field(default_factory=dict)
    duplicate_events: int = 0

    def apply_event(self, event: Event) -> int:
        if event.generation != self.generation:
            raise ProtocolError("event belongs to a different generation")
        if event.seq <= self.initial_cursor:
            raise ProtocolError("peer disclosed an event from before pairing")
        if event.seq <= self.processed_through:
            if self.events.get(event.seq) == event:
                self.duplicate_events += 1
                return 0
            raise ProtocolError("duplicate sequence has different event/gap content")
        if event.seq != self.processed_through + 1:
            raise ProtocolError("event would advance cursor across an uncovered position")
        self.events[event.seq] = event
        self.processed_through = event.seq
        return 1

    def apply_gap(self, start: int, end: int, reason: str) -> int:
        if start < 1 or end < start or not reason:
            raise ProtocolError("invalid gap frame")
        if end <= self.initial_cursor:
            raise ProtocolError("peer sent a gap entirely before pairing")

        original_start = start
        overlap_end = min(end, self.processed_through)
        if start <= overlap_end:
            for seq in range(max(start, self.initial_cursor + 1), overlap_end + 1):
                if self.gaps.get(seq) != reason:
                    raise ProtocolError("overlapping gap conflicts with durable coverage")
            start = overlap_end + 1
        if start > end:
            return 0
        if start != self.processed_through + 1:
            raise ProtocolError("gap would advance cursor across an uncovered position")

        for seq in range(start, end + 1):
            if seq in self.events or seq in self.gaps:
                raise ProtocolError("sequence already represented")
            self.gaps[seq] = reason
        self.processed_through = end
        return end - max(start, original_start) + 1

    def regress(self, target: int) -> None:
        if not self.initial_cursor <= target <= self.processed_through:
            raise ValueError("regression target outside retained Mac state")
        self.events = {seq: event for seq, event in self.events.items() if seq <= target}
        self.gaps = {seq: reason for seq, reason in self.gaps.items() if seq <= target}
        self.processed_through = target

    def assert_invariants(self) -> None:
        if self.processed_through < self.initial_cursor:
            raise AssertionError("Mac cursor regressed before pairing boundary")
        if set(self.events).intersection(self.gaps):
            raise AssertionError("sequence is represented by both event and gap")
        represented = set(self.events).union(self.gaps)
        expected = set(range(self.initial_cursor + 1, self.processed_through + 1))
        if represented != expected:
            raise AssertionError("Mac cursor advanced without exact event-or-gap coverage")
        if any(event.generation != self.generation for event in self.events.values()):
            raise AssertionError("Mac event stored under wrong generation")


@dataclass(frozen=True)
class SyncResult:
    planned_frames: int
    delivered_frames: int
    new_events: int
    new_gap_positions: int
    gap_frames: int
    ack_eligible: bool
    ack_delivered: bool
    complete: bool
    generation_transitions: int
    cursor_ahead_reset: bool


class ReferenceMac:
    """Per-pairing durable Mac cursor and exact event-or-gap coverage oracle."""

    def __init__(self, pairing_id: str) -> None:
        self.pairing_id = pairing_id
        self.current_generation: Optional[str] = None
        self.generations: Dict[str, GenerationCoverage] = {}
        self.transitions: List[Tuple[str, str, int]] = []

    @property
    def current(self) -> GenerationCoverage:
        if self.current_generation is None:
            raise AssertionError("Mac has not been paired")
        return self.generations[self.current_generation]

    def establish_pairing(
        self,
        phone: ReferencePhone,
        retention_count: int,
        retention_age_ms: int = DEFAULT_RETENTION_AGE_MS,
    ) -> None:
        initial = phone.add_pairing(self.pairing_id, retention_count, retention_age_ms)
        self.current_generation = phone.generation
        self.generations[phone.generation] = GenerationCoverage(
            generation=phone.generation,
            initial_cursor=initial,
            processed_through=initial,
        )

    def _observe_generation(self, phone: ReferencePhone) -> int:
        if self.current_generation == phone.generation:
            return 0
        old_generation = self.current_generation
        old_cursor = self.current.processed_through if old_generation is not None else 0
        if phone.generation in self.generations:
            raise ProtocolError("phone attempted to revive a retired generation")
        self.current_generation = phone.generation
        self.generations[phone.generation] = GenerationCoverage(
            generation=phone.generation,
            initial_cursor=0,
            processed_through=0,
        )
        if old_generation is not None:
            self.transitions.append((old_generation, phone.generation, old_cursor))
        return 1

    def sync(
        self,
        phone: ReferencePhone,
        frame_limit: Optional[int] = None,
        deliver_ack: bool = True,
    ) -> SyncResult:
        if frame_limit is not None and frame_limit < 0:
            raise ValueError("frame limit cannot be negative")
        transitions = self._observe_generation(phone)
        cursor_ahead_reset = False

        if self.current.processed_through > phone.highwater:
            phone.reset_generation()
            transitions += self._observe_generation(phone)
            cursor_ahead_reset = True

        session = phone.plan_sync(
            self.pairing_id,
            self.current.generation,
            self.current.processed_through,
        )
        count = len(session.frames) if frame_limit is None else min(
            len(session.frames), frame_limit
        )
        new_events = 0
        new_gap_positions = 0
        gap_frames = 0
        for frame in session.frames[:count]:
            session.mark_sent(frame)
            if frame.kind == "event":
                if frame.event is None:
                    raise AssertionError("event frame lacks event")
                new_events += self.current.apply_event(frame.event)
            elif frame.kind == "gap":
                if frame.reason is None:
                    raise AssertionError("gap frame lacks reason")
                gap_frames += 1
                new_gap_positions += self.current.apply_gap(
                    frame.from_seq, frame.to_seq, frame.reason
                )
            else:
                raise AssertionError(f"unknown sync frame: {frame.kind}")

        ack_delivered = False
        ack_eligible = (
            count > 0
            and self.current.processed_through
            >= phone.pairings[self.pairing_id].acked_seq
        )
        if ack_eligible and deliver_ack:
            phone.accept_ack(session, self.current.processed_through)
            ack_delivered = True

        return SyncResult(
            planned_frames=len(session.frames),
            delivered_frames=count,
            new_events=new_events,
            new_gap_positions=new_gap_positions,
            gap_frames=gap_frames,
            ack_eligible=ack_eligible,
            ack_delivered=ack_delivered,
            complete=count == len(session.frames),
            generation_transitions=transitions,
            cursor_ahead_reset=cursor_ahead_reset,
        )

    def regress_current(self, target: int) -> None:
        self.current.regress(target)

    def assert_invariants(
        self, phone: ReferencePhone, current_only: bool = False
    ) -> None:
        if current_only:
            generation_items = [(self.current.generation, self.current)]
        else:
            generation_items = list(self.generations.items())
        for generation, coverage in generation_items:
            coverage.assert_invariants()
            ledger = phone.ledgers.get(generation)
            if ledger is None:
                raise AssertionError("Mac references an unknown phone generation")
            for seq, event in coverage.events.items():
                if ledger.get(seq) != event:
                    raise AssertionError("Mac event differs from phone ground truth")

    def assert_current_complete(self, phone: ReferencePhone) -> None:
        if self.current_generation != phone.generation:
            raise AssertionError("Mac has not observed current phone generation")
        if self.current.processed_through != phone.highwater:
            raise AssertionError(
                f"Mac cursor {self.current.processed_through} does not cover phone "
                f"high-water {phone.highwater}"
            )
        self.current.assert_invariants()
        ledger = phone.ledgers[phone.generation]
        for seq in range(self.current.initial_cursor + 1, phone.highwater + 1):
            event = self.current.events.get(seq)
            gap = self.current.gaps.get(seq)
            if (event is None) == (gap is None):
                raise AssertionError(f"sequence {seq} lacks exact event-or-gap coverage")
            if event is not None and ledger[seq] != event:
                raise AssertionError(f"sequence {seq} event differs from phone ledger")


@dataclass(frozen=True)
class ChaosConfig:
    seed: int = 20_260_724
    steps: int = 1_000
    pairing_count: int = 3
    max_retention_count: int = 31
    max_retention_age_ms: int = 3_600_000
    max_time_advance_ms: int = 60_000

    def validate(self) -> None:
        if self.steps < 0:
            raise ValueError("steps cannot be negative")
        if self.pairing_count < 1:
            raise ValueError("pairing count must be positive")
        if self.max_retention_count < 3:
            raise ValueError("max retention count must be at least three")
        if self.max_retention_age_ms < 30_000:
            raise ValueError("max retention age must be at least 30000 ms")
        if self.max_time_advance_ms < 1:
            raise ValueError("max time advance must be positive")


class ChaosHarness:
    """Generate reproducible operations and assert the oracle after each one."""

    def __init__(self, config: ChaosConfig) -> None:
        config.validate()
        self.config = config
        self.random = random.Random(config.seed)
        self.phone = ReferencePhone()
        self.macs: List[ReferenceMac] = []
        self.stats: Dict[str, int] = {
            "acks_delivered": 0,
            "acks_lost": 0,
            "acks_withheld_below_phone_ack": 0,
            "cursor_regressions": 0,
            "events_delivered": 0,
            "events_generated": 0,
            "gap_frames_delivered": 0,
            "gap_positions_delivered": 0,
            "generation_resets": 0,
            "generation_transitions": 0,
            "invalid_acks_rejected": 0,
            "partial_disconnects": 0,
            "retention_advances": 0,
            "retention_age_advances": 0,
            "retention_count_advances": 0,
            "sync_sessions": 0,
        }

        # Verify that pairing starts at high-water and cannot disclose old rows.
        for index in range(3):
            self.phone.append_event("posted", f"prepair-{index + 1}")
            self.stats["events_generated"] += 1

        for index in range(config.pairing_count):
            pairing_id = f"mac-{index + 1}"
            mac = ReferenceMac(pairing_id)
            retention = max(3, config.max_retention_count // (index + 1))
            retention_age = max(30_000, config.max_retention_age_ms // (index + 1))
            mac.establish_pairing(self.phone, retention, retention_age)
            self.macs.append(mac)
        self._validate()

    def _apply_retention(self, pairing_id: str) -> None:
        reason = self.phone.apply_retention(pairing_id)
        if reason is not None:
            self.stats["retention_advances"] += 1
            self.stats[f"{reason}_advances"] += 1

    def _apply_caps(self) -> None:
        for pairing_id in sorted(self.phone.pairings):
            self._apply_retention(pairing_id)

    def _append_random_event(self, forced_kind: Optional[str] = None) -> None:
        kind = forced_kind or self.random.choice(ReferencePhone.EVENT_KINDS)
        self.phone.append_event(kind)
        self.stats["events_generated"] += 1
        self._apply_caps()

    def _sync_random_mac(self) -> None:
        mac = self.random.choice(self.macs)
        frame_limit = self.random.choice((None, None, 0, 1, 2, 5))
        deliver_ack = self.random.random() < 0.72
        result = mac.sync(self.phone, frame_limit=frame_limit, deliver_ack=deliver_ack)
        self.stats["sync_sessions"] += 1
        self.stats["events_delivered"] += result.new_events
        self.stats["gap_positions_delivered"] += result.new_gap_positions
        self.stats["gap_frames_delivered"] += result.gap_frames
        self.stats["generation_transitions"] += result.generation_transitions
        if result.ack_delivered:
            self.stats["acks_delivered"] += 1
        elif result.delivered_frames and not result.ack_eligible:
            self.stats["acks_withheld_below_phone_ack"] += 1
        elif result.delivered_frames:
            self.stats["acks_lost"] += 1
        if not result.complete:
            self.stats["partial_disconnects"] += 1
        if result.cursor_ahead_reset:
            self.stats["generation_resets"] += 1

    def _apply_random_retention_change(self) -> None:
        pairing_id = self.random.choice(sorted(self.phone.pairings))
        pairing = self.phone.pairings[pairing_id]
        pairing.retention_count = self.random.randint(1, self.config.max_retention_count)
        pairing.retention_age_ms = self.random.randint(
            30_000, self.config.max_retention_age_ms
        )
        self._apply_retention(pairing_id)

    def _regress_random_mac(self) -> None:
        candidates = [
            mac
            for mac in self.macs
            if mac.current_generation == self.phone.generation
            and mac.current.processed_through > mac.current.initial_cursor
        ]
        if not candidates:
            return
        mac = self.random.choice(candidates)
        target = self.random.randint(
            mac.current.initial_cursor, mac.current.processed_through - 1
        )
        mac.regress_current(target)
        self.stats["cursor_regressions"] += 1

    def _reset_generation(self) -> None:
        self.phone.reset_generation()
        self.stats["generation_resets"] += 1

    def _reject_invalid_ack(self) -> None:
        mac = self.random.choice(self.macs)
        self.stats["generation_transitions"] += mac._observe_generation(self.phone)
        session = self.phone.plan_sync(
            mac.pairing_id, mac.current.generation, mac.current.processed_through
        )
        pairing = self.phone.pairings[mac.pairing_id]
        if pairing.acked_seq > 0 and self.random.random() < 0.5:
            invalid_seq = pairing.acked_seq - 1
        else:
            invalid_seq = session.authorized_through + 1
        try:
            self.phone.accept_ack(session, invalid_seq)
        except ProtocolError:
            self.stats["invalid_acks_rejected"] += 1
            return
        raise AssertionError("invalid acknowledgement was accepted")

    def _validate(self, deep: bool = False) -> None:
        self.phone.assert_invariants()
        for mac in self.macs:
            mac.assert_invariants(self.phone, current_only=not deep)

    def step(self) -> None:
        self.phone.advance_time(self.random.randint(1, self.config.max_time_advance_ms))
        operation = self.random.random()
        if operation < 0.40:
            for _ in range(self.random.randint(1, 3)):
                self._append_random_event()
        elif operation < 0.68:
            self._sync_random_mac()
        elif operation < 0.77:
            self._apply_random_retention_change()
        elif operation < 0.84:
            self._regress_random_mac()
        elif operation < 0.90:
            self._reset_generation()
        elif operation < 0.96:
            self._append_random_event("capture_gap")
        else:
            self._reject_invalid_ack()
        self._validate()

    def _state_digest(self) -> str:
        state: Dict[str, Any] = {
            "phone": {
                "generation": self.phone.generation,
                "highwater": self.phone.highwater,
                "now_ms": self.phone.now_ms,
                "outbox": sorted(self.phone.outbox),
                "pairings": {
                    pairing_id: {
                        "acked": pairing.acked_seq,
                        "floor": pairing.serve_from_seq,
                        "gaps": [
                            [gap.from_seq, gap.to_seq, gap.reason]
                            for gap in pairing.gaps
                        ],
                        "retention": pairing.retention_count,
                        "retention_age_ms": pairing.retention_age_ms,
                    }
                    for pairing_id, pairing in sorted(self.phone.pairings.items())
                },
            },
            "macs": {},
        }
        mac_state: Dict[str, Any] = {}
        for mac in self.macs:
            generations: Dict[str, Any] = {}
            for generation, coverage in sorted(mac.generations.items()):
                generations[generation] = {
                    "events": [
                        coverage.events[seq].as_dict()
                        for seq in sorted(coverage.events)
                    ],
                    "gaps": [
                        [seq, coverage.gaps[seq]] for seq in sorted(coverage.gaps)
                    ],
                    "initial": coverage.initial_cursor,
                    "processed": coverage.processed_through,
                }
            mac_state[mac.pairing_id] = {
                "current": mac.current_generation,
                "generations": generations,
                "transitions": mac.transitions,
            }
        state["macs"] = mac_state
        encoded = json.dumps(state, sort_keys=True, separators=(",", ":")).encode()
        return hashlib.sha256(encoded).hexdigest()

    def run(self) -> Dict[str, Any]:
        for _ in range(self.config.steps):
            self.step()

        # A final event gives every pairing a newly authorized cumulative ACK even if
        # its prior ACK was lost after it had already processed the old high-water.
        self._append_random_event("posted")
        for mac in self.macs:
            result = mac.sync(self.phone, frame_limit=None, deliver_ack=True)
            self.stats["sync_sessions"] += 1
            self.stats["events_delivered"] += result.new_events
            self.stats["gap_positions_delivered"] += result.new_gap_positions
            self.stats["gap_frames_delivered"] += result.gap_frames
            self.stats["generation_transitions"] += result.generation_transitions
            if result.ack_delivered:
                self.stats["acks_delivered"] += 1
            if not result.complete:
                raise AssertionError("final drain disconnected unexpectedly")
            mac.assert_current_complete(self.phone)

        self._validate(deep=True)
        if self.phone.outbox:
            raise AssertionError("fully acknowledged final drain left physical outbox rows")
        if any(
            pairing.acked_seq != self.phone.highwater
            for pairing in self.phone.pairings.values()
        ):
            raise AssertionError("final cumulative acknowledgements did not reach high-water")

        summary: Dict[str, Any] = {
            "digest": self._state_digest(),
            "events_assigned_total": self.phone.total_events_assigned,
            "final_generation": self.phone.generation,
            "final_highwater": self.phone.highwater,
            "generations": self.phone.generation_index,
            "max_retention_age_ms": self.config.max_retention_age_ms,
            "pairings": self.config.pairing_count,
            "rows_pruned": self.phone.total_rows_pruned,
            "seed": self.config.seed,
            "status": "pass",
            "steps": self.config.steps,
        }
        summary.update(self.stats)
        return summary


def run_chaos(config: ChaosConfig) -> Dict[str, Any]:
    return ChaosHarness(config).run()


def _connected_socket_pair() -> Tuple[socket.socket, socket.socket]:
    """Return connected stream sockets, with a TCP fallback for older platforms."""

    try:
        return socket.socketpair()
    except (AttributeError, OSError):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        client = socket.create_connection(listener.getsockname())
        server, _ = listener.accept()
        listener.close()
        return server, client


class FakePhone:
    """Minimal framed phone endpoint for deterministic loopback simulation."""

    def __init__(self, event_count: int, gap_through: int = 0) -> None:
        if event_count < 1:
            raise ValueError("event count must be positive")
        if not 0 <= gap_through < event_count:
            raise ValueError("gap_through must be between zero and event_count - 1")
        self.event_count = event_count
        self.gap_through = gap_through

    @staticmethod
    def _event_message(seq: int, sync_id: str) -> Dict[str, Any]:
        content = {
            "big_text": None,
            "group_key": None,
            "info_text": None,
            "is_clearable": True,
            "is_group_summary": False,
            "messages": None,
            "sub_text": None,
            "summary_text": None,
            "text": f"synthetic-{seq}",
            "text_lines": None,
            "title": "Eko simulator",
        }
        # This ASCII/null/boolean object has the same bytes under sorted compact
        # JSON and RFC 8785 JCS, which keeps the fake event hash conformant.
        digest = hashlib.sha256(canonical_json_bytes(content)).hexdigest()
        return {
            "app": {
                "category": "msg",
                "label": "Eko Simulator",
                "pkg": "dev.eko.simulator",
            },
            "dnd": {"filter": "all", "suppressed": False},
            "ev": "posted",
            "flags": {"reconciled": False, "replayed": True},
            "h": digest,
            "key": f"simulated-key-{seq}",
            "n": content,
            "posted_at": 1_700_000_000_000 + seq,
            "seq": seq,
            "sync_id": sync_id,
            "truncated_fields": [],
            "type": "event",
            "user": 0,
        }

    def run(self, sock: socket.socket) -> Dict[str, Any]:
        reader = FramedSocketReader(sock)
        sent_types: List[str] = []
        hello = {
            "caps": ["notif", "dismiss", "otp_context"],
            "conn_epoch": 1,
            "device_id": "a" * 64,
            "device_name": "Fake Android",
            "mode": "normal",
            "os": "android",
            "os_version": 36,
            "outbox_gen": "11111111-2222-4333-8444-555555555555",
            "phone_time": 1_700_000_000_000,
            "proto_max": 1,
            "proto_min": 1,
            "type": "hello",
        }
        send_json_fragmented(sock, hello)
        sent_types.append("hello")

        welcome = reader.receive_json()
        if welcome.get("type") != "welcome" or welcome.get("cursor") != 0:
            raise ProtocolError("fake Mac returned an invalid welcome")

        send_fragmented(sock, encode_frame(0x7F, b"simulated-extension"))
        sent_types.append("frame_0x7f")

        first_event = self.gap_through + 1
        sync_id = "66666666-7777-4888-8999-aaaaaaaaaaaa"
        start = {
            "event_count": self.event_count - self.gap_through,
            "from_seq": first_event,
            "replay_to_seq": self.event_count,
            "sync_id": sync_id,
            "type": "backlog_start",
        }
        send_json_fragmented(sock, start)
        sent_types.append("backlog_start")

        if self.gap_through:
            gap = {
                "from_seq": 1,
                "reason": "retention_count",
                "sync_id": sync_id,
                "to_seq": self.gap_through,
                "type": "backlog_gap",
            }
            send_json_fragmented(sock, gap)
            sent_types.append("backlog_gap")

        for seq in range(first_event, self.event_count + 1):
            send_json_fragmented(sock, self._event_message(seq, sync_id))
            sent_types.append("event")

        send_json_fragmented(
            sock,
            {
                "active": [],
                "final": True,
                "index": 0,
                "sync_id": sync_id,
                "type": "active_chunk",
            },
        )
        sent_types.append("active_chunk")

        send_json_fragmented(
            sock,
            {"state_seq": self.event_count, "sync_id": sync_id, "type": "backlog_end"},
        )
        sent_types.append("backlog_end")

        ack = reader.receive_json()
        if ack.get("type") != "ack" or ack.get("seq") != self.event_count:
            raise ProtocolError("fake Mac did not cumulatively ACK replay_to_seq")
        return {"ack": ack["seq"], "sent_types": sent_types}


class FakeMac:
    """Minimal framed Mac endpoint that enforces exact event-or-gap coverage."""

    def run(self, sock: socket.socket) -> Dict[str, Any]:
        reader = FramedSocketReader(sock)
        received_types: List[str] = []

        hello = reader.receive_json()
        received_types.append(hello["type"])
        if hello["type"] != "hello" or hello.get("device_id") != "a" * 64:
            raise ProtocolError("fake phone sent an invalid hello")

        send_json_fragmented(
            sock,
            {
                "caps": ["notif", "dismiss", "otp_context"],
                "cursor": 0,
                "device_id": "b" * 64,
                "mac_name": "Fake Mac",
                "outbox_gen": hello["outbox_gen"],
                "proto": 1,
                "type": "welcome",
            },
        )

        start = reader.receive_json()
        received_types.append(start["type"])
        if start["type"] != "backlog_start":
            raise ProtocolError("backlog_start must precede replay data")
        replay_to = start.get("replay_to_seq")
        sync_id = start.get("sync_id")
        if not isinstance(replay_to, int) or replay_to < 1 or not isinstance(sync_id, str):
            raise ProtocolError("invalid backlog_start bounds")

        cursor = 0
        event_count = 0
        gap_positions = 0
        active_started = False
        active_final = False
        next_active_index = 0
        while True:
            message = reader.receive_json()
            message_type = message["type"]
            received_types.append(message_type)
            if message_type == "backlog_end":
                if message.get("sync_id") != sync_id:
                    raise ProtocolError("backlog_end sync_id mismatch")
                if message.get("state_seq") != replay_to:
                    raise ProtocolError("backlog_end state_seq mismatch")
                if not active_final:
                    raise ProtocolError("backlog ended before a final active_chunk")
                break
            if message.get("sync_id") != sync_id:
                raise ProtocolError("sync frame has wrong sync_id")
            if message_type == "backlog_gap":
                if active_started:
                    raise ProtocolError("gap arrived after active snapshot started")
                start_seq = message.get("from_seq")
                end_seq = message.get("to_seq")
                if start_seq != cursor + 1 or not isinstance(end_seq, int) or end_seq < start_seq:
                    raise ProtocolError("backlog gap is not contiguous")
                cursor = end_seq
                gap_positions += end_seq - start_seq + 1
            elif message_type == "event":
                if active_started:
                    raise ProtocolError("event arrived after active snapshot started")
                seq = message.get("seq")
                if seq != cursor + 1:
                    raise ProtocolError("event is not contiguous after event/gap coverage")
                cursor = seq
                event_count += 1
            elif message_type == "active_chunk":
                index = message.get("index")
                active = message.get("active")
                final = message.get("final")
                if active_final:
                    raise ProtocolError("active chunk arrived after final chunk")
                if index != next_active_index or not isinstance(active, list):
                    raise ProtocolError("active chunks are missing or out of order")
                if not isinstance(final, bool):
                    raise ProtocolError("active_chunk final must be boolean")
                active_started = True
                active_final = final
                next_active_index += 1
            else:
                raise ProtocolError(f"unexpected replay message: {message_type}")

        if cursor != replay_to:
            raise ProtocolError("backlog ended with uncovered sequence positions")
        if event_count != start.get("event_count"):
            raise ProtocolError("backlog event_count does not match delivered events")
        send_json_fragmented(sock, {"seq": cursor, "type": "ack"})
        return {
            "cursor": cursor,
            "events": event_count,
            "gap_positions": gap_positions,
            "received_types": received_types,
            "skipped_frame_types": reader.skipped_frame_types,
        }


def run_framed_simulation(event_count: int = 12, gap_through: int = 3) -> Dict[str, Any]:
    """Run fake phone and Mac peers over deterministically fragmented sockets."""

    phone_socket, mac_socket = _connected_socket_pair()
    phone_socket.settimeout(5.0)
    mac_socket.settimeout(5.0)
    results: "queue.Queue[Tuple[str, Any, Optional[BaseException]]]" = queue.Queue()

    def run_endpoint(name: str, endpoint: Any, endpoint_socket: socket.socket) -> None:
        try:
            results.put((name, endpoint.run(endpoint_socket), None))
        except BaseException as exc:  # Preserve thread traceback cause for the caller.
            results.put((name, None, exc))

    threads = [
        threading.Thread(
            target=run_endpoint,
            args=("phone", FakePhone(event_count, gap_through), phone_socket),
            daemon=True,
        ),
        threading.Thread(
            target=run_endpoint,
            args=("mac", FakeMac(), mac_socket),
            daemon=True,
        ),
    ]
    for thread in threads:
        thread.start()

    collected: Dict[str, Any] = {}
    errors: List[BaseException] = []
    try:
        for _ in threads:
            name, result, error = results.get(timeout=7.0)
            if error is not None:
                errors.append(error)
            else:
                collected[name] = result
    finally:
        phone_socket.close()
        mac_socket.close()
        for thread in threads:
            thread.join(timeout=1.0)

    if errors:
        raise errors[0]
    if any(thread.is_alive() for thread in threads):
        raise TimeoutError("fake endpoint did not terminate")

    transcript = {
        "event_count": event_count,
        "gap_through": gap_through,
        "mac": collected["mac"],
        "phone": collected["phone"],
    }
    digest = hashlib.sha256(
        json.dumps(transcript, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return {"digest": digest, "status": "pass", **transcript}


def detect_truncated_frame(cut_at: int) -> Dict[str, Any]:
    encoded = encode_json_frame(
        {"device_id": "a" * 64, "mode": "normal", "type": "hello"}
    )
    if not 0 < cut_at < len(encoded):
        raise ValueError(f"cut_at must be between 1 and {len(encoded) - 1}")
    decoder = FrameDecoder()
    decoder.feed(encoded[:cut_at])
    try:
        decoder.finish()
    except IncompleteFrame as exc:
        return {
            "cut_at": cut_at,
            "encoded_bytes": len(encoded),
            "error": str(exc),
            "status": "pass",
        }
    raise AssertionError("truncated frame was accepted as complete")


def _print_summary(summary: Mapping[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(summary, sort_keys=True, separators=(",", ":")))
        return
    if "seed" in summary:
        print(
            "PASS chaos "
            f"seed={summary['seed']} steps={summary['steps']} "
            f"pairings={summary['pairings']} generations={summary['generations']} "
            f"events={summary['events_assigned_total']} "
            f"gaps={summary['gap_positions_delivered']} digest={summary['digest']}"
        )
    elif "cut_at" in summary:
        print(
            "PASS framing rejected truncation "
            f"cut_at={summary['cut_at']}/{summary['encoded_bytes']} "
            f"error={summary['error']}"
        )
    else:
        print(
            "PASS framed simulation "
            f"events={summary['event_count']} gap_through={summary['gap_through']} "
            f"cursor={summary['mac']['cursor']} digest={summary['digest']}"
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    chaos = subparsers.add_parser(
        "chaos", help="run deterministic randomized reference-model operations"
    )
    chaos.add_argument("--seed", type=int, default=20_260_724)
    chaos.add_argument("--steps", type=int, default=1_000)
    chaos.add_argument("--pairings", type=int, default=3)
    chaos.add_argument("--max-retention-count", type=int, default=31)
    chaos.add_argument("--max-retention-age-ms", type=int, default=3_600_000)
    chaos.add_argument("--runs", type=int, default=1)
    chaos.add_argument("--json", action="store_true")

    simulate = subparsers.add_parser(
        "simulate", help="run fragmented fake phone/Mac application frames"
    )
    simulate.add_argument("--events", type=int, default=12)
    simulate.add_argument("--gap-through", type=int, default=3)
    simulate.add_argument("--truncate-at", type=int)
    simulate.add_argument("--json", action="store_true")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "chaos":
            if args.runs < 1:
                raise ValueError("runs must be positive")
            summaries = []
            for offset in range(args.runs):
                config = ChaosConfig(
                    seed=args.seed + offset,
                    steps=args.steps,
                    pairing_count=args.pairings,
                    max_retention_count=args.max_retention_count,
                    max_retention_age_ms=args.max_retention_age_ms,
                )
                summary = run_chaos(config)
                summaries.append(summary)
                if not args.json:
                    _print_summary(summary, as_json=False)
            if args.json:
                output: Any = summaries[0] if len(summaries) == 1 else summaries
                print(json.dumps(output, sort_keys=True, separators=(",", ":")))
            elif len(summaries) > 1:
                print(
                    f"PASS {len(summaries)} deterministic runs "
                    f"seeds={args.seed}..{args.seed + len(summaries) - 1}"
                )
        elif args.command == "simulate":
            if args.truncate_at is not None:
                summary = detect_truncated_frame(args.truncate_at)
            else:
                summary = run_framed_simulation(args.events, args.gap_through)
            _print_summary(summary, as_json=args.json)
        else:
            parser.error(f"unknown command: {args.command}")
    except (AssertionError, CursorAhead, IncompleteFrame, ProtocolError, ValueError) as exc:
        print(f"FAIL {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
