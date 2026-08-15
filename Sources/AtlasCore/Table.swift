import Foundation

/// A named way to play, so a phone screen can offer one tap instead of seven
/// sliders.  A mode is only a starting `GameConfig`: anything the host sets
/// explicitly afterwards still wins, which is why `apply` never reads the
/// config it is replacing.
public enum TableMode: String, Codable, Sendable, CaseIterable {
    /// Letters and nothing else — the game as it is played in the back of a car.
    case classic
    /// Cards turn up and are worth chasing, but never stop you playing.
    case cards
    /// Every turn carries a rule you must obey to play at all.
    case forced
    /// Short clock that shortens further with every round.
    case blitz
    /// Long clock, three lives, a full deck: a game meant to run.
    case marathon
    /// Short clock, forced cards, one life.  Someone goes out fast.
    case brutal
    /// One life each, and a bet can take it.  The shortest game there is.
    case sudden

    public var title: String {
        switch self {
        case .classic: return "Classic"
        case .cards: return "Cards"
        case .forced: return "Forced cards"
        case .blitz: return "Blitz"
        case .marathon: return "Marathon"
        case .brutal: return "Brutal"
        case .sudden: return "Sudden death"
        }
    }

    public var blurb: String {
        switch self {
        case .classic: return "Just the letters. 30 seconds a turn."
        case .cards: return "Cards appear. Meet one for bonus points."
        case .forced: return "Every turn has a rule you must obey."
        case .blitz: return "15 seconds, and the clock tightens each round."
        case .marathon: return "45 seconds, three lives, the whole deck."
        case .brutal: return "12 seconds, forced cards, one life."
        case .sudden: return "One life each. Bet it on a hard card to win one back."
        }
    }

    public var config: GameConfig {
        var c = GameConfig()
        switch self {
        case .classic:
            c.cardChance = 0
            // No deck at this table, so nothing to bet on either.
            c.allowWager = false
        case .cards:
            c.cardChance = 0.45
        case .forced:
            c.turnSeconds = 35
            c.cardChance = 1
            c.forcedCards = true
            // A forced hard card on a thin letter is a coin flip, not a test of
            // knowledge, so this table deals only from the two kinder tiers.
            c.cardTiers = [.easy, .medium]
        case .blitz:
            c.turnSeconds = 15
            c.turnDecay = 0.5
            c.minimumTurnSeconds = 6
            c.cardChance = 0.3
            c.cardTiers = [.easy, .medium]
        case .marathon:
            c.turnSeconds = 45
            c.lives = 3
            c.cardChance = 0.5
        case .brutal:
            c.turnSeconds = 12
            c.lives = 1
            c.turnDecay = 0.3
            c.minimumTurnSeconds = 5
            c.cardChance = 1
            c.forcedCards = true
        case .sudden:
            // One life is the whole table: every timeout is fatal, and so is
            // every lost bet.  The clock is generous to compensate, and the
            // deck stays on so there is always something to bet against.
            c.turnSeconds = 25
            c.lives = 1
            c.cardChance = 0.45
        }
        return c
    }

    /// Everything the home screen needs to draw the mode picker.
    public static var catalogue: [[String: String]] {
        allCases.map { ["id": $0.rawValue, "title": $0.title, "blurb": $0.blurb] }
    }
}
