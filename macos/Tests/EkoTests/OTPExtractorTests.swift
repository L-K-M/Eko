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

    func testMaskedCardTailDoesNotOutrankThePaymentCode() {
        assertCode("682415", in: """
        CHF 118.01
        01.08.2026 / 17:57
        Mastercard XXXX 5782
        Your code for confirming the payment transaction: 682415
        """)
    }

    func testMaskedCardTailIsIgnoredInEveryMaskingStyle() {
        assertCode("682415", in: "Mastercard **** 5782\nCode for the payment: 682415")
        assertCode("682415", in: "Visa •••• 5782 - your verification code is 682415")
        assertCode("682415", in: "Karte xxxx-xxxx-xxxx-5782\nIhr Code lautet 682415")
        assertCode("682415", in: "Payment with card ...5782. Code 682415")
    }

    func testCardTailWithoutACodeStaysUnmatched() {
        XCTAssertNil(extractor.extract(from: NotificationContent(
            text: "Mastercard XXXX 5782 wurde belastet. Kein Code noetig."
        )))
        XCTAssertNil(extractor.extract(from: NotificationContent(
            text: "Zahlung mit Kreditkarte 5782 bestaetigt. Kein Code noetig."
        )))
        XCTAssertNil(extractor.extract(from: NotificationContent(
            text: "Visa **** 4821 was charged USD 24.80. No code is needed."
        )))
        XCTAssertNil(extractor.extract(from: NotificationContent(
            text: "Mastercard Nr. 5782 wurde belastet. Kein Code noetig."
        )))
        XCTAssertNil(extractor.extract(from: NotificationContent(
            text: "Account number 5782 was charged. No code needed."
        )))
    }

    func testMaskRunIsNeverACodeItself() {
        XCTAssertNil(extractor.extract(from: NotificationContent(text: "Code XXXX wurde verwendet")))
    }

    func testKeywordPrefersTheNumberOnItsOwnLine() {
        assertCode("682415", in: "Terminal 4821\nYour code for confirming the payment transaction: 682415")
        assertCode("682415", in: "Coop Pronto\nCHF 24.80\nTerminal 4821\nIhr Code zur Freigabe der Zahlung lautet: 682415")
    }

    func testCodeOnItsOwnLineStillWinsWhenNothingSharesTheKeywordLine() {
        assertCode("682415", in: "Your verification code\n682415")
    }

    func testMaskLookalikesDoNotEatARealCode() {
        assertCode("482913", in: "Your code is... 482913")
        assertCode("448291", in: "Ihr Code lautet 448291...")
        assertCode("9XX482", in: "Your verification code is 9XX482")
        assertCode("6824", in: "Your Mastercard code is 6824")
        assertCode("6824", in: "Karte gesperrt. Code Nr. 6824 zur Freigabe.")
        // Emphasis glyphs hug the code in real SMS copy; only a four-digit
        // tail is a card tail, so a six-digit code inside asterisks survives.
        assertCode("482913", in: "**482913** is your verification code")
        assertCode("482913", in: "XXX 482913 is your verification code")
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
