import Foundation

/// An extra condition laid on top of the letter rule for a single turn.
///
/// A card never changes what is *legal* by default — it changes what is worth
/// points.  Meet it and the move scores several times over; ignore it and the
/// move still scores its one point.  A table that wants the sterner game turns
/// `forcedCards` on, and then a card is a rule like any other.
///
/// Every card is checked for feasibility against the letter in play before it
/// is dealt (see ``CardDeck/deal``), so a card can never be a sentence with no
/// answer.  That check is also what makes the tiers honest: a card only counts
/// as hard if, right now, on this letter, hardly anything satisfies it.
public enum CardRule: Codable, Sendable, Equatable, Hashable {
    case endsInVowel
    case endsInConsonant
    /// Letters only — spaces and punctuation are not counted.
    case lengthAtLeast(Int)
    case lengthAtMost(Int)
    case lengthExactly(Int)
    case contains(String)
    case avoidsLetter(String)
    /// Two of the same letter side by side, as in Ottawa or Mississippi.
    case doubleLetter
    case vowelsAtLeast(Int)
    case sameFirstAndLast
    case wordsAtLeast(Int)
    case singleWord
    case inContinent(String)
    case ofKind([String])
    case languageSpoken(String)
    case northOfEquator
    case southOfEquator
    case fameAtLeast(Int)
    case fameAtMost(Int)

    /// Whether a played surface satisfies this card.
    ///
    /// The letter rules read the name the player actually typed — saying
    /// *Bombay* is saying a six-letter word ending in Y, whatever the atlas
    /// files the place under.  Everything else reads the place itself.
    public func accepts(text: String, place: Place?) -> Bool {
        let letters = Array(Normalize.letters(text))
        guard !letters.isEmpty else { return false }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

        switch self {
        case .endsInVowel:
            return vowels.contains(letters[letters.count - 1])
        case .endsInConsonant:
            return !vowels.contains(letters[letters.count - 1])
        case .lengthAtLeast(let n):
            return letters.count >= n
        case .lengthAtMost(let n):
            return letters.count <= n
        case .lengthExactly(let n):
            return letters.count == n
        case .contains(let s):
            return letters.contains(Character(s))
        case .avoidsLetter(let s):
            return !letters.contains(Character(s))
        case .doubleLetter:
            return zip(letters, letters.dropFirst()).contains { $0 == $1 }
        case .vowelsAtLeast(let n):
            return letters.filter(vowels.contains).count >= n
        case .sameFirstAndLast:
            return letters[0] == letters[letters.count - 1]
        case .wordsAtLeast(let n):
            return CardRule.words(text) >= n
        case .singleWord:
            return CardRule.words(text) == 1
        case .inContinent(let code):
            return place?.continent == code
        case .ofKind(let kinds):
            return kinds.contains(place?.kind ?? "")
        case .languageSpoken(let name):
            return place?.language.contains(name) ?? false
        case .northOfEquator:
            return (place?.latitude ?? 0) > 0
        case .southOfEquator:
            return (place?.latitude ?? 0) < 0
        case .fameAtLeast(let n):
            return (place?.fame ?? 0) >= n
        case .fameAtMost(let n):
            guard let fame = place?.fame else { return false }
            return fame <= n
        }
    }

