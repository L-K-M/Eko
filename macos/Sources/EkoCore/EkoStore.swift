import Foundation
import GRDB

public enum PeerAuthorization: Equatable, Sendable {
    case paired(deviceID: String)
    case pendingPairing(deviceID: String)
    case revoked(deviceID: String)
    case unknown
    case certificateMismatch
}

public struct SessionStart: Equatable, Sendable {
    public let device: Device
    public let cursor: Int64
    public let generationChanged: Bool
}

public enum SessionAdmission: Equatable, Sendable {
    case started(SessionStart)
    case retiredGeneration
}

public struct FeedQuery: Equatable, Sendable {
    public var search: String
    public var deviceID: String?
    public var codesOnly: Bool
    public var limit: Int

    public init(search: String = "", deviceID: String? = nil, codesOnly: Bool = false, limit: Int = 300) {
        self.search = search
        self.deviceID = deviceID
        self.codesOnly = codesOnly
        self.limit = limit
    }
}

public struct PersistedPairingAttempt: Equatable, Sendable {
    public let attemptID: String
    public let deviceID: String
    public let deviceName: String
    public let localDeviceName: String
    public let peerCertificateDER: Data
    public let localNonce: Data
    public let localCommitment: Data
    public let peerCommitment: Data
    public let peerNonce: Data
    public let verificationCode: String
    public let transcriptHash: Data
    public let qrPreauthenticated: Bool
    public let localConfirmed: Bool
    public let peerConfirmed: Bool
    public let highestConnectionEpoch: Int64
    public let outboxGeneration: String
    public let initialCursor: Int64?
    public let expiresAt: Date

    public init(
        attemptID: String,
        deviceID: String,
        deviceName: String,
        localDeviceName: String,
        peerCertificateDER: Data,
        localNonce: Data,
        localCommitment: Data,
        peerCommitment: Data,
        peerNonce: Data,
        verificationCode: String,
        transcriptHash: Data,
        qrPreauthenticated: Bool,
        localConfirmed: Bool,
        peerConfirmed: Bool,
        highestConnectionEpoch: Int64,
        outboxGeneration: String,
        initialCursor: Int64?,
        expiresAt: Date
    ) {
        self.attemptID = attemptID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.localDeviceName = localDeviceName
        self.peerCertificateDER = peerCertificateDER
        self.localNonce = localNonce
        self.localCommitment = localCommitment
        self.peerCommitment = peerCommitment
        self.peerNonce = peerNonce
        self.verificationCode = verificationCode
        self.transcriptHash = transcriptHash
        self.qrPreauthenticated = qrPreauthenticated
        self.localConfirmed = localConfirmed
        self.peerConfirmed = peerConfirmed
        self.highestConnectionEpoch = highestConnectionEpoch
        self.outboxGeneration = outboxGeneration
        self.initialCursor = initialCursor
        self.expiresAt = expiresAt
    }
}

public final class EkoStore: @unchecked Sendable {
    public static let migrationIdentifiers = [
        "001_initial_event_store",
        "002_search_otp_and_preferences",
        "003_generation_pairing_and_sessions",
        "004_integrity_indexes",
        "005_notification_sound_preferences",
        "006_protocol_v1_state",
        "007_qr_consumption_and_coverage_receipts",
    ]

    private let pool: DatabasePool
    private let path: String
    private let clock: any EkoClock
    private let otpExtractor: OTPExtractor

