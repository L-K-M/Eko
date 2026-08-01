import XCTest
@testable import EkoCore

final class OTPExtractorTests: XCTestCase {
    private let extractor = OTPExtractor()

    func testOriginBoundCodeWinsDeterministically() {
        assertCode("123456", in: "Use 999999 if asked\n@example.com #123456", method: .originBound)
    }

    func testOriginBoundEmbeddedDomainVariants() {
        assertCode("AB12", in: "Sign in\n@example.com #AB12 @login.example.com", method: .originBound)
        assertCode("778899", in: "Sign in\n@example.com #778899 %login.example.com", method: .originBound)
    }

    func testGermanCompoundAndGroupedDigits() {
        assertCode("448291", in: "Ihr Bestätigungscode lautet 448 291")
    }

    func testCodeBeforeKeyword() {
        assertCode("482931", in: "482931 ist Ihr Sicherheitscode")
    }

    func testArabicIndicDigitsAreNormalized() {
        assertCode("123456", in: "رمز التحقق code ١٢٣٤٥٦")
    }

    func testPersianDigitsAreNormalized() {
        assertCode("9876", in: "OTP ۹۸۷۶")
    }

    func testUppercaseAlphabeticCode() {
        assertCode("QGFDAE", in: "Your TeamViewer code is QGFDAE")
    }

    func testGooglePrefixIsRemoved() {
        assertCode("123456", in: "G-123456 is your Google verification code")
    }

    func testSMSRetrieverHashNeverWins() {
        assertCode("654321", in: "<#> Your verification code is 654321\nFA+9qCX9VSu")
    }

    func testTitleIsNotInput() {
        let content = NotificationContent(title: "Verification code 123456", text: "Hello")
        XCTAssertNil(extractor.extract(from: content))
    }

    func testGroupSummaryIsExcluded() {
        let content = NotificationContent(text: "Verification code 123456", isGroupSummary: true)
        XCTAssertNil(extractor.extract(from: content))
    }

    func testCurrencyIsNotAResult() {
        XCTAssertNil(extractor.extract(from: NotificationContent(text: "Your purchase code costs CHF 1'234.50")))
    }

    func testPromoCodeIsIgnored() {
        XCTAssertNil(extractor.extract(from: NotificationContent(text: "Your promo code is SAVE20")))
    }

    func testCardLastFourIsIgnored() {
        XCTAssertNil(extractor.extract(from: NotificationContent(text: "Code for card ending 1234")))
    }

    func testFourDigitYearIsIgnored() {
        XCTAssertNil(extractor.extract(from: NotificationContent(text: "Your tax code for 2026")))
    }

    func testPINIsNotFoundInsideOrdinaryWord() {
        XCTAssertNil(extractor.extract(from: NotificationContent(text: "Shipping ETA 4829")))
    }

    // Regression: the domain sub-patterns used to nest quantifiers
    // (`(?:seg\.)+tld`), which a backtracking engine evaluates in 2^(dot count)
    // paths when the overall match fails. Notification text is wire data, so a
    // dotted line was a remote hang of the ingest actor. These inputs are
    // pathological enough that the old patterns would never finish; with the
    // unrolled patterns they complete in microseconds. The generous time budget
    // only guards against accidental reintroduction of super-linear matching.
    func testOriginBoundDottedLineDoesNotHang() {
        let dots = String(repeating: "a.", count: 2_000)
        let content = NotificationContent(bigText: "intro\n@\(dots)")
        let start = ContinuousClock.now
        XCTAssertNil(extractor.extract(from: content))
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(10))
    }

    func testDomainScrubbingDottedTextDoesNotHang() {
        let dots = String(repeating: "a.", count: 400)
        let content = NotificationContent(text: "code 123456 visit \(dots)")
        let start = ContinuousClock.now
        _ = extractor.extract(from: content)
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(10))
    }

    private func assertCode(
        _ expected: String,
        in text: String,
        method: OTPExtractionMethod = .keywordHeuristic,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            extractor.extract(from: NotificationContent(text: text)),
            OTPMatch(code: expected, method: method),
            file: file,
            line: line
        )
    }
}