    private static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "-" }).count
    }

    /// What the player is told to do, in the imperative.
    public var demand: String {
        switch self {
        case .endsInVowel: return "end in a vowel"
        case .endsInConsonant: return "end in a consonant"
        case .lengthAtLeast(let n): return "have \(n) letters or more"
        case .lengthAtMost(let n): return "have \(n) letters or fewer"
        case .lengthExactly(let n): return "have exactly \(n) letters"
        case .contains(let s): return "contain the letter \(s.uppercased())"
        case .avoidsLetter(let s): return "contain no \(s.uppercased()) at all"
        case .doubleLetter: return "have a double letter in it"
        case .vowelsAtLeast(let n): return "have at least \(n) vowels"
        case .sameFirstAndLast: return "start and end with the same letter"
        case .wordsAtLeast(let n): return n == 2 ? "be two or more words" : "be \(n) or more words"
        case .singleWord: return "be a single word"
        case .inContinent(let code):
            return "be in \(Place.continentNames[code] ?? code)"
        case .ofKind(let kinds): return "be \(CardRule.phrase(for: kinds))"
        case .languageSpoken(let name): return "be somewhere \(name) is spoken"
        case .northOfEquator: return "be north of the equator"
        case .southOfEquator: return "be south of the equator"
        case .fameAtLeast: return "be a household name"
        case .fameAtMost: return "be somewhere obscure"
        }
    }

    /// A short badge for the card face.
    public var headline: String {
        switch self {
        case .endsInVowel: return "Vowel ending"
        case .endsInConsonant: return "Consonant ending"
        case .lengthAtLeast(let n): return "\(n)+ letters"
        case .lengthAtMost(let n): return "\(n) letters or fewer"
        case .lengthExactly(let n): return "Exactly \(n)"
        case .contains(let s): return "Must have \(s.uppercased())"
        case .avoidsLetter(let s): return "No \(s.uppercased())"
        case .doubleLetter: return "Double letter"
        case .vowelsAtLeast(let n): return "\(n) vowels"
        case .sameFirstAndLast: return "Bookends"
        case .wordsAtLeast: return "Two words"
        case .singleWord: return "One word"
        case .inContinent(let code): return Place.continentNames[code] ?? code
        case .ofKind(let kinds): return CardRule.phrase(for: kinds).capitalizedFirst
        case .languageSpoken(let name): return name
        case .northOfEquator: return "Northern half"
        case .southOfEquator: return "Southern half"
        case .fameAtLeast: return "Household name"
        case .fameAtMost: return "Deep cut"
        }
    }

    private static func phrase(for kinds: [String]) -> String {
        switch Set(kinds) {
        case ["country"]: return "a country"
        case ["capital"]: return "a capital city"
        case ["city", "capital"]: return "a city or town"
        case ["island"]: return "an island"
        case ["river", "lake", "sea"]: return "a river, lake or sea"
        case ["mountain", "range"]: return "a mountain or a range"
        case ["desert", "region", "continent"]: return "a desert, region or continent"
        default: return "a " + kinds.joined(separator: " or ")
        }
    }
}

/// How much a card is worth, and how scarce it has to be to count as one.
public enum CardTier: String, Codable, Sendable, CaseIterable {
    case easy, medium, hard

    /// Points multiplier for a move that satisfies the card.
    public var multiplier: Int {
        switch self {
        case .easy: return 2
        case .medium: return 3
        case .hard: return 5
        }
    }

    /// Hard cards pay a life as well — that is what makes them worth the risk.
    public var grantsLife: Bool { self == .hard }

    /// Fewest places under the current letter that must satisfy the card.
    /// Below this, the card is a trap rather than a challenge.
    var minimumAnswers: Int {
        switch self {
        case .easy: return 8
        case .medium: return 5
        case .hard: return 3
        }
    }

    /// Most of the letter's places that may satisfy the card.  A card that
    /// nine places in ten already meet is not a card, it is decoration — and a
    /// "hard" one that half the atlas satisfies is a lie about the reward.
    var maximumShare: Double {
        switch self {
        case .easy: return 0.85
        case .medium: return 0.55
        case .hard: return 0.22
        }
    }
}

public struct Card: Codable, Sendable, Equatable {
    public var rule: CardRule
    public var tier: CardTier
    public var headline: String
    public var demand: String
    public var multiplier: Int
    public var grantsLife: Bool
    /// How many unplayed places satisfied this card when it was dealt.  Shown
    /// to the player, because "12 places fit" is the difference between a card
    /// that feels fair and one that feels arbitrary.
    public var answers: Int

    public init(rule: CardRule, tier: CardTier, answers: Int) {
        self.rule = rule
        self.tier = tier
        self.headline = rule.headline
        self.demand = rule.demand
        self.multiplier = tier.multiplier
        self.grantsLife = tier.grantsLife
        self.answers = answers
    }

    public func accepts(text: String, place: Place?) -> Bool {
        rule.accepts(text: text, place: place)
    }
}

/// Builds the pool of possible cards and picks one that actually has answers.
public enum CardDeck {

