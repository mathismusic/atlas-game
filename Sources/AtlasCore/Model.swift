import Foundation

public enum GamePhase: String, Codable, Sendable {
    case lobby, playing, finished
}

public enum BotDifficulty: String, Codable, Sendable, CaseIterable {
    /// Countries and world capitals only, plays fast and never sets traps.
    case easy
    /// Adds well-known cities; occasionally steers toward awkward letters.
    case medium
    /// The whole atlas, and deliberately hands you the thinnest letter it can.
    case hard

    /// Lowest fame this bot will play.
    ///
    /// The easy tier used to stop at 88, which sounds reasonable until you hand
    /// it a Y: above 88 there is Yemen and the Yangtze and nothing else, so an
    /// easy bot lost the game on move two to anyone who said "Germany".  At 80
    /// it also knows York, Yosemite and Yellowstone — still household names,
    /// and it is the blunder rate, not ignorance, that keeps it beatable.
    var minFame: Int {
        switch self {
        case .easy: return 80
        case .medium: return 74
        case .hard: return 0
        }
    }

    /// How often it plays the letter-starving move rather than a random legal one.
    var strategyRate: Double {
        switch self {
        case .easy: return 0.0
        case .medium: return 0.35
        case .hard: return 0.9
        }
    }

    /// Seconds spent "thinking".
    var thinkRange: ClosedRange<Double> {
        switch self {
        case .easy: return 2.0...5.0
        case .medium: return 1.5...4.0
        case .hard: return 0.8...3.0
        }
    }

    /// Chance of failing to find a move even when one exists — keeps easy bots beatable.
    var blunderRate: Double {
        switch self {
        case .easy: return 0.10
        case .medium: return 0.04
        case .hard: return 0.0
        }
    }

    /// Chance of going out of its way to meet a card that is only worth points.
    ///
    /// An easy bot mostly plays the first thing it thinks of and lets the bonus
    /// go, which is exactly how it loses on points to someone paying attention.
    var cardRate: Double {
        switch self {
        case .easy: return 0.25
        case .medium: return 0.6
        case .hard: return 0.95
        }
    }

    /// Chance of digging below `minFame` when the famous tier has run dry.
    ///
    /// X, Q, O, Y and Z barely exist among famous places, so a bot held to its
    /// tier would concede on those letters every single time — which reads as
    /// broken rather than as easy.  A real player faced with X racks their
    /// brain and sometimes produces Xi'an.
    var recallRate: Double {
        switch self {
        case .easy: return 0.5
        case .medium: return 0.8
        case .hard: return 1.0
        }
    }
}

public struct Player: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var isBot: Bool
    public var difficulty: BotDifficulty?
    public var lives: Int
    public var eliminated: Bool
    /// Set when a human player's browser has gone quiet; used only for display.
    public var connected: Bool
    /// One point a place, more when a card is met.  Survives elimination, so a
    /// player knocked out early still has a score to show for the places they
    /// did find.
    public var score: Int
    public var placesPlayed: Int
    /// Cards met, for the end-of-game summary.
    public var cardsMet: Int

    public init(id: String, name: String, isBot: Bool = false,
                difficulty: BotDifficulty? = nil, lives: Int = 2) {
        self.id = id
        self.name = name
        self.isBot = isBot
        self.difficulty = difficulty
        self.lives = lives
        self.eliminated = false
        self.connected = true
        self.score = 0
        self.placesPlayed = 0
        self.cardsMet = 0
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isBot = try c.decodeIfPresent(Bool.self, forKey: .isBot) ?? false
        difficulty = try c.decodeIfPresent(BotDifficulty.self, forKey: .difficulty)
        lives = try c.decodeIfPresent(Int.self, forKey: .lives) ?? 2
        eliminated = try c.decodeIfPresent(Bool.self, forKey: .eliminated) ?? false
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? true
        score = try c.decodeIfPresent(Int.self, forKey: .score) ?? 0
        placesPlayed = try c.decodeIfPresent(Int.self, forKey: .placesPlayed) ?? 0
        cardsMet = try c.decodeIfPresent(Int.self, forKey: .cardsMet) ?? 0
    }
}

