import XCTest
import Yams
@testable import EkoCore

final class OTPCorpusTests: XCTestCase {
    private static let corpusFiles = [
        "standards",
        "english",
        "false-positives",
        "german-swiss",
        "multilingual",
    ]
    private static let corpusFormat = "eko-otp-corpus-v1"
    private static let dedupeWindowMilliseconds: Int64 = 10 * 60 * 1_000

    private let extractor = OTPExtractor()

    func testSharedCorpusMatchesExpectations() throws {
        var totalCases = 0
        var totalEvents = 0
        for name in Self.corpusFiles {
            let url = otpCorpusURL("\(name).yaml")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "missing corpus file \(name).yaml at \(url.path)"
            )
            let yaml = try String(contentsOf: url, encoding: .utf8)
            let corpus = try YAMLDecoder().decode(OTPCorpusFile.self, from: yaml)
            XCTAssertEqual(corpus.format, Self.corpusFormat, "unexpected format in \(name).yaml")
            XCTAssertFalse(corpus.cases.isEmpty, "no cases decoded from \(name).yaml")
            for corpusCase in corpus.cases {
                totalCases += 1
                totalEvents += runCase(corpusCase, file: name, defaults: corpus.defaults)
            }
        }
        XCTAssertGreaterThan(totalCases, 0)
        XCTAssertGreaterThan(totalEvents, 0)
    }

    @discardableResult
    private func runCase(_ corpusCase: OTPCorpusCase, file: String, defaults: OTPCorpusDefaults?) -> Int {
        let deviceID = corpusCase.deviceID ?? corpusCase.id
        let source = corpusCase.source ?? defaults?.source ?? "sms"
        var lastBannerAt: [String: Int64] = [:]
        for (index, event) in corpusCase.events.enumerated() {
            let context = "\(file)/\(corpusCase.id) (\(deviceID)/\(source)) event \(index)"
            let content = NotificationContent(
                title: event.title,
                text: event.text,
                bigText: event.bigText,
                subText: event.subText,
                infoText: event.infoText,
                summaryText: event.summaryText,
                textLines: event.textLines ?? [],
                messages: (event.messages ?? []).map {
                    NotificationMessageLine(sender: $0.sender, text: $0.text, timestamp: $0.ts)
                },
                isGroupSummary: event.isGroupSummary ?? defaults?.isGroupSummary ?? false
            )
            let match = extractor.extract(from: content)
            let atMs = event.atMs ?? Int64(index * 1_000)

            let actualTier: String
            switch match?.method {
            case .originBound: actualTier = "origin_bound"
            case .keywordHeuristic: actualTier = "heuristic"
            case nil: actualTier = "none"
            }

            var banner = false
            if let code = match?.code {
                let dedupeKey = "\(deviceID)\u{0}\(code)"
                if let last = lastBannerAt[dedupeKey], atMs - last < Self.dedupeWindowMilliseconds {
                    banner = false
                } else {
                    banner = true
                    lastBannerAt[dedupeKey] = atMs
                }
            }
            let panel = match != nil
            let autoCopyAllowed = match != nil && !NotificationCoordinator.isBankingStyle(content.displayBody)

            XCTAssertEqual(match?.code, event.expected.code, "code: \(context)")
            XCTAssertEqual(actualTier, event.expected.tier, "tier: \(context)")
            XCTAssertEqual(banner, event.expected.banner, "banner: \(context)")
            XCTAssertEqual(panel, event.expected.panel, "panel: \(context)")
            XCTAssertEqual(autoCopyAllowed, event.expected.autoCopyAllowed, "auto_copy_allowed: \(context)")
        }
        return corpusCase.events.count
    }
}

private struct OTPCorpusFile: Decodable {
    let format: String
    let defaults: OTPCorpusDefaults?
    let cases: [OTPCorpusCase]
}

private struct OTPCorpusDefaults: Decodable {
    let source: String?
    let isGroupSummary: Bool?

    enum CodingKeys: String, CodingKey {
        case source
        case isGroupSummary = "is_group_summary"
    }
}

private struct OTPCorpusCase: Decodable {
    let id: String
    let source: String?
    let deviceID: String?
    let events: [OTPCorpusEvent]

    enum CodingKeys: String, CodingKey {
        case id, source, events
        case deviceID = "device_id"
    }
}

private struct OTPCorpusEvent: Decodable {
    let atMs: Int64?
    let notificationKey: String?
    let title: String?
    let text: String?
    let bigText: String?
    let subText: String?
    let infoText: String?
    let summaryText: String?
    let textLines: [String]?
    let messages: [OTPCorpusMessage]?
    let isGroupSummary: Bool?
    let expected: OTPCorpusExpectation

    enum CodingKeys: String, CodingKey {
        case title, text, messages, expected
        case atMs = "at_ms"
        case notificationKey = "notification_key"
        case bigText = "big_text"
        case subText = "sub_text"
        case infoText = "info_text"
        case summaryText = "summary_text"
        case textLines = "text_lines"
        case isGroupSummary = "is_group_summary"
    }
}

private struct OTPCorpusMessage: Decodable {
    let sender: String?
    let text: String
    let ts: Int64?
}

private struct OTPCorpusExpectation: Decodable {
    let code: String?
    let tier: String
    let banner: Bool
    let panel: Bool
    let autoCopyAllowed: Bool

    enum CodingKeys: String, CodingKey {
        case code, tier, banner, panel
        case autoCopyAllowed = "auto_copy_allowed"
    }
}