    public init(path: String, clock: any EkoClock = SystemEkoClock(), otpExtractor: OTPExtractor = OTPExtractor()) throws {
        self.path = path
        self.clock = clock
        self.otpExtractor = otpExtractor

        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(5)
        configuration.maximumReaderCount = 4
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        self.pool = try DatabasePool(path: path, configuration: configuration)
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
            let synchronous = try Int.fetchOne(db, sql: "PRAGMA synchronous")
            guard synchronous == 2 else {
                throw EkoCoreError.storage("SQLite refused synchronous=FULL")
            }
            let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode")
            guard journalMode?.lowercased() == "wal" else {
                throw EkoCoreError.storage("SQLite is not operating in WAL mode")
            }
        }
        try Self.makeMigrator().migrate(pool)
    }

    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration(migrationIdentifiers[0]) { db in
            try db.execute(sql: """
                CREATE TABLE device (
                    id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 64),
                    name TEXT NOT NULL,
                    pinned_cert_der BLOB NOT NULL,
                    pairing_state TEXT NOT NULL DEFAULT 'confirmed'
                        CHECK (pairing_state IN ('pending', 'confirmed', 'revoked_pending')),
                    current_generation TEXT,
                    processed_through_seq INTEGER NOT NULL DEFAULT 0 CHECK (processed_through_seq >= 0),
                    initial_cursor INTEGER NOT NULL DEFAULT 0 CHECK (initial_cursor >= 0),
                    last_ip TEXT,
                    capabilities_json TEXT NOT NULL DEFAULT '[]',
                    last_seen_ms INTEGER
                )
                """)
            try db.execute(sql: """
                CREATE TABLE event (
                    device_id TEXT NOT NULL REFERENCES device(id) ON DELETE CASCADE,
                    outbox_gen TEXT NOT NULL,
                    seq INTEGER NOT NULL CHECK (seq > 0),
                    kind TEXT NOT NULL CHECK (kind IN ('posted', 'updated', 'removed', 'capture_gap')),
                    notification_key TEXT,
                    payload_json BLOB NOT NULL,
                    content_hash TEXT,
                    received_at_ms INTEGER NOT NULL,
                    replayed INTEGER NOT NULL DEFAULT 0 CHECK (replayed IN (0, 1)),
                    PRIMARY KEY (device_id, outbox_gen, seq)
                ) WITHOUT ROWID
                """)
            try db.execute(sql: """
                CREATE TABLE gap_span (
                    device_id TEXT NOT NULL REFERENCES device(id) ON DELETE CASCADE,
                    outbox_gen TEXT NOT NULL,
                    from_seq INTEGER NOT NULL,
                    to_seq INTEGER NOT NULL,
                    reason TEXT NOT NULL,
                    start_time_ms INTEGER,
                    end_time_ms INTEGER,
                    confidence TEXT NOT NULL CHECK (confidence IN ('definitive', 'suspected')),
                    created_at_ms INTEGER NOT NULL,
                    CHECK (from_seq > 0 AND to_seq >= from_seq),
                    PRIMARY KEY (device_id, outbox_gen, from_seq, to_seq)
                ) WITHOUT ROWID
                """)
            try db.execute(sql: """
                CREATE TABLE notification (
                    device_id TEXT NOT NULL REFERENCES device(id) ON DELETE CASCADE,
                    outbox_gen TEXT NOT NULL,
                    notification_key TEXT NOT NULL,
                    app_package TEXT NOT NULL,
                    app_label TEXT NOT NULL,
                    title TEXT,
                    body TEXT NOT NULL,
                    payload_json BLOB NOT NULL,
                    content_hash TEXT,
                    last_state_seq INTEGER NOT NULL CHECK (last_state_seq >= 0),
                    posted_at_ms INTEGER,
                    received_at_ms INTEGER NOT NULL,
                    is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
                    is_replayed INTEGER NOT NULL DEFAULT 0 CHECK (is_replayed IN (0, 1)),
                    is_group_summary INTEGER NOT NULL DEFAULT 0 CHECK (is_group_summary IN (0, 1)),
                    PRIMARY KEY (device_id, outbox_gen, notification_key)
                ) WITHOUT ROWID
                """)
            try db.execute(sql: "CREATE INDEX event_received_idx ON event(device_id, received_at_ms DESC)")
            try db.execute(sql: "CREATE INDEX notification_received_idx ON notification(device_id, received_at_ms DESC)")
            try db.execute(sql: "CREATE INDEX gap_created_idx ON gap_span(device_id, created_at_ms DESC)")
        }

        migrator.registerMigration(migrationIdentifiers[1]) { db in
            try db.execute(sql: "ALTER TABLE notification ADD COLUMN search_text TEXT NOT NULL DEFAULT ''")
            try db.execute(sql: "ALTER TABLE notification ADD COLUMN is_starred INTEGER NOT NULL DEFAULT 0 CHECK (is_starred IN (0, 1))")
            try db.execute(sql: """
                CREATE TABLE otp (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    device_id TEXT NOT NULL REFERENCES device(id) ON DELETE CASCADE,
                    outbox_gen TEXT NOT NULL,
                    notification_key TEXT NOT NULL,
                    event_seq INTEGER NOT NULL CHECK (event_seq >= 0),
                    code TEXT NOT NULL,
                    method TEXT NOT NULL,
                    detected_at_ms INTEGER NOT NULL,
                    banner_eligible INTEGER NOT NULL CHECK (banner_eligible IN (0, 1)),
                    copied_at_ms INTEGER,
                    UNIQUE (device_id, outbox_gen, notification_key, event_seq, code)
                )
                """)
            try db.execute(sql: """
                CREATE TABLE app_preference (
                    device_id TEXT NOT NULL REFERENCES device(id) ON DELETE CASCADE,
                    app_package TEXT NOT NULL,
                    banner_mode TEXT NOT NULL DEFAULT 'normal'
                        CHECK (banner_mode IN ('normal', 'silent', 'muted')),
                    auto_copy_otp INTEGER NOT NULL DEFAULT 0 CHECK (auto_copy_otp IN (0, 1)),
                    PRIMARY KEY (device_id, app_package)
                ) WITHOUT ROWID
                """)
            try db.execute(sql: "CREATE INDEX notification_search_idx ON notification(device_id, search_text)")
            try db.execute(sql: "CREATE INDEX otp_recent_idx ON otp(device_id, code, detected_at_ms DESC)")
            try db.execute(sql: "CREATE INDEX otp_notification_idx ON otp(device_id, outbox_gen, notification_key, event_seq DESC)")
        }

        migrator.registerMigration(migrationIdentifiers[2]) { db in
            try db.execute(sql: "ALTER TABLE device ADD COLUMN highest_protocol INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE device ADD COLUMN highest_conn_epoch INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: """
                CREATE TABLE retired_generation (
                    device_id TEXT NOT NULL REFERENCES device(id) ON DELETE CASCADE,
                    outbox_gen TEXT NOT NULL,
                    retired_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (device_id, outbox_gen)
                ) WITHOUT ROWID
                """)
            try db.execute(sql: """
                CREATE TABLE generation_transition (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    device_id TEXT NOT NULL REFERENCES device(id) ON DELETE CASCADE,
                    old_generation TEXT,
                    new_generation TEXT NOT NULL,
                    transitioned_at_ms INTEGER NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE pairing_attempt (
                    attempt_id TEXT PRIMARY KEY NOT NULL,
                    device_id TEXT NOT NULL,
                    device_name TEXT NOT NULL,
                    peer_cert_der BLOB NOT NULL,
                    local_nonce BLOB NOT NULL,
                    local_commitment BLOB NOT NULL,
                    peer_commitment BLOB NOT NULL,
                    peer_nonce BLOB NOT NULL,
                    verification_code TEXT NOT NULL,
                    transcript_hash BLOB NOT NULL,
                    qr_preauthenticated INTEGER NOT NULL CHECK (qr_preauthenticated IN (0, 1)),
                    local_confirmed INTEGER NOT NULL DEFAULT 0 CHECK (local_confirmed IN (0, 1)),
                    peer_confirmed INTEGER NOT NULL DEFAULT 0 CHECK (peer_confirmed IN (0, 1)),
                    expires_at_ms INTEGER NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX pairing_attempt_expiry_idx ON pairing_attempt(expires_at_ms)")
        }

        migrator.registerMigration(migrationIdentifiers[3]) { db in
            try db.execute(sql: "CREATE INDEX event_notification_idx ON event(device_id, outbox_gen, notification_key, seq DESC)")
            try db.execute(sql: "CREATE INDEX notification_active_idx ON notification(device_id, outbox_gen, is_active, last_state_seq)")
            try db.execute(sql: "CREATE INDEX generation_transition_device_idx ON generation_transition(device_id, transitioned_at_ms DESC)")
        }
        migrator.registerMigration(migrationIdentifiers[4]) { db in
            try db.execute(sql: "ALTER TABLE app_preference ADD COLUMN sound_enabled INTEGER NOT NULL DEFAULT 0 CHECK (sound_enabled IN (0, 1))")
        }
        migrator.registerMigration(migrationIdentifiers[5]) { db in
            try db.execute(sql: "ALTER TABLE notification ADD COLUMN body_complete INTEGER NOT NULL DEFAULT 1 CHECK (body_complete IN (0, 1))")
            try db.execute(sql: "ALTER TABLE pairing_attempt ADD COLUMN highest_conn_epoch INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE pairing_attempt ADD COLUMN outbox_gen TEXT NOT NULL DEFAULT ''")
            try db.execute(sql: "ALTER TABLE pairing_attempt ADD COLUMN initial_cursor INTEGER")
            try db.execute(sql: "ALTER TABLE pairing_attempt ADD COLUMN local_device_name TEXT NOT NULL DEFAULT ''")
            try db.execute(sql: """
                CREATE TABLE pairing_peer_epoch (
                    device_id TEXT PRIMARY KEY NOT NULL,
                    highest_conn_epoch INTEGER NOT NULL
                ) WITHOUT ROWID
                """)
            try db.execute(sql: """
                CREATE TABLE unpair_tombstone (
                    unpair_id TEXT PRIMARY KEY NOT NULL,
                    device_id TEXT NOT NULL REFERENCES device(id) ON DELETE CASCADE,
                    initiator_id TEXT NOT NULL,
                    peer_id TEXT NOT NULL,
                    reason TEXT NOT NULL CHECK (reason IN ('user_request', 'identity_replaced')),
                    status TEXT NOT NULL CHECK (status IN ('pending', 'applied')),
                    created_at_ms INTEGER NOT NULL
                ) WITHOUT ROWID
                """)
            try db.execute(sql: "CREATE INDEX unpair_tombstone_device_idx ON unpair_tombstone(device_id, status)")
        }
        migrator.registerMigration(migrationIdentifiers[6]) { db in
            try db.execute(sql: """
                CREATE TABLE consumed_qr_token (
                    token TEXT PRIMARY KEY NOT NULL,
                    attempt_id TEXT NOT NULL,
                    expires_at_ms INTEGER NOT NULL
                ) WITHOUT ROWID
                """)
            try db.execute(sql: "CREATE INDEX consumed_qr_token_expiry_idx ON consumed_qr_token(expires_at_ms)")
            try db.execute(sql: "ALTER TABLE event ADD COLUMN payload_pruned INTEGER NOT NULL DEFAULT 0 CHECK (payload_pruned IN (0, 1))")
        }
        return migrator
    }

    public func peerAuthorization(for certificateDER: Data) throws -> PeerAuthorization {
        let fingerprint = EkoCrypto.fingerprint(of: certificateDER)
        return try pool.read { db in
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT pinned_cert_der, pairing_state FROM device WHERE id = ?",
                arguments: [fingerprint]
            ) {
                let stored: Data = row["pinned_cert_der"]
                guard EkoCrypto.constantTimeEqual(stored, certificateDER) else { return .certificateMismatch }
                let state: String = row["pairing_state"]
                return state == PairingState.revokedPending.rawValue
                    ? .revoked(deviceID: fingerprint)
                    : .paired(deviceID: fingerprint)
            }
            if let pendingDER = try Data.fetchOne(
                db,
                sql: """
                    SELECT peer_cert_der FROM pairing_attempt
                    WHERE device_id = ? AND expires_at_ms > ?
                    ORDER BY expires_at_ms DESC LIMIT 1
                    """,
                arguments: [fingerprint, millisecondsSinceEpoch(clock.now())]
            ) {
                return EkoCrypto.constantTimeEqual(pendingDER, certificateDER)
                    ? .pendingPairing(deviceID: fingerprint)
                    : .certificateMismatch
            }
            return .unknown
        }
    }

    public func device(id: String) throws -> Device? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM device WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return try Self.decodeDevice(row)
        }
    }

    public func devices() throws -> [Device] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM device ORDER BY name COLLATE NOCASE")
                .map(Self.decodeDevice)
        }
    }

    public func recentEvents(deviceID: String? = nil, limit: Int = 200) throws -> [StoredEvent] {
        let bounded = min(max(limit, 1), 1_000)
        return try pool.read { db in
            let rows: [Row]
            if let deviceID {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM event WHERE device_id = ? ORDER BY received_at_ms DESC LIMIT ?",
                    arguments: [deviceID, bounded]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM event ORDER BY received_at_ms DESC LIMIT ?",
                    arguments: [bounded]
                )
            }
            return try rows.map { row in
                let rawKind: String = row["kind"]
                guard let kind = EventKind(rawValue: rawKind) else {
                    throw EkoCoreError.storage("event has invalid kind")
                }
                let received: Int64 = row["received_at_ms"]
                return StoredEvent(
                    deviceID: row["device_id"],
                    generation: row["outbox_gen"],
                    sequence: row["seq"],
                    kind: kind,
                    notificationKey: row["notification_key"],
                    payloadJSON: row["payload_json"],
                    contentHash: row["content_hash"],
                    receivedAt: dateFromMilliseconds(received),
                    replayed: row["replayed"],
                    payloadPruned: row["payload_pruned"]
                )
            }
        }
    }

    public func confirmPairing(
        hello: HelloMessage,
        certificateDER: Data,
        initialCursor: Int64,
        negotiatedProtocol: Int,
        endpoint: String?,
        completedAttemptID: String? = nil
    ) throws -> Device {
        let fingerprint = EkoCrypto.fingerprint(of: certificateDER)
        guard fingerprint == hello.deviceID, let generation = hello.outboxGeneration,
              initialCursor >= 0 else {
            throw EkoCoreError.unauthorized
        }
        let capabilities = try Self.encodeCapabilities(hello.capabilities)
        let now = millisecondsSinceEpoch(clock.now())
        return try pool.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT pinned_cert_der FROM device WHERE id = ?", arguments: [fingerprint]) {
                let existing: Data = row["pinned_cert_der"]
                guard EkoCrypto.constantTimeEqual(existing, certificateDER) else { throw EkoCoreError.unauthorized }
            }
            // An explicitly confirmed new pairing supersedes every revocation receipt and
            // pending pair attempt for this certificate, atomically with the pin commit.
            // The attempt that is completing right now must survive: pair_result{confirmed}
            // is sent only after this transaction, and if that frame is lost the phone
            // resumes under the same attempt_id (protocol.md §7.4) — deleting its row
            // here made every resume land in `unauthorized` and wedged pairing.
            try db.execute(sql: "DELETE FROM unpair_tombstone WHERE device_id = ?", arguments: [fingerprint])
            if let completedAttemptID {
                try db.execute(
                    sql: "DELETE FROM pairing_attempt WHERE device_id = ? AND attempt_id != ?",
                    arguments: [fingerprint, completedAttemptID]
                )
            } else {
                try db.execute(sql: "DELETE FROM pairing_attempt WHERE device_id = ?", arguments: [fingerprint])
            }
            try db.execute(
                sql: """
                    INSERT INTO device (
                        id, name, pinned_cert_der, pairing_state, current_generation,
                        processed_through_seq, initial_cursor, last_ip, capabilities_json,
                        last_seen_ms, highest_protocol, highest_conn_epoch
                    ) VALUES (?, ?, ?, 'confirmed', ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        pairing_state = 'confirmed',
                        current_generation = excluded.current_generation,
                        processed_through_seq = CASE
                            WHEN device.current_generation = excluded.current_generation
                                THEN MAX(device.processed_through_seq, excluded.processed_through_seq)
                            ELSE excluded.processed_through_seq
                        END,
                        initial_cursor = CASE
                            WHEN device.current_generation = excluded.current_generation
                                THEN MAX(device.initial_cursor, excluded.initial_cursor)
                            ELSE excluded.initial_cursor
                        END,
                        last_ip = excluded.last_ip,
                        capabilities_json = excluded.capabilities_json,
                        last_seen_ms = excluded.last_seen_ms,
                        highest_protocol = MAX(device.highest_protocol, excluded.highest_protocol),
                        highest_conn_epoch = MAX(device.highest_conn_epoch, excluded.highest_conn_epoch)
                    """,
                arguments: [
                    fingerprint, hello.deviceName, certificateDER, generation,
                    initialCursor, initialCursor, endpoint, capabilities, now,
                    negotiatedProtocol, hello.connectionEpoch,
                ]
            )
            try Self.recordPeerEpoch(
                db,
                deviceID: fingerprint,
                certificateDER: certificateDER,
                epoch: hello.connectionEpoch
            )
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM device WHERE id = ?", arguments: [fingerprint]) else {
                throw EkoCoreError.storage("paired device was not persisted")
            }
            return try Self.decodeDevice(row)
        }
    }

    /// Admits a normal-session hello in one atomic transaction: epoch eligibility, epoch
    /// high-water advancement, generation selection, and the session device update commit
    /// together. A retired generation rejects the admission; per protocol the epoch
    /// high-water still advances (it is accepted before generation processing), but no
    /// generation, cursor, or session state is touched, so a later valid hello at a newer
    /// epoch is unaffected.
    public func beginSession(
        hello: HelloMessage,
        certificateDER: Data,
        negotiatedProtocol: Int,
        endpoint: String?
    ) throws -> SessionAdmission {
        let fingerprint = EkoCrypto.fingerprint(of: certificateDER)
        guard fingerprint == hello.deviceID, let generation = hello.outboxGeneration else {
            throw EkoCoreError.unauthorized
        }
        let now = millisecondsSinceEpoch(clock.now())
        let capabilities = try Self.encodeCapabilities(hello.capabilities)

        return try pool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM device WHERE id = ?", arguments: [fingerprint]) else {
                throw EkoCoreError.unauthorized
            }
            let storedCertificate: Data = row["pinned_cert_der"]
            let pairingState: String = row["pairing_state"]
            let highestProtocol: Int = row["highest_protocol"]
            let highestEpoch: Int64 = row["highest_conn_epoch"]
            let peerEpoch = try Int64.fetchOne(
                db,
                sql: "SELECT highest_conn_epoch FROM pairing_peer_epoch WHERE device_id = ?",
                arguments: [fingerprint]
            ) ?? 0
            guard EkoCrypto.constantTimeEqual(storedCertificate, certificateDER),
                  pairingState == PairingState.confirmed.rawValue else {
                throw EkoCoreError.unauthorized
            }
            guard hello.protoMax >= highestProtocol else { throw EkoCoreError.incompatibleProtocol }
            guard hello.connectionEpoch > max(highestEpoch, peerEpoch) else { throw EkoCoreError.superseded }
            try db.execute(
                sql: "UPDATE device SET highest_conn_epoch = ? WHERE id = ?",
                arguments: [hello.connectionEpoch, fingerprint]
            )
            try Self.recordPeerEpoch(
                db,
                deviceID: fingerprint,
                certificateDER: certificateDER,
                epoch: hello.connectionEpoch
            )

            let oldGeneration: String? = row["current_generation"]
            if oldGeneration != generation {
                let isRetired = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM retired_generation WHERE device_id = ? AND outbox_gen = ?)",
                    arguments: [fingerprint, generation]
                ) == true
                if isRetired {
                    return .retiredGeneration
                }
            }

            var generationChanged = false
            var cursor: Int64 = row["processed_through_seq"]
            if oldGeneration != generation {
                if let oldGeneration {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO retired_generation(device_id, outbox_gen, retired_at_ms) VALUES (?, ?, ?)",
                        arguments: [fingerprint, oldGeneration, now]
                    )
                    try db.execute(
                        sql: "UPDATE notification SET is_active = 0 WHERE device_id = ? AND outbox_gen = ?",
                        arguments: [fingerprint, oldGeneration]
                    )
                }
                try db.execute(
                    sql: "INSERT INTO generation_transition(device_id, old_generation, new_generation, transitioned_at_ms) VALUES (?, ?, ?, ?)",
                    arguments: [fingerprint, oldGeneration, generation, now]
                )
                cursor = 0
                generationChanged = true
            }

            try db.execute(
                sql: """
                    UPDATE device SET
                        name = ?, current_generation = ?, processed_through_seq = ?,
                        initial_cursor = CASE WHEN ? THEN 0 ELSE initial_cursor END,
                        last_ip = ?, capabilities_json = ?, last_seen_ms = ?,
                        highest_protocol = MAX(highest_protocol, ?)
                    WHERE id = ?
                    """,
                arguments: [
                    hello.deviceName, generation, cursor, generationChanged,
                    endpoint, capabilities, now, negotiatedProtocol, fingerprint,
                ]
            )
            guard let updated = try Row.fetchOne(db, sql: "SELECT * FROM device WHERE id = ?", arguments: [fingerprint]) else {
                throw EkoCoreError.storage("session device disappeared")
            }
            return .started(SessionStart(
                device: try Self.decodeDevice(updated),
                cursor: cursor,
                generationChanged: generationChanged
            ))
        }
    }

    public func reserveRestrictedEpoch(deviceID: String, certificateDER: Data, epoch: Int64) throws {
        try pool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT pinned_cert_der, highest_conn_epoch FROM device WHERE id = ?",
                arguments: [deviceID]
            ) else { throw EkoCoreError.unauthorized }
            let storedCertificate: Data = row["pinned_cert_der"]
            let highestEpoch: Int64 = row["highest_conn_epoch"]
            let peerEpoch = try Int64.fetchOne(
                db,
                sql: "SELECT highest_conn_epoch FROM pairing_peer_epoch WHERE device_id = ?",
                arguments: [deviceID]
            ) ?? 0
            guard EkoCrypto.constantTimeEqual(storedCertificate, certificateDER) else {
                throw EkoCoreError.unauthorized
            }
            guard epoch > max(highestEpoch, peerEpoch) else { throw EkoCoreError.superseded }
            try db.execute(
                sql: "UPDATE device SET highest_conn_epoch = ? WHERE id = ?",
                arguments: [epoch, deviceID]
            )
            try Self.recordPeerEpoch(
                db,
                deviceID: deviceID,
                certificateDER: certificateDER,
                epoch: epoch
            )
        }
    }

    public func ingestEvent(deviceID: String, generation: String, event: EventMessage) throws -> IngestOutcome {
        guard let sequence = event.sequence else {
            throw EkoCoreError.protocolViolation("sequenced ingest requires seq")
        }
        let payload = try ProtocolCodec.encode(.event(event))
        let receivedAt = millisecondsSinceEpoch(clock.now())
        let replayed = event.flags.replayed
        let otp = event.notification.flatMap(otpExtractor.extract)

        return try pool.write { db in
            let cursor = try Self.requireCurrentCursor(db, deviceID: deviceID, generation: generation)
            if sequence <= cursor {
                if let stored = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT payload_json, payload_pruned, kind, notification_key, content_hash FROM event
                        WHERE device_id = ? AND outbox_gen = ? AND seq = ?
                        """,
                    arguments: [deviceID, generation, sequence]
                ) {
                    let pruned: Bool = stored["payload_pruned"]
                    if pruned {
                        // A pruned receipt proves the position was committed; duplicate
                        // detection compares the retained receipt fields only.
                        let storedKind: String = stored["kind"]
                        let storedKey: String? = stored["notification_key"]
                        let storedHash: String? = stored["content_hash"]
                        guard storedKind == event.event.rawValue,
                              storedKey == event.key,
                              storedHash == event.contentHash else {
                            throw EkoCoreError.sequenceConflict
                        }
                    } else {
                        let storedPayload: Data = stored["payload_json"]
                        guard case .event(let storedEvent) = try ProtocolCodec.decode(storedPayload),
                              Self.durablyEquivalent(storedEvent, event) else {
                            throw EkoCoreError.sequenceConflict
                        }
                    }
                } else {
                    throw EkoCoreError.sequenceConflict
                }
                return Self.outcome(
                    deviceID: deviceID,
                    generation: generation,
                    sequence: sequence,
                    event: event,
                    otp: otp,
                    otpBannerEligible: false,
                    replayed: replayed,
                    duplicate: true
                )
            }
            guard sequence == cursor + 1 else {
                throw EkoCoreError.protocolViolation("event sequence \(sequence) does not cover cursor \(cursor)")
            }

            try db.execute(
                sql: """
                    INSERT INTO event (
                        device_id, outbox_gen, seq, kind, notification_key,
                        payload_json, content_hash, received_at_ms, replayed
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    deviceID, generation, sequence, event.event.rawValue, event.key,
                    payload, event.contentHash, receivedAt, replayed,
                ]
            )

            var otpBannerEligible = false
            switch event.event {
            case .posted, .updated:
                guard let key = event.key, let app = event.app, let content = event.notification else {
                    throw EkoCoreError.protocolViolation("notification event is incomplete")
                }
                let title = content.title
                let body = content.displayBody
                let searchText = [app.label, app.package, title, body]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .normalizedForSearch
                try db.execute(
                    sql: """
                        INSERT INTO notification (
                            device_id, outbox_gen, notification_key, app_package, app_label,
                            title, body, payload_json, content_hash, last_state_seq,
                            posted_at_ms, received_at_ms, is_active, is_replayed,
                            is_group_summary, search_text
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
                        ON CONFLICT(device_id, outbox_gen, notification_key) DO UPDATE SET
                            app_package = excluded.app_package,
                            app_label = excluded.app_label,
                            title = excluded.title,
                            body = excluded.body,
                            payload_json = excluded.payload_json,
                            content_hash = excluded.content_hash,
                            last_state_seq = excluded.last_state_seq,
                            posted_at_ms = excluded.posted_at_ms,
                            received_at_ms = excluded.received_at_ms,
                            is_active = 1,
                            body_complete = 1,
                            is_replayed = excluded.is_replayed,
                            is_group_summary = excluded.is_group_summary,
                            search_text = excluded.search_text
                        WHERE excluded.last_state_seq >= notification.last_state_seq
                        """,
                    arguments: [
                        deviceID, generation, key, app.package, app.label, title, body,
                        payload, event.contentHash, sequence, event.postedAt, receivedAt,
                        replayed, content.isGroupSummary, searchText,
                    ]
                )
                if let otp {
                    let cutoff = receivedAt - 10 * 60 * 1_000
                    let alreadyPresented = try Bool.fetchOne(
                        db,
                        sql: """
                            SELECT EXISTS(
                                SELECT 1 FROM otp
                                WHERE device_id = ? AND code = ? AND detected_at_ms >= ?
                                  AND banner_eligible = 1
                            )
                            """,
                        arguments: [deviceID, otp.code, cutoff]
                    ) ?? false
                    otpBannerEligible = !alreadyPresented
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO otp (
                                device_id, outbox_gen, notification_key, event_seq, code,
                                method, detected_at_ms, banner_eligible
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            deviceID, generation, key, sequence, otp.code,
                            otp.method.rawValue, receivedAt, otpBannerEligible,
                        ]
                    )
                }

            case .removed:
                guard let key = event.key else { throw EkoCoreError.protocolViolation("removed event has no key") }
                try db.execute(
                    sql: """
                        UPDATE notification
                        SET is_active = 0, last_state_seq = ?, received_at_ms = ?
                        WHERE device_id = ? AND outbox_gen = ? AND notification_key = ?
                          AND last_state_seq <= ?
                        """,
                    arguments: [sequence, receivedAt, deviceID, generation, key, sequence]
                )

            case .captureGap:
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO gap_span (
                            device_id, outbox_gen, from_seq, to_seq, reason,
                            start_time_ms, end_time_ms, confidence, created_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, 'suspected', ?)
                        """,
                    arguments: [
                        deviceID, generation, sequence, sequence,
                        event.evidence ?? "capture_gap", event.interval?.startAt, event.interval?.endAt, receivedAt,
                    ]
                )
            }

            try db.execute(
                sql: "UPDATE device SET processed_through_seq = ?, last_seen_ms = ? WHERE id = ?",
                arguments: [sequence, receivedAt, deviceID]
            )
            return Self.outcome(
                deviceID: deviceID,
                generation: generation,
                sequence: sequence,
                event: event,
                otp: otp,
                otpBannerEligible: otpBannerEligible,
                replayed: replayed,
                duplicate: false
            )
        }
    }

    @discardableResult
    public func ingestGap(deviceID: String, generation: String, gap: BacklogGapMessage) throws -> Int64 {
        let now = millisecondsSinceEpoch(clock.now())
        return try pool.write { db in
            let cursor = try Self.requireCurrentCursor(db, deviceID: deviceID, generation: generation)
            if gap.toSequence <= cursor {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT from_seq, to_seq, reason FROM gap_span
                        WHERE device_id = ? AND outbox_gen = ?
                          AND to_seq >= ? AND from_seq <= ?
                        ORDER BY from_seq
                        """,
                    arguments: [deviceID, generation, gap.fromSequence, gap.toSequence]
                )
                var coveredThrough = gap.fromSequence - 1
                for row in rows {
                    let from: Int64 = row["from_seq"]
                    let to: Int64 = row["to_seq"]
                    let reason: String = row["reason"]
                    guard reason == gap.reason, from <= coveredThrough + 1 else { break }
                    coveredThrough = max(coveredThrough, to)
                }
                guard coveredThrough >= gap.toSequence else {
                    throw EkoCoreError.sequenceConflict
                }
                return cursor
            }
            guard gap.fromSequence <= cursor + 1 else {
                throw EkoCoreError.protocolViolation("gap starts after an uncovered sequence")
            }
            let effectiveFrom = max(gap.fromSequence, cursor + 1)
            let overlapsEvent = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM event
                        WHERE device_id = ? AND outbox_gen = ? AND seq BETWEEN ? AND ?
                    )
                    """,
                arguments: [deviceID, generation, effectiveFrom, gap.toSequence]
            ) ?? false
            guard !overlapsEvent else {
                throw EkoCoreError.sequenceConflict
            }
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO gap_span (
                        device_id, outbox_gen, from_seq, to_seq, reason,
                        start_time_ms, end_time_ms, confidence, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'definitive', ?)
                    """,
                arguments: [
                    deviceID, generation, effectiveFrom, gap.toSequence, gap.reason,
                    nil, nil, now,
                ]
            )
            try db.execute(
                sql: "UPDATE device SET processed_through_seq = ?, last_seen_ms = ? WHERE id = ?",
                arguments: [gap.toSequence, now, deviceID]
            )
            return gap.toSequence
        }
    }

    public func reconcileActiveSnapshot(
        deviceID: String,
        generation: String,
        entries: [ActiveEntry],
        stateSequence: Int64
    ) throws -> [String] {
        guard Set(entries.map(\.key)).count == entries.count else {
            throw EkoCoreError.protocolViolation("active snapshot contains duplicate keys")
        }
        let now = millisecondsSinceEpoch(clock.now())
        return try pool.write { db in
            _ = try Self.requireCurrentCursor(db, deviceID: deviceID, generation: generation)
            let activeKeys = Set(entries.map(\.key))
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT notification_key, content_hash, last_state_seq, body_complete, is_active
                    FROM notification
                    WHERE device_id = ? AND outbox_gen = ?
                    """,
                arguments: [deviceID, generation]
            )
            var existing: [String: (hash: String?, sequence: Int64, complete: Bool, active: Bool)] = [:]
            for row in rows {
                let key: String = row["notification_key"]
                let hash: String? = row["content_hash"]
                let sequence: Int64 = row["last_state_seq"]
                let complete: Bool = row["body_complete"]
                let active: Bool = row["is_active"]
                existing[key] = (hash, sequence, complete, active)
                if active, !activeKeys.contains(key), sequence <= stateSequence {
                    try db.execute(
                        sql: """
                            UPDATE notification SET is_active = 0, last_state_seq = ?, received_at_ms = ?
                            WHERE device_id = ? AND outbox_gen = ? AND notification_key = ?
                              AND last_state_seq <= ?
                            """,
                        arguments: [stateSequence, now, deviceID, generation, key, stateSequence]
                    )
                }
            }

            var fetchKeys: [String] = []
            for entry in entries {
                guard entry.stateSequence <= stateSequence else {
                    throw EkoCoreError.protocolViolation("active entry state exceeds snapshot state")
                }
                if let current = existing[entry.key] {
                    if entry.stateSequence < current.sequence { continue }
                    if entry.stateSequence == current.sequence {
                        guard current.active, current.hash == entry.contentHash else {
                            throw EkoCoreError.protocolViolation("active snapshot contradicts equal local state")
                        }
                        if !current.complete { fetchKeys.append(entry.key) }
                        continue
                    }
                    if current.hash == entry.contentHash, current.complete {
                        try db.execute(
                            sql: """
                                UPDATE notification SET last_state_seq = ?, is_active = 1, received_at_ms = ?
                                WHERE device_id = ? AND outbox_gen = ? AND notification_key = ?
                                """,
                            arguments: [entry.stateSequence, now, deviceID, generation, entry.key]
                        )
                    } else {
                        try db.execute(
                            sql: """
                                UPDATE notification SET content_hash = ?, last_state_seq = ?, is_active = 1,
                                    body_complete = 0, received_at_ms = ?
                                WHERE device_id = ? AND outbox_gen = ? AND notification_key = ?
                                """,
                            arguments: [
                                entry.contentHash, entry.stateSequence, now,
                                deviceID, generation, entry.key,
                            ]
                        )
                        fetchKeys.append(entry.key)
                    }
                } else {
                    try db.execute(
                        sql: """
                            INSERT INTO notification (
                                device_id, outbox_gen, notification_key, app_package, app_label,
                                title, body, payload_json, content_hash, last_state_seq,
                                posted_at_ms, received_at_ms, is_active, is_replayed,
                                is_group_summary, search_text, body_complete
                            ) VALUES (?, ?, ?, '', '', NULL, '', ?, ?, ?, NULL, ?, 1, 0, 0, '', 0)
                            """,
                        arguments: [
                            deviceID, generation, entry.key, Data(), entry.contentHash,
                            entry.stateSequence, now,
                        ]
                    )
                    fetchKeys.append(entry.key)
                }
            }
            return fetchKeys
        }
    }

    public func applyFetchEvent(deviceID: String, generation: String, event: EventMessage) throws {
        guard event.sequence == nil, let stateSequence = event.stateSequence,
              event.event == .posted,
              let key = event.key, let app = event.app, let content = event.notification else {
            throw EkoCoreError.protocolViolation("fetch response is not a synthetic notification event")
        }
        let payload = try ProtocolCodec.encode(.event(event))
        let receivedAt = millisecondsSinceEpoch(clock.now())
        let otp = otpExtractor.extract(from: content)
        try pool.write { db in
            _ = try Self.requireCurrentCursor(db, deviceID: deviceID, generation: generation)
            let existing = try Row.fetchOne(
                db,
                sql: """
                    SELECT last_state_seq, content_hash, body_complete, is_active, payload_json FROM notification
                    WHERE device_id = ? AND outbox_gen = ? AND notification_key = ?
                    """,
                arguments: [deviceID, generation, key]
            )
            if let existing {
                let existingState: Int64 = existing["last_state_seq"]
                guard stateSequence >= existingState else { return }
                if stateSequence == existingState {
                    let existingHash: String? = existing["content_hash"]
                    let complete: Bool = existing["body_complete"]
                    let active: Bool = existing["is_active"]
                    guard active, existingHash == event.contentHash else {
                        throw EkoCoreError.protocolViolation("fetch event contradicts equal local state")
                    }
                    if complete {
                        let existingPayload: Data = existing["payload_json"]
                        guard case .event(let existingEvent) = try ProtocolCodec.decode(existingPayload),
                              Self.sameNotificationState(existingEvent, event) else {
                            throw EkoCoreError.protocolViolation("fetch event contradicts complete equal state")
                        }
                        return
                    }
                }
            }
            let body = content.displayBody
            let searchText = [app.label, app.package, content.title, body]
                .compactMap { $0 }
                .joined(separator: " ")
                .normalizedForSearch
            try db.execute(
                sql: """
                    INSERT INTO notification (
                        device_id, outbox_gen, notification_key, app_package, app_label,
                        title, body, payload_json, content_hash, last_state_seq,
                        posted_at_ms, received_at_ms, is_active, is_replayed,
                        is_group_summary, search_text
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?)
                    ON CONFLICT(device_id, outbox_gen, notification_key) DO UPDATE SET
                        app_package = excluded.app_package, app_label = excluded.app_label,
                        title = excluded.title, body = excluded.body,
                        payload_json = excluded.payload_json, content_hash = excluded.content_hash,
                        last_state_seq = excluded.last_state_seq, posted_at_ms = excluded.posted_at_ms,
                        received_at_ms = excluded.received_at_ms, is_active = 1,
                        body_complete = 1, is_replayed = 0, is_group_summary = excluded.is_group_summary,
                        search_text = excluded.search_text
                    WHERE excluded.last_state_seq >= notification.last_state_seq
                    """,
                arguments: [
                    deviceID, generation, key, app.package, app.label, content.title, body,
                    payload, event.contentHash, stateSequence, event.postedAt, receivedAt,
                    content.isGroupSummary, searchText,
                ]
            )
            if let otp {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO otp (
                            device_id, outbox_gen, notification_key, event_seq, code,
                            method, detected_at_ms, banner_eligible
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                        """,
                    arguments: [
                        deviceID, generation, key, stateSequence, otp.code,
                        otp.method.rawValue, receivedAt,
                    ]
                )
            }
        }
    }

    public func applyFetchMissing(deviceID: String, generation: String, message: FetchMissingMessage) throws {
        let now = millisecondsSinceEpoch(clock.now())
        try pool.write { db in
            _ = try Self.requireCurrentCursor(db, deviceID: deviceID, generation: generation)
            guard let existing = try Row.fetchOne(
                db,
                sql: """
                    SELECT last_state_seq, is_active FROM notification
                    WHERE device_id = ? AND outbox_gen = ? AND notification_key = ?
                    """,
                arguments: [deviceID, generation, message.key]
            ) else {
                throw EkoCoreError.protocolViolation("fetch_missing has no requested local state")
            }
            let existingState: Int64 = existing["last_state_seq"]
            let active: Bool = existing["is_active"]
            guard message.stateSequence >= existingState else { return }
            if message.stateSequence == existingState, active {
                throw EkoCoreError.protocolViolation("fetch_missing contradicts equal active state")
            }
            try db.execute(
                sql: """
                    UPDATE notification SET is_active = 0, last_state_seq = ?, received_at_ms = ?
                    WHERE device_id = ? AND outbox_gen = ? AND notification_key = ?
                      AND last_state_seq <= ?
                    """,
                arguments: [message.stateSequence, now, deviceID, generation, message.key, message.stateSequence]
            )
        }
    }

    public func currentOTP(deviceID: String, generation: String?, notificationKey: String) throws -> String? {
        try pool.read { db in
            if let generation {
                return try String.fetchOne(
                    db,
                    sql: """
                        SELECT code FROM otp
                        WHERE device_id = ? AND outbox_gen = ? AND notification_key = ?
                        ORDER BY event_seq DESC, id DESC LIMIT 1
                        """,
                    arguments: [deviceID, generation, notificationKey]
                )
            }
            return try String.fetchOne(
                db,
                sql: """
                    SELECT code FROM otp
                    WHERE device_id = ? AND notification_key = ?
                    ORDER BY detected_at_ms DESC, id DESC LIMIT 1
                    """,
                arguments: [deviceID, notificationKey]
            )
        }
    }

    public func markOTPCopied(deviceID: String, code: String) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    UPDATE otp SET copied_at_ms = ?
                    WHERE id = (
                        SELECT id FROM otp WHERE device_id = ? AND code = ?
                        ORDER BY detected_at_ms DESC, id DESC LIMIT 1
                    )
                    """,
                arguments: [millisecondsSinceEpoch(clock.now()), deviceID, code]
            )
        }
    }

    public func notifications(query: FeedQuery = FeedQuery()) throws -> [CurrentNotification] {
        try pool.read { db in try Self.fetchNotifications(db, query: query) }
    }

    public func observeNotifications(query: FeedQuery = FeedQuery()) -> AsyncThrowingStream<[CurrentNotification], Error> {
        let pool = self.pool
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let observation = ValueObservation.tracking { db in
                        try Self.fetchNotifications(db, query: query)
                    }
                    for try await value in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func observeDevices() -> AsyncThrowingStream<[Device], Error> {
        let pool = self.pool
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let observation = ValueObservation.tracking { db in
                        try Row.fetchAll(db, sql: "SELECT * FROM device ORDER BY name COLLATE NOCASE")
                            .map(Self.decodeDevice)
                    }
                    for try await value in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func gaps(limit: Int = 100) throws -> [GapSpan] {
        let bounded = min(max(limit, 1), 500)
        return try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM gap_span
                    ORDER BY created_at_ms DESC LIMIT ?
                    """,
                arguments: [bounded]
            ).map(Self.decodeGap)
        }
    }

    public func setStarred(deviceID: String, generation: String, key: String, starred: Bool) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    UPDATE notification SET is_starred = ?
                    WHERE device_id = ? AND outbox_gen = ? AND notification_key = ?
                    """,
                arguments: [starred, deviceID, generation, key]
            )
        }
    }

    public func appPreferences() throws -> [AppPreference] {
        try pool.read { db in try Self.fetchAppPreferences(db) }
    }

    public func observeAppPreferences() -> AsyncThrowingStream<[AppPreference], Error> {
        let pool = self.pool
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let observation = ValueObservation.tracking { db in try Self.fetchAppPreferences(db) }
                    for try await value in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func appPreference(deviceID: String, appPackage: String) throws -> AppPreference? {
        try pool.read { db in
            try Self.fetchAppPreferences(db).first {
                $0.deviceID == deviceID && $0.appPackage == appPackage
            }
        }
    }

    public func setAppPreference(
        deviceID: String,
        appPackage: String,
        bannerMode: BannerMode,
        autoCopyOTP: Bool,
        soundEnabled: Bool
    ) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_preference (
                        device_id, app_package, banner_mode, auto_copy_otp, sound_enabled
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(device_id, app_package) DO UPDATE SET
                        banner_mode = excluded.banner_mode,
                        auto_copy_otp = excluded.auto_copy_otp,
                        sound_enabled = excluded.sound_enabled
                    """,
                arguments: [deviceID, appPackage, bannerMode.rawValue, autoCopyOTP, soundEnabled]
            )
        }
    }

    public func savePairingAttempt(_ attempt: PersistedPairingAttempt) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM pairing_attempt WHERE expires_at_ms < ?", arguments: [millisecondsSinceEpoch(clock.now())])
            try db.execute(sql: "DELETE FROM consumed_qr_token WHERE expires_at_ms < ?", arguments: [millisecondsSinceEpoch(clock.now())])
            try Self.upsertPairingAttempt(db, attempt: attempt, expiresAt: attempt.expiresAt)
        }
    }

    /// Consumes a single-use QR token and persists the pairing attempt bound to that
    /// consumption in one transaction. A disconnect or failure before this call cannot
    /// burn the token; once this call commits, a resumed attempt with the same attempt id
    /// is served idempotently while a different attempt using the same token is rejected.
    public func consumeQRTokenAndSaveAttempt(token: String, attempt: PersistedPairingAttempt) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM consumed_qr_token WHERE expires_at_ms < ?", arguments: [millisecondsSinceEpoch(clock.now())])
            if let consumedAttempt = try String.fetchOne(
                db,
                sql: "SELECT attempt_id FROM consumed_qr_token WHERE token = ?",
                arguments: [token]
            ) {
                guard consumedAttempt == attempt.attemptID else {
                    throw EkoCoreError.unauthorized
                }
            } else {
                try db.execute(
                    sql: "INSERT INTO consumed_qr_token(token, attempt_id, expires_at_ms) VALUES (?, ?, ?)",
                    arguments: [token, attempt.attemptID, millisecondsSinceEpoch(attempt.expiresAt)]
                )
            }
            try Self.upsertPairingAttempt(db, attempt: attempt, expiresAt: attempt.expiresAt)
        }
    }

    public func reservePairingEpoch(deviceID: String, certificateDER: Data, epoch: Int64) throws {
        guard EkoCrypto.fingerprint(of: certificateDER) == deviceID else {
            throw EkoCoreError.unauthorized
        }
        try pool.write { db in
            let pendingEpoch = try Int64.fetchOne(
                db,
                sql: "SELECT highest_conn_epoch FROM pairing_peer_epoch WHERE device_id = ?",
                arguments: [deviceID]
            ) ?? 0
            let confirmedEpoch = try Int64.fetchOne(
                db,
                sql: "SELECT highest_conn_epoch FROM device WHERE id = ?",
                arguments: [deviceID]
            ) ?? 0
            guard epoch > max(pendingEpoch, confirmedEpoch) else { throw EkoCoreError.superseded }
            try db.execute(
                sql: """
                    INSERT INTO pairing_peer_epoch(device_id, highest_conn_epoch)
                    VALUES (?, ?)
                    ON CONFLICT(device_id) DO UPDATE SET
                        highest_conn_epoch = excluded.highest_conn_epoch
                    """,
                arguments: [deviceID, epoch]
            )
        }
    }

    public func pairingAttempt(id: String) throws -> PersistedPairingAttempt? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM pairing_attempt WHERE attempt_id = ?",
                arguments: [id]
            ) else { return nil }
            let expiresAt: Int64 = row["expires_at_ms"]
            guard expiresAt > millisecondsSinceEpoch(clock.now()) else {
                throw EkoCoreError.pairingExpired
            }
            return Self.decodePairingAttempt(row)
        }
    }

    public func deletePairingAttempt(id: String) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM pairing_attempt WHERE attempt_id = ?", arguments: [id])
        }
    }

    public func beginUnpair(deviceID: String, message: UnpairMessage, deleteHistory: Bool) throws {
        try pool.write { db in
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM unpair_tombstone WHERE unpair_id = ?",
                arguments: [message.unpairID]
            ) {
                let status: String = existing["status"]
                guard Self.unpairRow(existing, matches: message, deviceID: deviceID),
                      status == "pending" else {
                    throw EkoCoreError.protocolViolation("unpair id was reused with different state")
                }
                return
            }
            let hasPending = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM unpair_tombstone WHERE device_id = ? AND status = 'pending')",
                arguments: [deviceID]
            ) ?? false
            guard !hasPending else {
                throw EkoCoreError.invalidState("device already has a pending unpair action")
            }
            try db.execute(sql: "DELETE FROM pairing_attempt WHERE device_id = ?", arguments: [deviceID])
            if deleteHistory { try Self.deleteNotificationData(db, deviceID: deviceID) }
            if deleteHistory {
                try db.execute(
                    sql: """
                        UPDATE device SET pairing_state = 'revoked_pending', current_generation = NULL,
                            processed_through_seq = 0, initial_cursor = 0, capabilities_json = '[]'
                        WHERE id = ?
                        """,
                    arguments: [deviceID]
                )
            } else {
                try db.execute(
                    sql: "UPDATE device SET pairing_state = 'revoked_pending' WHERE id = ?",
                    arguments: [deviceID]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO unpair_tombstone (
                        unpair_id, device_id, initiator_id, peer_id, reason, status, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, 'pending', ?)
                    """,
                arguments: [
                    message.unpairID, deviceID, message.initiatorID, message.peerID,
                    message.reason.rawValue, millisecondsSinceEpoch(clock.now()),
                ]
            )
        }
    }

    public func applyUnpair(deviceID: String, message: UnpairMessage) throws -> UnpairStatus {
        try pool.write { db in
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM unpair_tombstone WHERE unpair_id = ?",
                arguments: [message.unpairID]
            ) {
                guard Self.unpairRow(existing, matches: message, deviceID: deviceID) else {
                    throw EkoCoreError.protocolViolation("unpair id was reused with different payload")
                }
                let status: String = existing["status"]
                if status == "applied" { return .alreadyApplied }
            }
            try db.execute(sql: "DELETE FROM pairing_attempt WHERE device_id = ?", arguments: [deviceID])
            try Self.deleteNotificationData(db, deviceID: deviceID)
            try db.execute(
                sql: """
                    UPDATE device SET pairing_state = 'revoked_pending', current_generation = NULL,
                        processed_through_seq = 0, initial_cursor = 0, capabilities_json = '[]'
                    WHERE id = ?
                    """,
                arguments: [deviceID]
            )
            try db.execute(
                sql: """
                    INSERT INTO unpair_tombstone (
                        unpair_id, device_id, initiator_id, peer_id, reason, status, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, 'applied', ?)
                    ON CONFLICT(unpair_id) DO UPDATE SET status = 'applied'
                    """,
                arguments: [
                    message.unpairID, deviceID, message.initiatorID, message.peerID,
                    message.reason.rawValue, millisecondsSinceEpoch(clock.now()),
                ]
            )
            return .applied
        }
    }

    public func pendingUnpair(deviceID: String) throws -> UnpairMessage? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM unpair_tombstone
                    WHERE device_id = ? AND status = 'pending'
                    ORDER BY created_at_ms LIMIT 1
                """,
                arguments: [deviceID]
            ) else { return nil }
            let rawReason: String = row["reason"]
            guard let reason = UnpairReason(rawValue: rawReason) else {
                throw EkoCoreError.storage("unpair tombstone has an invalid reason")
            }
            return UnpairMessage(
                unpairID: row["unpair_id"],
                initiatorID: row["initiator_id"],
                peerID: row["peer_id"],
                reason: reason
            )
        }
    }

    public func completeUnpair(deviceID: String) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM pairing_attempt WHERE device_id = ?", arguments: [deviceID])
            try db.execute(sql: "DELETE FROM pairing_peer_epoch WHERE device_id = ?", arguments: [deviceID])
            try db.execute(sql: "DELETE FROM device WHERE id = ?", arguments: [deviceID])
        }
    }

    /// Explicit local "forget without notifying" action: drops the pin, every revocation
    /// receipt (pending or applied), pending pair attempts, and the epoch high-water for
    /// this certificate without any wire exchange. After this call the certificate is
    /// unknown and TLS rejects it unless a new pairing mode admits it again.
    public func forgetWithoutNotifying(deviceID: String) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM pairing_attempt WHERE device_id = ?", arguments: [deviceID])
            try db.execute(sql: "DELETE FROM unpair_tombstone WHERE device_id = ?", arguments: [deviceID])
            try db.execute(sql: "DELETE FROM pairing_peer_epoch WHERE device_id = ?", arguments: [deviceID])
            try db.execute(sql: "DELETE FROM device WHERE id = ?", arguments: [deviceID])
        }
    }

    /// Prunes display history by age and count. Sequence coverage receipts are durable:
    /// for each device's current generation, every position at or below
    /// `processed_through_seq` keeps either its full event row or a stripped receipt row
    /// (payload removed, kind/key/hash retained), and definitive gap spans are never
    /// deleted, so duplicate redelivery stays idempotent and the cursor never loses its
    /// underlying event-or-gap coverage. Rows outside the current generation are display
    /// history and are deleted normally.
    public func prune(retentionDays: Int = 7, maximumNotificationsPerDevice: Int = 5_000) throws {
        let days = min(max(retentionDays, 1), 90)
        let count = min(max(maximumNotificationsPerDevice, 100), 50_000)
        let cutoff = millisecondsSinceEpoch(clock.now()) - Int64(days) * 86_400_000
        try pool.write { db in
            let devices = try Row.fetchAll(
                db,
                sql: "SELECT id, current_generation FROM device"
            )
            for deviceRow in devices {
                let id: String = deviceRow["id"]
                let currentGeneration: String? = deviceRow["current_generation"]
                try db.execute(
                    sql: """
                        DELETE FROM notification
                        WHERE device_id = ? AND is_starred = 0 AND (
                            received_at_ms < ? OR (device_id, outbox_gen, notification_key) NOT IN (
                                SELECT device_id, outbox_gen, notification_key
                                FROM notification
                                WHERE device_id = ?
                                ORDER BY received_at_ms DESC LIMIT ?
                            )
                        )
                        """,
                    arguments: [id, cutoff, id, count]
                )
                if let currentGeneration {
                    try db.execute(
                        sql: """
                            UPDATE event SET payload_json = ?, payload_pruned = 1
                            WHERE device_id = ? AND outbox_gen = ? AND payload_pruned = 0 AND (
                                received_at_ms < ? OR seq NOT IN (
                                    SELECT seq FROM event
                                    WHERE device_id = ? AND outbox_gen = ?
                                    ORDER BY received_at_ms DESC, seq DESC LIMIT ?
                                )
                            )
                            """,
                        arguments: [Data(), id, currentGeneration, cutoff, id, currentGeneration, count * 4]
                    )
                    try db.execute(
                        sql: """
                            DELETE FROM event WHERE device_id = ? AND outbox_gen != ? AND (
                                received_at_ms < ? OR (outbox_gen, seq) NOT IN (
                                    SELECT outbox_gen, seq FROM event
                                    WHERE device_id = ? AND outbox_gen != ?
                                    ORDER BY received_at_ms DESC, seq DESC LIMIT ?
                                )
                            )
                            """,
                        arguments: [id, currentGeneration, cutoff, id, currentGeneration, count * 4]
                    )
                } else {
                    try db.execute(
                        sql: """
                            DELETE FROM event WHERE device_id = ? AND (
                                received_at_ms < ? OR (outbox_gen, seq) NOT IN (
                                    SELECT outbox_gen, seq FROM event
                                    WHERE device_id = ?
                                    ORDER BY received_at_ms DESC, seq DESC LIMIT ?
                                )
                            )
                            """,
                        arguments: [id, cutoff, id, count * 4]
                    )
                }
                try db.execute(
                    sql: """
                        DELETE FROM otp WHERE device_id = ? AND detected_at_ms < ?
                          AND NOT EXISTS (
                              SELECT 1 FROM notification n
                              WHERE n.device_id = otp.device_id
                                AND n.outbox_gen = otp.outbox_gen
                                AND n.notification_key = otp.notification_key
                          )
                        """,
                    arguments: [id, cutoff]
                )
                if let currentGeneration {
                    try db.execute(
                        sql: """
                            DELETE FROM gap_span WHERE device_id = ? AND created_at_ms < ?
                              AND (outbox_gen != ? OR confidence != 'definitive')
                            """,
                        arguments: [id, cutoff, currentGeneration]
                    )
                } else {
                    try db.execute(
                        sql: "DELETE FROM gap_span WHERE device_id = ? AND created_at_ms < ?",
                        arguments: [id, cutoff]
                    )
                }
            }
            try db.execute(
                sql: "DELETE FROM consumed_qr_token WHERE expires_at_ms < ?",
                arguments: [millisecondsSinceEpoch(clock.now())]
            )
        }
    }

    public func diagnostics() throws -> StoreDiagnostics {
        try pool.read { db in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let fileBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return StoreDiagnostics(
                deviceCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM device") ?? 0,
                eventCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0,
                activeNotificationCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notification WHERE is_active = 1") ?? 0,
                gapCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gap_span") ?? 0,
                otpCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM otp") ?? 0,
                databaseBytes: fileBytes
            )
        }
    }

    public func processedThrough(deviceID: String, generation: String) throws -> Int64 {
        try pool.read { db in try Self.requireCurrentCursor(db, deviceID: deviceID, generation: generation) }
    }

    private static func deleteNotificationData(_ db: Database, deviceID: String) throws {
        try db.execute(sql: "DELETE FROM event WHERE device_id = ?", arguments: [deviceID])
        try db.execute(sql: "DELETE FROM gap_span WHERE device_id = ?", arguments: [deviceID])
        try db.execute(sql: "DELETE FROM notification WHERE device_id = ?", arguments: [deviceID])
        try db.execute(sql: "DELETE FROM otp WHERE device_id = ?", arguments: [deviceID])
    }

    private static func upsertPairingAttempt(_ db: Database, attempt: PersistedPairingAttempt, expiresAt: Date) throws {
        try db.execute(
            sql: """
                INSERT INTO pairing_attempt (
                    attempt_id, device_id, device_name, local_device_name, peer_cert_der,
                    local_nonce, local_commitment, peer_commitment, peer_nonce,
                    verification_code, transcript_hash, qr_preauthenticated,
                    local_confirmed, peer_confirmed, highest_conn_epoch, outbox_gen,
                    initial_cursor, expires_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(attempt_id) DO UPDATE SET
                    device_id = excluded.device_id,
                    device_name = excluded.device_name,
                    local_device_name = excluded.local_device_name,
                    peer_cert_der = excluded.peer_cert_der,
                    local_nonce = excluded.local_nonce,
                    local_commitment = excluded.local_commitment,
                    peer_commitment = excluded.peer_commitment,
                    peer_nonce = excluded.peer_nonce,
                    verification_code = excluded.verification_code,
                    transcript_hash = excluded.transcript_hash,
                    qr_preauthenticated = excluded.qr_preauthenticated,
                    local_confirmed = excluded.local_confirmed,
                    peer_confirmed = excluded.peer_confirmed,
                    highest_conn_epoch = MAX(pairing_attempt.highest_conn_epoch, excluded.highest_conn_epoch),
                    outbox_gen = excluded.outbox_gen,
                    initial_cursor = excluded.initial_cursor,
                    expires_at_ms = excluded.expires_at_ms
                """,
            arguments: [
                attempt.attemptID, attempt.deviceID, attempt.deviceName, attempt.localDeviceName,
                attempt.peerCertificateDER,
                attempt.localNonce, attempt.localCommitment, attempt.peerCommitment, attempt.peerNonce,
                attempt.verificationCode, attempt.transcriptHash, attempt.qrPreauthenticated,
                attempt.localConfirmed, attempt.peerConfirmed, attempt.highestConnectionEpoch,
                attempt.outboxGeneration, attempt.initialCursor, millisecondsSinceEpoch(expiresAt),
            ]
        )
    }

    private static func recordPeerEpoch(
        _ db: Database,
        deviceID: String,
        certificateDER: Data,
        epoch: Int64
    ) throws {
        guard EkoCrypto.fingerprint(of: certificateDER) == deviceID else {
            throw EkoCoreError.unauthorized
        }
        try db.execute(
            sql: """
                INSERT INTO pairing_peer_epoch(device_id, highest_conn_epoch)
                VALUES (?, ?)
                ON CONFLICT(device_id) DO UPDATE SET
                    highest_conn_epoch = MAX(pairing_peer_epoch.highest_conn_epoch, excluded.highest_conn_epoch)
                """,
            arguments: [deviceID, epoch]
        )
    }

    private static func unpairRow(_ row: Row, matches message: UnpairMessage, deviceID: String) -> Bool {
        let rowDeviceID: String = row["device_id"]
        let initiatorID: String = row["initiator_id"]
        let peerID: String = row["peer_id"]
        let reason: String = row["reason"]
        return rowDeviceID == deviceID
            && initiatorID == message.initiatorID
            && peerID == message.peerID
            && reason == message.reason.rawValue
    }

    private static func requireCurrentCursor(_ db: Database, deviceID: String, generation: String) throws -> Int64 {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT pairing_state, current_generation, processed_through_seq FROM device WHERE id = ?",
            arguments: [deviceID]
        ) else { throw EkoCoreError.unauthorized }
        let state: String = row["pairing_state"]
        let currentGeneration: String? = row["current_generation"]
        guard state == PairingState.confirmed.rawValue, currentGeneration == generation else {
            throw EkoCoreError.protocolViolation("message is scoped to an inactive generation")
        }
        return row["processed_through_seq"]
    }

    private static func fetchNotifications(_ db: Database, query: FeedQuery) throws -> [CurrentNotification] {
        let boundedLimit = min(max(query.limit, 1), 500)
        var predicates: [String] = []
        var arguments: StatementArguments = []
        let normalizedSearch = String(query.search.prefix(200)).normalizedForSearch
        if !normalizedSearch.isEmpty {
            predicates.append(#"n.search_text LIKE ? ESCAPE '\'"#)
            arguments += ["%\(normalizedSearch.escapedForLike)%"]
        }
        if let deviceID = query.deviceID {
            predicates.append("n.device_id = ?")
            arguments += [deviceID]
        }
        if query.codesOnly {
            predicates.append("o.id IS NOT NULL")
        }
        predicates.append("n.body_complete = 1")
        predicates.append("COALESCE(p.banner_mode, 'normal') != 'muted'")
        let whereClause = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
        arguments += [boundedLimit]
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    n.*, d.name AS device_name,
                    o.code AS otp_code, o.event_seq AS otp_event_seq
                FROM notification n
                JOIN device d ON d.id = n.device_id
                LEFT JOIN app_preference p
                  ON p.device_id = n.device_id AND p.app_package = n.app_package
                LEFT JOIN otp o ON o.id = (
                    SELECT latest.id FROM otp latest
                    WHERE latest.device_id = n.device_id
                      AND latest.outbox_gen = n.outbox_gen
                      AND latest.notification_key = n.notification_key
                    ORDER BY latest.event_seq DESC, latest.id DESC LIMIT 1
                )
                \(whereClause)
                ORDER BY n.received_at_ms DESC
                LIMIT ?
                """,
            arguments: arguments
        )
        return rows.map { row in
            let posted: Int64? = row["posted_at_ms"]
            let received: Int64 = row["received_at_ms"]
            return CurrentNotification(
                deviceID: row["device_id"],
                deviceName: row["device_name"],
                generation: row["outbox_gen"],
                key: row["notification_key"],
                appPackage: row["app_package"],
                appLabel: row["app_label"],
                title: row["title"],
                body: row["body"],
                contentHash: row["content_hash"],
                lastStateSequence: row["last_state_seq"],
                postedAt: posted.map(dateFromMilliseconds),
                receivedAt: dateFromMilliseconds(received),
                isActive: row["is_active"],
                isReplayed: row["is_replayed"],
                isGroupSummary: row["is_group_summary"],
                isStarred: row["is_starred"],
                otpCode: row["otp_code"],
                otpEventSequence: row["otp_event_seq"]
            )
        }
    }

    private static func decodeDevice(_ row: Row) throws -> Device {
        let capabilitiesJSON: String = row["capabilities_json"]
        let capabilities = (try? JSONDecoder().decode([String].self, from: Data(capabilitiesJSON.utf8))) ?? []
        let stateString: String = row["pairing_state"]
        guard let state = PairingState(rawValue: stateString) else {
            throw EkoCoreError.storage("device has an invalid pairing state")
        }
        let lastSeen: Int64? = row["last_seen_ms"]
        return Device(
            id: row["id"],
            name: row["name"],
            pinnedCertificateDER: row["pinned_cert_der"],
            pairingState: state,
            currentGeneration: row["current_generation"],
            processedThroughSequence: row["processed_through_seq"],
            lastIPAddress: row["last_ip"],
            capabilities: capabilities,
            highestProtocolVersion: row["highest_protocol"],
            highestConnectionEpoch: row["highest_conn_epoch"],
            lastSeen: lastSeen.map(dateFromMilliseconds)
        )
    }

    private static func fetchAppPreferences(_ db: Database) throws -> [AppPreference] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                WITH apps AS (
                    SELECT device_id, app_package, MAX(app_label) AS app_label
                    FROM notification WHERE body_complete = 1 GROUP BY device_id, app_package
                )
                SELECT apps.device_id, d.name AS device_name, apps.app_package, apps.app_label,
                       COALESCE(p.banner_mode, 'normal') AS banner_mode,
                       COALESCE(p.auto_copy_otp, 0) AS auto_copy_otp,
                       COALESCE(p.sound_enabled, 0) AS sound_enabled
                FROM apps
                JOIN device d ON d.id = apps.device_id
                LEFT JOIN app_preference p
                  ON p.device_id = apps.device_id AND p.app_package = apps.app_package
                ORDER BY apps.app_label COLLATE NOCASE, d.name COLLATE NOCASE
                """
        )
        return try rows.map { row in
            let rawMode: String = row["banner_mode"]
            guard let mode = BannerMode(rawValue: rawMode) else {
                throw EkoCoreError.storage("app preference has invalid banner mode")
            }
            return AppPreference(
                deviceID: row["device_id"],
                deviceName: row["device_name"],
                appPackage: row["app_package"],
                appLabel: row["app_label"],
                bannerMode: mode,
                autoCopyOTP: row["auto_copy_otp"],
                soundEnabled: row["sound_enabled"]
            )
        }
    }

    private static func decodeGap(_ row: Row) throws -> GapSpan {
        let confidenceString: String = row["confidence"]
        guard let confidence = GapConfidence(rawValue: confidenceString) else {
            throw EkoCoreError.storage("gap has invalid confidence")
        }
        let start: Int64? = row["start_time_ms"]
        let end: Int64? = row["end_time_ms"]
        return GapSpan(
            deviceID: row["device_id"],
            generation: row["outbox_gen"],
            fromSequence: row["from_seq"],
            toSequence: row["to_seq"],
            reason: row["reason"],
            startTime: start.map(dateFromMilliseconds),
            endTime: end.map(dateFromMilliseconds),
            confidence: confidence
        )
    }

    private static func decodePairingAttempt(_ row: Row) -> PersistedPairingAttempt {
        let expiry: Int64 = row["expires_at_ms"]
        return PersistedPairingAttempt(
            attemptID: row["attempt_id"],
            deviceID: row["device_id"],
            deviceName: row["device_name"],
            localDeviceName: row["local_device_name"],
            peerCertificateDER: row["peer_cert_der"],
            localNonce: row["local_nonce"],
            localCommitment: row["local_commitment"],
            peerCommitment: row["peer_commitment"],
            peerNonce: row["peer_nonce"],
            verificationCode: row["verification_code"],
            transcriptHash: row["transcript_hash"],
            qrPreauthenticated: row["qr_preauthenticated"],
            localConfirmed: row["local_confirmed"],
            peerConfirmed: row["peer_confirmed"],
            highestConnectionEpoch: row["highest_conn_epoch"],
            outboxGeneration: row["outbox_gen"],
            initialCursor: row["initial_cursor"],
            expiresAt: dateFromMilliseconds(expiry)
        )
    }

    private static func encodeCapabilities(_ capabilities: [String]) throws -> String {
        let data = try JSONEncoder().encode(capabilities.sorted())
        guard let value = String(data: data, encoding: .utf8) else {
            throw EkoCoreError.invalidData("capabilities are not UTF-8")
        }
        return value
    }

    private static func outcome(
        deviceID: String,
        generation: String,
        sequence: Int64,
        event: EventMessage,
        otp: OTPMatch?,
        otpBannerEligible: Bool,
        replayed: Bool,
        duplicate: Bool
    ) -> IngestOutcome {
        IngestOutcome(
            deviceID: deviceID,
            generation: generation,
            sequence: sequence,
            kind: event.event,
            notificationKey: event.key,
            appPackage: event.app?.package,
            appLabel: event.app?.label,
            title: event.notification?.title,
            body: event.notification?.displayBody,
            otpCode: otp?.code,
            otpBannerEligible: otpBannerEligible,
            replayed: replayed,
            dndSuppressed: event.dnd?.suppressed ?? false,
            duplicate: duplicate
        )
    }

    // Early returns, not one chained && expression: Xcode 16.3's type checker
    // times out on the long chains ("unable to type-check this expression in
    // reasonable time").
    private static func durablyEquivalent(_ lhs: EventMessage, _ rhs: EventMessage) -> Bool {
        if lhs.sequence != rhs.sequence { return false }
        if lhs.stateSequence != rhs.stateSequence { return false }
        if lhs.event != rhs.event { return false }
        if lhs.key != rhs.key { return false }
        if lhs.postedAt != rhs.postedAt { return false }
        if lhs.user != rhs.user { return false }
        if lhs.contentHash != rhs.contentHash { return false }
        if lhs.app != rhs.app { return false }
        if lhs.notification != rhs.notification { return false }
        if lhs.dnd != rhs.dnd { return false }
        if lhs.flags.reconciled != rhs.flags.reconciled { return false }
        if lhs.truncatedFields != rhs.truncatedFields { return false }
        if lhs.removeReason != rhs.removeReason { return false }
        if lhs.confidence != rhs.confidence { return false }
        if lhs.interval != rhs.interval { return false }
        if lhs.evidence != rhs.evidence { return false }
        if lhs.details != rhs.details { return false }
        return true
    }

    private static func sameNotificationState(_ lhs: EventMessage, _ rhs: EventMessage) -> Bool {
        if lhs.key != rhs.key { return false }
        if lhs.postedAt != rhs.postedAt { return false }
        if lhs.user != rhs.user { return false }
        if lhs.contentHash != rhs.contentHash { return false }
        if lhs.app != rhs.app { return false }
        if lhs.notification != rhs.notification { return false }
        if lhs.dnd != rhs.dnd { return false }
        if lhs.truncatedFields != rhs.truncatedFields { return false }
        return true
    }
}
