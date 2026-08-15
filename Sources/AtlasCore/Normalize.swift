import Foundation

/// Text handling shared by the atlas index, the rules engine and the verifier.
///
/// Two different reductions are needed and they must not be confused:
///
/// * ``Normalize/key(_:)`` collapses a name to a lookup key.  Punctuation and
///   spacing disappear, so `"St. Louis"`, `"St Louis"` and `"saint louis"` all
///   land on the same entry.
/// * ``Normalize/letters(_:)`` keeps only the alphabetic run, which is what the
///   chain rule reads.  `"São Paulo"` starts with `s` and ends with `o`;
///   `"Washington, D.C."` ends with `c`.
public enum Normalize {

    /// Characters that Unicode canonical decomposition will not split apart.
    private static let hardFolds: [Character: String] = [
        "ø": "o", "Ø": "O", "đ": "d", "Đ": "D", "ł": "l", "Ł": "L",
        "ß": "ss", "æ": "ae", "Æ": "Ae", "œ": "oe", "Œ": "Oe",
        "ð": "d", "Ð": "D", "þ": "th", "Þ": "Th", "ı": "i", "İ": "I",
    ]

    /// Lowercased, accent-free ASCII-ish rendering of `s`.
    public static func fold(_ s: String) -> String {
        var pre = ""
        pre.reserveCapacity(s.count)
        for ch in s {
            if let rep = hardFolds[ch] { pre += rep } else { pre.append(ch) }
        }
        return pre.folding(options: [.diacriticInsensitive, .caseInsensitive],
                           locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Lookup key: folded, with everything but letters and digits removed.
    public static func key(_ s: String) -> String {
        String(fold(s).unicodeScalars.filter {
            ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57)
        }.map(Character.init))
    }

    /// The alphabetic run used by the chain rule.
    public static func letters(_ s: String) -> String {
        String(fold(s).unicodeScalars.filter { $0.value >= 97 && $0.value <= 122 }
            .map(Character.init))
    }

    public static func firstLetter(_ s: String) -> Character? { letters(s).first }
    public static func lastLetter(_ s: String) -> Character? { letters(s).last }

    /// Collapses runs of whitespace and trims, preserving the player's casing.
    public static func tidy(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Title-cases a name typed in all-lower or all-upper, leaving mixed-case
    /// input (`"McAllen"`, `"da Nang"`) untouched.
    public static func displayCase(_ s: String) -> String {
        let t = tidy(s)
        guard !t.isEmpty else { return t }
        let alpha = t.filter { $0.isLetter }
        let uniform = alpha.allSatisfy { $0.isLowercase } || alpha.allSatisfy { $0.isUppercase }
        guard uniform else { return t }
        return t.split(separator: " ").map { word -> String in
            guard let f = word.first else { return String(word) }
            return String(f).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