public struct GameConfig: Codable, Sendable {
    public var turnSeconds: Double
    public var lives: Int
    /// Letter the first player must use.  `nil` picks one at random on start.
    public var startLetter: String?
    /// Places below this fame are rejected.  0 accepts the whole atlas.
    public var minFame: Int
    public var allowChallenge: Bool
    /// Cap on successful+failed challenges per player per game.  0 — the
    /// default — is no cap: the atlas being wrong is not the player's fault,
    /// and rationing the fix only teaches people to stop reporting it.
    public var challengesPerPlayer: Int

    // --- table modes -----------------------------------------------------

    /// Chance a turn is dealt a card.  0 turns the deck off entirely.
    public var cardChance: Double
    /// When true a dealt card is a rule, not an opportunity: a place that does
    /// not meet it is refused, exactly as if it started with the wrong letter.
    public var forcedCards: Bool
    /// Tiers the deck may deal from.  Dropping `hard` keeps the game gentle;
    /// keeping only `hard` is a punishing table.
    public var cardTiers: Set<CardTier>
    /// If the letter in play has no unplayed answer left anywhere in the atlas,
    /// hand the turn back rather than punishing a player for the impossible.
    public var deadLetterRescue: Bool
    /// Whether a player may bet a life on a hard card of their own summoning.
    /// Off at a table with no deck, where there would be nothing to bet on.
    public var allowWager: Bool
    /// Seconds shaved off the clock after every full round.  A blitz table sets
    /// this and the game tightens as the easy places run out.
    public var turnDecay: Double
    /// The clock never falls below this, however long the game runs.
    public var minimumTurnSeconds: Double

    public init(turnSeconds: Double = 30, lives: Int = 2, startLetter: String? = nil,
                minFame: Int = 0, allowChallenge: Bool = true,
                challengesPerPlayer: Int = 0, cardChance: Double = 0.4,
                forcedCards: Bool = false,
                cardTiers: Set<CardTier> = Set(CardTier.allCases),
                deadLetterRescue: Bool = true, allowWager: Bool = true,
                turnDecay: Double = 0, minimumTurnSeconds: Double = 5) {
        self.turnSeconds = turnSeconds
        self.lives = lives
        self.startLetter = startLetter
        self.minFame = minFame
        self.allowChallenge = allowChallenge
        self.challengesPerPlayer = challengesPerPlayer
        self.cardChance = cardChance
        self.forcedCards = forcedCards
        self.cardTiers = cardTiers
        self.deadLetterRescue = deadLetterRescue
        self.allowWager = allowWager
        self.turnDecay = turnDecay
        self.minimumTurnSeconds = minimumTurnSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        turnSeconds = try c.decodeIfPresent(Double.self, forKey: .turnSeconds) ?? 30
        lives = try c.decodeIfPresent(Int.self, forKey: .lives) ?? 2
        startLetter = try c.decodeIfPresent(String.self, forKey: .startLetter)
        minFame = try c.decodeIfPresent(Int.self, forKey: .minFame) ?? 0
        allowChallenge = try c.decodeIfPresent(Bool.self, forKey: .allowChallenge) ?? true
        challengesPerPlayer = try c.decodeIfPresent(Int.self, forKey: .challengesPerPlayer) ?? 0
        cardChance = try c.decodeIfPresent(Double.self, forKey: .cardChance) ?? 0.4
        forcedCards = try c.decodeIfPresent(Bool.self, forKey: .forcedCards) ?? false
        cardTiers = try c.decodeIfPresent(Set<CardTier>.self, forKey: .cardTiers)
            ?? Set(CardTier.allCases)
        deadLetterRescue = try c.decodeIfPresent(Bool.self, forKey: .deadLetterRescue) ?? true
        allowWager = try c.decodeIfPresent(Bool.self, forKey: .allowWager) ?? true
        turnDecay = try c.decodeIfPresent(Double.self, forKey: .turnDecay) ?? 0
        minimumTurnSeconds = try c.decodeIfPresent(Double.self, forKey: .minimumTurnSeconds) ?? 5
    }
}

public struct Move: Codable, Sendable, Equatable {
    public var playerID: String
    public var playerName: String
    /// The surface form exactly as the player typed it (tidied for case).
    public var text: String
    public var placeID: Int
    public var kind: String
    public var country: String
    /// True when this place entered the atlas through a challenge in this game.
    public var viaChallenge: Bool
    public var at: Double
    /// One line of geography, so the chain teaches as it scrolls past.  Empty
    /// for a place the atlas knows nothing about beyond its name.
    public var blurb: String
    public var points: Int
    /// The card that was in play, if any, and whether this move met it.
    public var card: Card?
    public var metCard: Bool
    /// True when the player summoned this card by betting a life on it, so the
    /// chain can say what the move was really worth: a life won or a life gone.
    public var wagered: Bool

