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
    private static let phonePattern = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])\+?\d(?:[\s().-]*\d){8,}(?![0-9A-Za-z])"#
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
    // A run of masking glyphs followed by the surviving digits of an account
    // number: "XXXX 5782", "**** 5782", "xxxx-xxxx-xxxx-5782", "...5782".
    // Letter masks need three glyphs and a non-alphanumeric on the left so a
    // real alphanumeric code can never be swallowed; a dotted mask must abut
    // its digits so "your code is... 482913" survives.
    private static let maskedNumberPattern = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])(?:(?:[Xx]{3,}|[*#•·∙●○]{2,})(?:[-\s–—]*(?:[Xx]{3,}|[*#•·∙●○]{2,}))*[-\s–—]*\d{2,8}|(?:\.{3,}|…)\d{2,8})(?![0-9A-Za-z])"#
    )
    // The last four digits of a card or account announced by a brand or by a
    // compound noun that ends in card/karte/konto — "Mastercard 5782",
    // "Kreditkarte 5782", "Visa 5782". Unlike endingPattern this allows no
    // word characters before the digits, so "Mastercard code is 6824" keeps
    // its code.
    private static let cardContextPattern = try! NSRegularExpression(
        pattern: #"\b(?:\w*(?:card|karte|konto)|visa|maestro|amex|account)\W{0,8}\d{4}\b"#,
        options: [.caseInsensitive]
    )
    private static let orderPattern = try! NSRegularExpression(
        pattern: #"\b(?:order|bestell\w*|tracking|sendung|invoice|rechnung|reference|referenz)(?:\s*(?:number|nummer|nr\.?|id))?\D{0,12}[0-9A-Za-z-]{4,20}\b"#,
        options: [.caseInsensitive]
    )
    private static let currencyPattern = try! NSRegularExpression(
        pattern: #"(?:\b(?:CHF|EUR|USD)\s*|[$€£]\s*)\d[\d'’.,\s]*|\d[\d'’.,\s]*\s*(?:\b(?:CHF|EUR|USD)\b|[$€£])"#,
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
        text = Self.maskedNumberPattern.replacingMatches(in: text, with: " ")
        text = Self.endingPattern.replacingMatches(in: text, with: " ")
        text = Self.cardContextPattern.replacingMatches(in: text, with: " ")
        text = Self.orderPattern.replacingMatches(in: text, with: " ")
        text = Self.currencyPattern.replacingMatches(in: text, with: " ")

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard Self.ignorePattern.firstMatch(in: text, range: fullRange) == nil else { return nil }
        let keywordMatches = Self.keywordPattern.matches(in: text, range: fullRange)
        guard !keywordMatches.isEmpty else { return nil }

        var candidates = Self.groupedDigitsPattern.matches(in: text, range: fullRange)
        candidates.append(contentsOf: Self.tokenPattern.matches(in: text, range: fullRange))
        let newlinesBefore = newlinePrefixSums(text)

        let ranked = candidates.compactMap { match -> RankedCandidate? in
            guard let range = Range(match.range, in: text) else { return nil }
            let raw = String(text[range])
            guard let code = normalizeCandidate(raw), isPlausibleCode(code) else { return nil }
            guard !keywordMatches.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else {
                return nil
            }

            var bestLineDistance = Int.max
            var bestScore = Int.max
            for keyword in keywordMatches {
                let gapStart: Int
                let gapEnd: Int
                let directionPenalty: Int
                if match.range.location >= NSMaxRange(keyword.range) {
                    gapStart = NSMaxRange(keyword.range)
                    gapEnd = match.range.location
                    directionPenalty = 0
                } else if keyword.range.location >= NSMaxRange(match.range) {
                    gapStart = NSMaxRange(match.range)
                    gapEnd = keyword.range.location
                    directionPenalty = 4
                } else {
                    continue
                }
                let distance = gapEnd - gapStart
                guard distance <= 80 else { continue }
                // A notification body is line structured: a keyword binds to a
                // number on its own line before it binds to a nearer number
                // that a line break separates from it.
                let lineDistance = newlinesBefore[gapEnd] - newlinesBefore[gapStart]
                let score = distance + directionPenalty
                if lineDistance < bestLineDistance || (lineDistance == bestLineDistance && score < bestScore) {
                    bestLineDistance = lineDistance
                    bestScore = score
                }
            }
            guard bestScore != Int.max else { return nil }
            let numericPreference = code.allSatisfy(\.isNumber) ? 0 : 2
            return RankedCandidate(
                code: code,
                lineDistance: bestLineDistance,
                score: bestScore + numericPreference,
                location: match.range.location
            )
        }

        guard let winner = ranked.sorted(by: {
            if $0.lineDistance != $1.lineDistance { return $0.lineDistance < $1.lineDistance }
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

    /// Newlines preceding each UTF-16 offset, so the gap between two matches
    /// can be measured in line breaks in constant time.
    private func newlinePrefixSums(_ text: String) -> [Int] {
        var sums = [Int](repeating: 0, count: text.utf16.count + 1)
        var running = 0
        for (offset, unit) in text.utf16.enumerated() {
            sums[offset] = running
            if unit == 0x000A { running += 1 }
        }
        sums[text.utf16.count] = running
        return sums
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
        let lineDistance: Int
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