    /// Every card the game knows how to deal.
    ///
    /// Variety is the whole point: a deck of four rules is a deck you have seen
    /// by the third game.  Feasibility filtering does the quality control, so
    /// this list can afford to be greedy — a template that suits one letter and
    /// no other simply never comes up on the others.
    public static let templates: [(rule: CardRule, tier: CardTier)] = {
        var deck: [(CardRule, CardTier)] = [
            (.endsInVowel, .easy),
            (.endsInConsonant, .easy),
            (.doubleLetter, .medium),
            (.sameFirstAndLast, .hard),
            (.wordsAtLeast(2), .medium),
            (.singleWord, .easy),
            (.northOfEquator, .easy),
            (.southOfEquator, .medium),
            (.fameAtLeast(85), .easy),
            (.fameAtMost(70), .medium),
            (.vowelsAtLeast(3), .easy),
            (.vowelsAtLeast(4), .medium),
            (.vowelsAtLeast(5), .hard),
            (.ofKind(["city", "capital"]), .easy),
            (.ofKind(["country"]), .medium),
            (.ofKind(["capital"]), .medium),
            (.ofKind(["island"]), .hard),
            (.ofKind(["river", "lake", "sea"]), .hard),
            (.ofKind(["mountain", "range"]), .hard),
            (.ofKind(["desert", "region", "continent"]), .hard),
        ]
        for n in 3...5 { deck.append((.lengthAtMost(n), .hard)) }
        for n in 6...7 { deck.append((.lengthAtMost(n), .medium)) }
        for n in 5...6 { deck.append((.lengthAtLeast(n), .easy)) }
        for n in 7...8 { deck.append((.lengthAtLeast(n), .medium)) }
        for n in 9...11 { deck.append((.lengthAtLeast(n), .hard)) }
        for n in 4...6 { deck.append((.lengthExactly(n), .medium)) }
        for n in 7...9 { deck.append((.lengthExactly(n), .hard)) }
        for letter in "aeinorst" { deck.append((.contains(String(letter)), .easy)) }
        for letter in "bcdglmpuvy" { deck.append((.contains(String(letter)), .medium)) }
        for letter in "hjkwz" { deck.append((.contains(String(letter)), .hard)) }
        for letter in "aeiou" { deck.append((.avoidsLetter(String(letter)), .medium)) }
        for code in ["AF", "AS", "EU", "NA", "SA", "OC"] {
            deck.append((.inContinent(code), .medium))
        }
        for language in ["English", "Spanish", "French", "Arabic", "Portuguese",
                         "Russian", "German", "Mandarin", "Italian", "Swahili"] {
            deck.append((.languageSpoken(language), .medium))
        }
        return deck.map { (rule: $0.0, tier: $0.1) }
    }()

    /// Scans at most this many of the letter's places when counting answers.
    /// The count is only there to keep a card honest; reading the whole tail of
    /// a common letter on every turn would cost more than the feature is worth.
    static let scanWidth = 140

    /// Picks a card that the current letter can actually answer.
    ///
    /// `tiers` is the set the table has allowed.  Returns nil when nothing in
    /// the deck fits — a starved letter deserves no extra burden.
    public static func deal(atlas: Atlas, letter: Character, used: Set<Int>,
                            minFame: Int, tiers: Set<CardTier>,
                            rng: inout SeededRNG) -> Card? {
        let places = scanPool(atlas: atlas, letter: letter, used: used, minFame: minFame)
        guard !places.isEmpty else { return nil }

        var order = Array(templates.indices)
        shuffle(&order, rng: &rng)
        for index in order {
            let template = templates[index]
            guard tiers.contains(template.tier) else { continue }
            guard let matches = answerCount(for: template, among: places) else { continue }
            return Card(rule: template.rule, tier: template.tier, answers: matches)
        }
        return nil
    }

    /// Whether ``deal`` could return anything from these tiers, without
    /// consuming randomness — asking would otherwise change the game you were
    /// only enquiring about.  Stops at the first template that fits, so the
    /// usual answer is cheap and only a genuinely starved letter is expensive.
    public static func canDeal(atlas: Atlas, letter: Character, used: Set<Int>,
                               minFame: Int, tiers: Set<CardTier>) -> Bool {
        let places = scanPool(atlas: atlas, letter: letter, used: used, minFame: minFame)
        guard !places.isEmpty else { return false }
        return templates.contains { template in
            tiers.contains(template.tier) && answerCount(for: template, among: places) != nil
        }
    }

    private typealias ScanEntry = (text: String, place: Place?)

    /// The places a card would be judged against.  Empty when the letter is too
    /// thin to carry a card at all.
    private static func scanPool(atlas: Atlas, letter: Character, used: Set<Int>,
                                 minFame: Int) -> [ScanEntry] {
        let pool = atlas.candidates(startingWith: letter, minFame: minFame, excluding: used)
            .prefix(scanWidth)
        guard pool.count >= 6 else { return [] }
        return pool.map { (text: $0.text, place: atlas.place($0.placeID)) }
    }

    /// How many of `places` answer this template, or nil when that count makes
    /// it unfit: too few answers to be fair, or so many it is not its tier.
    private static func answerCount(for template: (rule: CardRule, tier: CardTier),
                                    among places: [ScanEntry]) -> Int? {
        var matches = 0
        for entry in places where template.rule.accepts(text: entry.text, place: entry.place) {
            matches += 1
        }
        guard matches >= template.tier.minimumAnswers,
              Double(matches) <= template.tier.maximumShare * Double(places.count)
        else { return nil }
        return matches
    }

    private static func shuffle(_ items: inout [Int], rng: inout SeededRNG) {
        guard items.count > 1 else { return }
        for i in stride(from: items.count - 1, to: 0, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            items.swapAt(i, j)
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
