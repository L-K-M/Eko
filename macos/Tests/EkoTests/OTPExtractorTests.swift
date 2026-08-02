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
            text: "Visa **** 4821 was charged USD 24.80. No code is needed."
        )))
        XCTAssertNil(extractor.extract(from: NotificationContent(
            text: "Mastercard Nr. 5782 wurde belastet. Kein Code noetig."
        )))
        XCTAssertNil(extractor.extract(from: NotificationContent(
            text: "Account number 5782 was charged. No code needed."
        )))
        XCTAssertNil(extractor.extract(from: NotificationContent(
            text: "Karte mit der Endung 5782 wurde belastet."
        )))
    }

    // A mask run with no tail behind it must not send ICU exponential. Before
    // the repeated group required a separator and was bounded, sixty X's in a
    // body never returned, and NSRegularExpression cannot be interrupted. If
    // that shape comes back this test stops finishing rather than failing,
    // which is the loudest alarm available for a hang.
    func testLongMaskRunDoesNotHangTheEngine() {
        XCTAssertNil(extractor.extract(from: NotificationContent(
            text: "code " + String(repeating: "X", count: 1_000)
        )))
        // Sixty glyphs is past where the pre-fix pattern stopped coming back —
        // forty-eight took 6.6 s and fifty-two never finished — and short enough
        // to leave the code inside the 1 000-character cap. Asserting the code
        // is *found* keeps this about linearity: the previous version asserted
        // nil on a 1 023-character input, which only held because truncation
        // removed the keyword, so raising the cap would have failed it for a
        // reason that has nothing to do with backtracking.
        assertCode(
            "682415",
            in: "Mastercard " + String(repeating: "*", count: 60) + "\nYour code: 682415"
        )
        assertCode("682415", in: "Mastercard **** **** **** 1234\nYour code: 682415")
        assertCode("682415", in: "Mastercard XXXX XXXX XXXX 5782\nYour code: 682415")
    }

    func testMaskRunIsNeverACodeItself() {
        XCTAssertNil(extractor.extract(from: NotificationContent(text: "Code XXXX wurde verwendet")))
    }

    // Neither an amount nor a phone number spans a line break, but a payment
    // notification puts the amount, the card and the code on lines of their
    // own. Letting those two patterns run over the newline spliced the card
    // tail onto the code beneath it and deleted both.
    func testLineAboveTheCodeDoesNotSwallowIt() {
        assertCode("682415", in: "Coop\nCHF 45.00\n682415 is your confirmation code")
        assertCode("682415", in: "Mastercard 5782\n682415 ist Ihr Code")
        assertCode("682415", in: "CHF 118.01\n682415 ist Ihr Code")
        assertCode("7043", in: "Revolut\nCard **** 8821\n7043 is your confirmation code")
        assertCode("4821", in: "Visa ****\n4821 ist Ihr Code zur Freigabe")
        assertCode("1234", in: "XXXX\n1234 is your verification code")
        assertCode("4821", in: "Visa No.\n4821 ist Ihr Code")
        assertCode("4821", in: "Ihre Karte\n4821 ist Ihr Code")
        assertCode("1234", in: "Card ending\n1234 is your code")
        assertCode("4821", in: "Bestellung\n4821 ist Ihr Code")
        assertCode("682415", in: "Rechnung\n682415 ist Ihr Code")
        assertCode("682415", in: "Bestaetigungscode fuer Karte mit der Endung 5782\n682415")
    }

    func testCodeOnItsOwnLineStillWins() {
        assertCode("682415", in: "Your verification code\n682415")
    }

    // A merchant name in capitals is token shaped, so nothing may promote it
    // above the digits the keyword actually introduces.
    func testUppercaseMerchantNameNeverBeatsTheCode() {
        assertCode("682415", in: "CHF 118.01 bei DIGITEC \u{2013} Bestaetigungscode:\n682415")
        assertCode("682415", in: "Zahlung per TWINT wird freigegeben. Bestaetigungscode:\n682415")
        assertCode("483920", in: "483920\nBestaetigungscode fuer Ihre Zahlung an MIGROS.")
    }

    func testMaskLookalikesDoNotEatARealCode() {
        assertCode("482913", in: "Your code is... 482913")
        assertCode("448291", in: "Ihr Code lautet 448291...")
        assertCode("9XX482", in: "Your verification code is 9XX482")
        assertCode("6824", in: "Karte gesperrt. Code Nr. 6824 zur Freigabe.")
        // Emphasis glyphs hug a code in real SMS copy. Two of them are not a
        // mask, and a mask tail is four digits, so neither length is eaten.
        assertCode("482913", in: "**482913** is your verification code")
        assertCode("4821", in: "Doğrulama kodu: **4821**")
        // Three glyphs is bold-italic, and a card tail is never masked from
        // the right, so a closing run marks emphasis rather than a mask.
        assertCode("4821", in: "***4821*** is your verification code")
        assertCode("4821", in: "•••4821••• ist Ihr Code")
        assertCode("482913", in: "XXX 482913 is your verification code")
        assertCode("4821", in: "Ihr Code...4821")
        // A brand next to four digits is not evidence of a card tail: the
        // sender name sits exactly there in real one-time-code messages.
        assertCode("6824", in: "Your Mastercard code is 6824")
        assertCode("1234", in: "Barclaycard: 1234 is your verification code.")
        assertCode("3907", in: "Amex: 3907 is your one-time code.")
        assertCode("4821", in: "Verifieringskod foer ditt konto: 4821")
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