    public init(playerID: String, playerName: String, text: String, placeID: Int,
                kind: String, country: String, viaChallenge: Bool, at: Double,
                blurb: String = "", points: Int = 1, card: Card? = nil,
                metCard: Bool = false, wagered: Bool = false) {
        self.playerID = playerID
        self.playerName = playerName
        self.text = text
        self.placeID = placeID
        self.kind = kind
        self.country = country
        self.viaChallenge = viaChallenge
        self.at = at
        self.blurb = blurb
        self.points = points
        self.card = card
        self.metCard = metCard
        self.wagered = wagered
    }
}

public struct LogEntry: Codable, Sendable, Equatable {
    public var seq: Int
    public var kind: String
    public var text: String
    public var playerID: String?
    public var at: Double
}

/// Why a submission was not accepted.
public enum RejectReason: Error, Sendable, Equatable {
    case gameNotRunning
    case notYourTurn
    case empty
    case tooShort
    case wrongLetter(expected: Character, got: Character)
    case alreadyUsed(name: String)
    case tooObscure(name: String, fame: Int)
    case notInAtlas
    case challengeInFlight
    /// Only raised at a table that plays cards as rules rather than as bonuses.
    case cardNotMet(demand: String)
    /// A bet that could not be taken — carries its own explanation, since the
    /// reasons are various and each of them is worth reading.
    case wagerRefused(String)

    public var code: String {
        switch self {
        case .gameNotRunning: return "game_not_running"
        case .notYourTurn: return "not_your_turn"
        case .empty: return "empty"
        case .tooShort: return "too_short"
        case .wrongLetter: return "wrong_letter"
        case .alreadyUsed: return "already_used"
        case .tooObscure: return "too_obscure"
        case .notInAtlas: return "not_in_atlas"
        case .challengeInFlight: return "challenge_in_flight"
        case .cardNotMet: return "card_not_met"
        case .wagerRefused: return "wager_refused"
        }
    }

    public var message: String {
        switch self {
        case .gameNotRunning: return "The game is not running."
        case .notYourTurn: return "It is not your turn."
        case .empty: return "Type a place first."
        case .tooShort: return "That is too short to be a place."
        case .wrongLetter(let e, let g):
            return "Must start with \(String(e).uppercased()) — you played \(String(g).uppercased())."
        case .alreadyUsed(let n): return "\(n) has already been played."
        case .tooObscure(let n, _): return "\(n) is too obscure for this game."
        case .notInAtlas: return "Not in the atlas."
        case .challengeInFlight: return "A challenge is already being checked."
        case .cardNotMet(let demand): return "The card says it must \(demand)."
        case .wagerRefused(let why): return why
        }
    }

    /// Whether offering the "challenge this" button makes sense.
    public var isChallengeable: Bool {
        if case .notInAtlas = self { return true }
        if case .tooObscure = self { return true }
        return false
    }
}

public enum SubmitOutcome: Sendable {
    case accepted(Move)
    case rejected(RejectReason)
}

/// A challenge waiting on a web lookup.  The turn clock is paused while one of
/// these is outstanding.
public struct PendingChallenge: Codable, Sendable, Equatable {
    public var id: String
    public var playerID: String
    public var text: String
    public var startedAt: Double
}

/// What a ``PlaceVerifier`` concluded about a challenged name.
public struct VerificationResult: Codable, Sendable, Equatable {
    public var accepted: Bool
    /// Canonical title the source resolved to, e.g. "Zermatt".
    public var resolvedName: String
    public var kind: String
    public var summary: String
    public var sourceURL: String
    /// Human-readable explanation, shown either way.
    public var reason: String

    public init(accepted: Bool, resolvedName: String = "", kind: String = "place",
                summary: String = "", sourceURL: String = "", reason: String = "") {
        self.accepted = accepted
        self.resolvedName = resolvedName
        self.kind = kind
        self.summary = summary
        self.sourceURL = sourceURL
        self.reason = reason
    }
}
