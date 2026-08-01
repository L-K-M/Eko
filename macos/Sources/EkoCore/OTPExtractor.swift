import Foundation

public enum OTPExtractionMethod: String, Codable, Sendable {
    case originBound = "origin_bound"
    case keywordHeuristic = "keyword_heuristic"
}

public struct OTPMatch: Codable, Equatable, Sendable {
    public let code: String
    public let method: OTPExtractionMethod

    public init(code: String, method: OTPExtractionMethod) {
        self.code = code
        self.method = method
    }
}

public struct OTPExtractor: Sendable {
    private static let originPattern = try! NSRegularExpression(
        pattern: #"^\s*@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}\s+#([0-9A-Za-z-]{3,10})(?:\s+(?:@|%)(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})?(?:\s+\S+)*\s*$"#,
        options: [.caseInsensitive]
    )
    private static let retrieverHashPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9+/]{11}$"#
    )
    private static let domainPattern = try! NSRegularExpression(
        pattern: #"\b(?:https?://)?(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?:/[^\s]*)?"#,
        options: [.caseInsensitive]
    )
    private static let quotedPattern = try! NSRegularExpression(
        pattern: #"\"[^\"\n]{0,120}\"|“[^”\n]{0,120}”|«[^»\n]{0,120}»"#
    )
    // Horizontal whitespace only: a phone number never spans a line break, but
    // a card tail and the code beneath it do, and \s would splice the two into
    // one nine-digit "number" and delete both.
    private static let phonePattern = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])\+?\d(?:[ \t().-]*\d){8,}(?![0-9A-Za-z])"#
    )
    private static let dateTimePattern = try! NSRegularExpression(
        pattern: #"\b\d{1,2}:\d{2}(?::\d{2})?\b|\b\d{1,2}[./-]\d{1,2}[./-]\d{2,4}\b"#
    )
    private static let postcodePattern = try! NSRegularExpression(
        pattern: #"\b[A-Za-z]{1,2}\d[A-Za-z\d]?\s+\d[A-Za-z]{2}\b"#
    )
    private static let endingPattern = try! NSRegularExpression(
        pattern: #"\b(?:ending|ends?\s+in|endziffer|letzte[nr]?\s+ziffern?|card|karte)\D{0,12}\d{4}\b"#,
        options: [.caseInsensitive]
    )
    // A run of masking glyphs followed by the four surviving digits of an
    // account number: "XXXX 5782", "**** 5782", "xxxx-xxxx-xxxx-5782".
    //
    // Every bound here is the loose one that broke something. Three glyphs
    // minimum, because "**4821**" and "Ваш код: **4821**" are emphasis, not a
    // mask. A non-alphanumeric on the left, so a code merely containing a
    // doubled X ("9XX482") survives. Exactly four digits, because "**482913**"
    // is a six-digit code in asterisks. No dotted form at all: "card ...5782"
    // is already endingPattern's, while "Ваш код...4821" is a code behind an
    // ellipsis. Losing a code outright is worse than leaking a tail that
    // ranking still has to beat, so every doubtful case resolves to leaking.
    // Horizontal whitespace between the glyphs and the digits, for the same
    // reason amounts and phone numbers stop at the line break: an issuer keeps
    // a masked tail on one line, so `\s` here only reached down and deleted the
    // code beneath it ("Visa ****\n4821 ist Ihr Code").
    private static let maskedNumberPattern = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])(?:[Xx]{3,}|[*#•·∙●○]{3,})(?:[- \t–—]*(?:[Xx]{3,}|[*#•·∙●○]{3,}))*[- \t–—]*\d{4}(?![0-9A-Za-z])"#
    )
    // A card or account tail announced by a reference abbreviation, where
    // `\b(?:card|karte)` cannot reach because the noun is a compound:
    // "Mastercard Nr. 5782", "Kontonummer 5782". The abbreviation is required —
    // a bare brand next to four digits is not evidence, since "Barclaycard:
    // 1234", "Amex: 3907" and "Verifieringskod för ditt konto: 4821" all put a
    // real code exactly there. Bare "card"/"karte" tails remain endingPattern's.
    private static let cardContextPattern = try! NSRegularExpression(
        pattern: #"\b(?:\w*(?:card|karte|konto)|visa|maestro|amex|account)\W{0,8}(?:nr|no|nummer|number)\.?\W{0,4}\d{4}\b"#,
        options: [.caseInsensitive]
    )
    private static let orderPattern = try! NSRegularExpression(
        pattern: #"\b(?:order|bestell\w*|tracking|sendung|invoice|rechnung|reference|referenz)(?:\s*(?:number|nummer|nr\.?|id))?\D{0,12}[0-9A-Za-z-]{4,20}\b"#,
        options: [.caseInsensitive]
    )
    // Horizontal whitespace again: an amount ends at its line. Letting \s run on
    // made "CHF 45.00\n682415 ist Ihr Code" one amount and swallowed the code.
    private static let currencyPattern = try! NSRegularExpression(
        pattern: #"(?:\b(?:CHF|EUR|USD)[ \t]*|[$€£][ \t]*)\d[\d'’., \t]*|\d[\d'’., \t]*[ \t]*(?:\b(?:CHF|EUR|USD)\b|[$€£])"#,
        options: [.caseInsensitive]
    )
    private static let ignorePattern = try! NSRegularExpression(
        pattern: #"\b(?:barcode|unicode|encode|decode|versions?code|discount\s*code|promo(?:tional)?\s*code|coupon\s*code|gutschein(?:code)?|rabattcode|product\s*code|source\s*code|code\s*review)\b"#,
        options: [.caseInsensitive]
    )
    private static let keywordPattern = try! NSRegularExpression(
        pattern: #"code|k[oó]d(?:u|e|en)?\b|\b(?:otp|one[ -]?time\s+password|passcode|pin|2fa|(?:m|sms)?tan|einmalkennwort|c[oó]digo|codul|clave|codice|код|пароль|şifre|vahvistuskoodi|mã)\b|验证码|校验码|コード|認証番号|인증번호|קוד|کد|كود|رمز|รหัส|कोड|κωδικ"#,
        options: [.caseInsensitive]
    )
    private static let groupedDigitsPattern = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])(?:[0-9][ -]?){4,8}(?![0-9A-Za-z])"#
    )
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])[0-9A-Za-z-]{4,10}(?![0-9A-Za-z])"#
    )
    private static let bracketTagPattern = try! NSRegularExpression(
        pattern: #"\[#\](?:\[[^\]\n]{1,40}\])?"#,
        options: [.caseInsensitive]
    )

    public init() {}

    public func extract(from content: NotificationContent) -> OTPMatch? {
        guard !content.isGroupSummary else { return nil }

        let fields = extractionFields(content)
        guard !fields.isEmpty else { return nil }
        var text = fields.joined(separator: "\n")
        text = normalizeDigits(text)
        text = stripRetrieverArtifacts(text)

        if let originCode = extractOriginBoundCode(text) {
            return OTPMatch(code: originCode, method: .originBound)
        }

        text = Self.bracketTagPattern.replacingMatches(in: text, with: " ")
        text = String(text.prefix(1_000))
        text = Self.domainPattern.replacingMatches(in: text, with: " ")
        text = Self.quotedPattern.replacingMatches(in: text, with: " ")
        text = Self.phonePattern.replacingMatches(in: text, with: " ")
        text = Self.dateTimePattern.replacingMatches(in: text, with: " ")
        text = Self.postcodePattern.replacingMatches(in: text, with: " ")
        // The mask strip runs last of the three: it leaves the card word behind,
        // and endingPattern spans letters, so stripping "Card **** 8821" first
        // would leave "Card  " sitting `\D{0,12}` away from the code on the next
        // line and endingPattern would then eat the code.
        text = Self.endingPattern.replacingMatches(in: text, with: " ")
        text = Self.cardContextPattern.replacingMatches(in: text, with: " ")
        text = Self.maskedNumberPattern.replacingMatches(in: text, with: " ")
        text = Self.orderPattern.replacingMatches(in: text, with: " ")
        text = Self.currencyPattern.replacingMatches(in: text, with: " ")

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard Self.ignorePattern.firstMatch(in: text, range: fullRange) == nil else { return nil }
        let keywordMatches = Self.keywordPattern.matches(in: text, range: fullRange)
        guard !keywordMatches.isEmpty else { return nil }

        var candidates = Self.groupedDigitsPattern.matches(in: text, range: fullRange)
        candidates.append(contentsOf: Self.tokenPattern.matches(in: text, range: fullRange))

        let ranked = candidates.compactMap { match -> RankedCandidate? in
            guard let range = Range(match.range, in: text) else { return nil }
            let raw = String(text[range])
            guard let code = normalizeCandidate(raw), isPlausibleCode(code) else { return nil }
            guard !keywordMatches.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else {
                return nil
            }

            var bestScore = Int.max
            for keyword in keywordMatches {
                let distance: Int
                let directionPenalty: Int
                if match.range.location >= NSMaxRange(keyword.range) {
                    distance = match.range.location - NSMaxRange(keyword.range)
                    directionPenalty = 0
                } else if keyword.range.location >= NSMaxRange(match.range) {
                    distance = keyword.range.location - NSMaxRange(match.range)
                    directionPenalty = 4
                } else {
                    continue
                }
                guard distance <= 80 else { continue }
                bestScore = min(bestScore, distance + directionPenalty)
            }
            guard bestScore != Int.max else { return nil }
            let numericPreference = code.allSatisfy(\.isNumber) ? 0 : 2
            return RankedCandidate(code: code, score: bestScore + numericPreference, location: match.range.location)
        }

        guard let winner = ranked.sorted(by: {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.location < $1.location
        }).first else { return nil }
        return OTPMatch(code: winner.code, method: .keywordHeuristic)
    }

    private func extractionFields(_ content: NotificationContent) -> [String] {
        var values: [String] = []
        if let text = content.text { values.append(text) }
        if let bigText = content.bigText { values.append(bigText) }
        if let textLines = content.textLines { values.append(contentsOf: textLines) }
        if let messages = content.messages { values.append(contentsOf: messages.map(\.text)) }
        if let subText = content.subText { values.append(subText) }
        if let infoText = content.infoText { values.append(infoText) }
        if let summaryText = content.summaryText { values.append(summaryText) }
        return values.filter { !$0.isEmpty }
    }

    private func stripRetrieverArtifacts(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        while let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if trimmed.isEmpty || Self.retrieverHashPattern.firstMatch(in: trimmed, range: range) != nil {
                lines.removeLast()
            } else {
                break
            }
        }
        return lines.joined(separator: "\n").replacingOccurrences(of: "<#>", with: "")
    }

    private func extractOriginBoundCode(_ text: String) -> String? {
        guard let line = text.components(separatedBy: .newlines)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = Self.originPattern.firstMatch(in: line, range: range),
              match.range.location == 0, match.range.length == range.length,
              let codeRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        let code = String(line[codeRange])
        return isPlausibleOriginCode(code) ? code : nil
    }

    private func isPlausibleOriginCode(_ code: String) -> Bool {
        guard (3...10).contains(code.count),
              code.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            return false
        }
        if code.contains(where: \.isNumber) { return true }
        return code == code.uppercased() && code.contains(where: \.isLetter)
    }

    private func normalizeDigits(_ input: String) -> String {
        String(input.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 0x0660...0x0669:
                return Character(String(scalar.value - 0x0660))
            case 0x06F0...0x06F9:
                return Character(String(scalar.value - 0x06F0))
            default:
                return Character(String(scalar))
            }
        })
    }

    private func normalizeCandidate(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^G-[0-9]{4,8}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            value.removeFirst(2)
        }
        if value.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) {
            value.removeAll(where: { $0 == " " || $0 == "-" })
        }
        return value.isEmpty ? nil : value
    }

    private func isPlausibleCode(_ code: String) -> Bool {
        let digits = code.filter(\.isNumber)
        let letters = code.filter(\.isLetter)
        if letters.isEmpty {
            guard (4...8).contains(digits.count), digits.count == code.count else { return false }
            if digits.count == 4, let year = Int(digits), (1900...2099).contains(year) { return false }
            return true
        }

        guard (4...10).contains(code.count), code.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            return false
        }
        if digits.isEmpty {
            // A single repeated glyph is a mask remnant ("XXXX"), never a code.
            guard Set(code.lowercased()).count > 1 else { return false }
            return code == code.uppercased() && code.contains(where: \.isLetter)
        }
        return true
    }

    private struct RankedCandidate {
        let code: String
        let score: Int
        let location: Int
    }
}

private extension NSRegularExpression {
    func replacingMatches(in string: String, with replacement: String) -> String {
        stringByReplacingMatches(
            in: string,
            range: NSRange(string.startIndex..<string.endIndex, in: string),
            withTemplate: replacement
        )
    }
}
