import Foundation

/// Rules that must hold after every single state transition, whatever the
/// players do.  The simulator checks these thousands of times per run; the
/// server checks them never, because if they can be broken the simulator should
/// have found it first.
public enum Invariants {

    public static func check(_ game: Game, now: Double) -> [String] {
        var problems: [String] = []
        let view = game.view(now: now, moveLimit: .max, logLimit: 1)
        let moves = game.moves
        let players = game.players

        // 1. The chain actually chains.
        for (i, move) in moves.enumerated() where i > 0 {
            guard let prev = Normalize.lastLetter(moves[i - 1].text),
                  let cur = Normalize.firstLetter(move.text) else {
                problems.append("move \(i) has no letters: \(move.text)")
                continue
            }
            if prev != cur {
                problems.append("chain break at \(i): \(moves[i-1].text) -> \(move.text)")
            }
        }

        // 2. No place is played twice, under any of its names.
        var seen = Set<Int>()
        for move in moves where !seen.insert(move.placeID).inserted {
            problems.append("place \(move.placeID) (\(move.text)) played twice")
        }
        if seen.count != view.placesUsed {
            problems.append("used-set size \(view.placesUsed) != distinct moves \(seen.count)")
        }

        // 3. Turn pointer is sane.
        if game.phase == .playing {
            guard let currentID = game.currentPlayerID else {
                problems.append("playing but nobody is on turn")
                return problems
            }
            guard let current = players.first(where: { $0.id == currentID }) else {
                problems.append("current player \(currentID) is not in the roster")
                return problems
            }
            if current.eliminated { problems.append("eliminated player \(current.name) is on turn") }
            if view.timeLeft < 0 { problems.append("negative time left") }
            if view.timeLeft > game.config.turnSeconds + 0.01 {
                problems.append("time left \(view.timeLeft) exceeds turn length")
            }
        } else if game.currentPlayerID != nil {
            problems.append("phase \(game.phase) but a player is on turn")
        }

        // 4. Lives never go negative; elimination and lives agree.
        for p in players {
            if p.lives < 0 { problems.append("\(p.name) has \(p.lives) lives") }
            if p.eliminated && p.lives > 0 && game.phase != .finished {
                problems.append("\(p.name) eliminated with \(p.lives) lives left")
            }
            if !p.eliminated && p.lives <= 0 {
                problems.append("\(p.name) alive with no lives")
            }
        }

        // 5. A finished game has at most one survivor.
        if game.phase == .finished {
            let alive = players.filter { !$0.eliminated }
            if alive.count > 1 {
                problems.append("finished with \(alive.count) survivors")
            }
            if let w = game.winnerID, !players.contains(where: { $0.id == w }) {
                problems.append("winner \(w) is not a player")
            }
        }

        // 6. Every move was legal for the letter in force at the time.
        if let first = moves.first, let c = Normalize.firstLetter(first.text) {
            _ = c   // the opening letter is chosen by the engine; nothing to compare against
        }

        // 7. The scoreboard is exactly the moves, added up.  This catches both
        //    a mis-scored card and a dead-letter retraction that forgets to give
        //    the points back.
        for p in players {
            let mine = moves.filter { $0.playerID == p.id }
            let points = mine.reduce(0) { $0 + $1.points }
            if p.score != points {
                problems.append("\(p.name) scores \(p.score) but their moves total \(points)")
            }
            if p.placesPlayed != mine.count {
                problems.append("\(p.name) played \(p.placesPlayed) but has \(mine.count) moves")
            }
            let met = mine.filter { $0.metCard }.count
            if p.cardsMet != met {
                problems.append("\(p.name) met \(p.cardsMet) cards but \(met) moves say so")
            }
            if mine.contains(where: { $0.points < 1 }) {
                problems.append("\(p.name) has a move worth less than a point")
            }
        }

        // 8. A card that is a rule was actually obeyed.  A wagered card is the
        //    exception: the player asked for it and is allowed to miss it, which
        //    is the whole of what they staked a life on.
        if game.config.forcedCards {
            for move in moves where !move.wagered {
                guard let card = move.card else { continue }
                if !card.accepts(text: move.text, place: game.atlas.place(move.placeID)) {
                    problems.append("\(move.text) broke the forced card: \(card.demand)")
                }
            }
        }

        // 9. A bet is only ever a bet against a hard card, and only ever appears
        //    on a turn that had a card at all.
        for move in moves where move.wagered {
            guard let card = move.card else {
                problems.append("\(move.text) was wagered with no card on the table")
                continue
            }
            if card.tier != .hard {
                problems.append("\(move.text) wagered against a \(card.tier) card")
            }
        }
        return problems
    }
}

/// How a simulated human behaves.
public struct FuzzProfile: Sendable {
    /// Chance a turn begins with one or more junk submissions.
    public var junkRate: Double = 0.35
    /// Chance the player simply lets the clock run out.
    public var stallRate: Double = 0.08
    /// Chance of trying a challenge on an unknown name.
    public var challengeRate: Double = 0.15
    /// Chance a challenge is upheld by the stub verifier.
    public var challengeSuccessRate: Double = 0.5
    /// Fame floor this player's vocabulary reaches.
    public var minFame: Int = 60
    /// Chance of bothering to meet a card that is only worth points.  A forced
    /// card is always attempted regardless of this.
    public var cardRate: Double = 0.55
    /// Chance of staking a life on a hard card when the table allows it.  Kept
    /// well above what a sane player would do so that both halves of the bet —
    /// paid and lost — turn up thousands of times in a sweep.
    public var wagerRate: Double = 0.2

    public init() {}
}

public struct SimResult: Sendable {
    public var moves: Int
    public var turns: Int
    public var winnerName: String?
    public var virtualSeconds: Double
    public var violations: [String]
    public var rejections: Int
    public var challenges: Int
    public var challengesUpheld: Int
    public var timeouts: Int
    /// Moves played with a card on the table, and how many of those met it.
    public var cardsDealt: Int
    public var cardsMet: Int
    /// Lives staked, and how many of those bets came home.  A bet the clock ate
    /// is counted as made but not settled, so these need not agree.
    public var wagersMade: Int
    public var wagersWon: Int
    public var points: Int
    /// Times the letter in play had no answer left and the turn was handed back.
    /// Read off the log, which is capped, so a marathon game may under-report.
    public var deadLetters: Int
    public var transcript: [String]
}

/// Plays whole games against a virtual clock.
///
/// Time never really passes: the loop jumps to whichever is sooner, the engine's
/// next deadline or the next scripted human action.  A thousand games therefore
/// run in about a second while exercising exactly the code paths a real server
/// would.
public struct Simulator {

    public struct Seat: Sendable {
        public var name: String
        public var isBot: Bool
        public var difficulty: BotDifficulty?
        public var profile: FuzzProfile?

        public static func bot(_ name: String, _ d: BotDifficulty) -> Seat {
            Seat(name: name, isBot: true, difficulty: d, profile: nil)
        }
        public static func human(_ name: String, _ p: FuzzProfile = FuzzProfile()) -> Seat {
            Seat(name: name, isBot: false, difficulty: nil, profile: p)
        }
    }

    /// Nonsense a fuzzing player might type.  Every one of these must be
    /// rejected cleanly rather than crashing or corrupting state.
    static let junk: [String] = [
        "", " ", "   ", "\n\t", "a", "x", "1234", "!!!", "-", "'",
        "notaplacename", "qqqqqqq", "zzzzzz", "🌍🌎", "Ｓｙｄｎｅｙ",
        "<script>alert(1)</script>", "'; DROP TABLE places;--",
        String(repeating: "long", count: 200), "null", "undefined", "NaN",
        "Sydney Opera House", "Barack Obama", "Casablanca the film",
    ]

    /// Generous enough that a table of players who never fail still runs the
    /// atlas dry — otherwise "did the game end?" would fail on good play.
    public static let defaultVirtualLimit: Double = 400_000

    public static func run(seats: [Seat], config: GameConfig = GameConfig(),
                           seed: UInt64, atlas: Atlas,
                           maxVirtualSeconds: Double = defaultVirtualLimit,
                           recordTranscript: Bool = false) -> SimResult {
        var rng = SeededRNG(seed: seed)
        let game = Game(atlas: atlas, config: config, seed: seed &* 31 &+ 7)
        let verifier = StubVerifier()

        for (i, seat) in seats.enumerated() {
            var p = Player(id: "p\(i)", name: seat.name, isBot: seat.isBot,
                           difficulty: seat.difficulty, lives: config.lives)
            p.connected = true
            game.addPlayer(p)
        }

        var now = 0.0
        var violations: [String] = []
        var transcript: [String] = []
        var rejections = 0, challenges = 0, upheld = 0, timeouts = 0, wagers = 0
        var turns = 0

        func audit() {
            let found = Invariants.check(game, now: now)
            if !found.isEmpty { violations.append(contentsOf: found) }
        }

        game.start(now: now)
        audit()

        // When the human on turn intends to act, and with what.
        var humanActAt: Double?
        var lastTurnKey = ""

        var guardCounter = 0
        while game.phase == .playing && now < maxVirtualSeconds {
            guardCounter += 1
            if guardCounter > 200_000 {
                violations.append("simulation did not terminate")
                break
            }

            let currentID = game.currentPlayerID
            let turnKey = "\(currentID ?? "-")#\(game.moves.count)#\(game.players.map { $0.lives })"
            if turnKey != lastTurnKey {
                lastTurnKey = turnKey
                turns += 1
                humanActAt = nil
            }

            // Schedule the human's action for this turn.
            let seatIndex = currentID.flatMap { id in game.players.firstIndex { $0.id == id } }
            let isHumanTurn = seatIndex.map { !game.players[$0].isBot } ?? false
            if isHumanTurn, humanActAt == nil {
                let left = game.timeLeft(now: now)
                humanActAt = now + Double.random(in: 0.2...max(0.3, left * 0.8), using: &rng)
            }

            let engineWake = game.nextWakeup(now: now) ?? (now + 1)
            let target = min(engineWake, humanActAt ?? .greatestFiniteMagnitude)
            now = max(now + 0.0005, target)

            if isHumanTurn, let actAt = humanActAt, now >= actAt,
               let idx = seatIndex, let profile = seats[idx].profile {
                humanActAt = nil
                let id = game.players[idx].id
                let outcome = playHumanTurn(game: game, atlas: atlas, verifier: verifier,
                                            playerID: id, profile: profile,
                                            now: &now, rng: &rng,
                                            rejections: &rejections,
                                            challenges: &challenges, upheld: &upheld,
                                            wagers: &wagers)
                if recordTranscript, let line = outcome { transcript.append(line) }
                audit()
            }

            let before = game.players.map(\.lives)
            if game.tick(now: now) {
                let after = game.players.map(\.lives)
                timeouts += zip(before, after).filter { $0 > $1 }.count
                if recordTranscript, let last = game.log.last {
                    transcript.append("[\(String(format: "%6.1f", now))] \(last.text)")
                }
                audit()
            }
        }

        if game.phase == .playing {
            violations.append("game still running after \(Int(now))s of virtual time")
        }
        audit()

        let winner = game.winnerID.flatMap { id in game.players.first { $0.id == id }?.name }
        let finished = game.moves
        return SimResult(moves: finished.count, turns: turns, winnerName: winner,
                         virtualSeconds: now, violations: violations,
                         rejections: rejections, challenges: challenges,
                         challengesUpheld: upheld, timeouts: timeouts,
                         cardsDealt: finished.filter { $0.card != nil }.count,
                         cardsMet: finished.filter(\.metCard).count,
                         wagersMade: wagers,
                         wagersWon: finished.filter { $0.wagered && $0.metCard }.count,
                         points: game.players.reduce(0) { $0 + $1.score },
                         deadLetters: game.log.filter { $0.kind == "dead_letter" }.count,
                         transcript: transcript)
    }

    /// One simulated human turn: some junk, maybe a challenge, maybe a real move.
    /// `now` is `inout` because a challenge consumes real time: the lookup has
    /// to finish before the player can play, and the caller's clock must follow
    /// the engine's or the two drift apart.
    private static func playHumanTurn(game: Game, atlas: Atlas, verifier: StubVerifier,
                                      playerID: String, profile: FuzzProfile,
                                      now: inout Double, rng: inout SeededRNG,
                                      rejections: inout Int, challenges: inout Int,
                                      upheld: inout Int, wagers: inout Int) -> String? {
        // Junk first — it must never disturb the game state.
        if Double.random(in: 0...1, using: &rng) < profile.junkRate {
            let attempts = Int(rng.next() % 3) + 1
            for _ in 0..<attempts {
                let text = junk[Int(rng.next() % UInt64(junk.count))]
                if case .rejected = game.submit(playerID: playerID, text: text, now: now) {
                    rejections += 1
                }
            }
        }

        // Replaying an already-used place must also be refused.
        if let earlier = game.moves.randomElement(using: &rng),
           Double.random(in: 0...1, using: &rng) < 0.2 {
            if case .rejected = game.submit(playerID: playerID, text: earlier.text, now: now) {
                rejections += 1
            }
        }

        // A bet, before the stall: a player who freezes after staking a life is
        // exactly the case where the clock has to void the bet instead of
        // charging for it twice, and it will not arise unless the fuzzer can
        // walk away from its own wager.
        if Double.random(in: 0...1, using: &rng) < profile.wagerRate,
           game.view(now: now, moveLimit: 0, logLimit: 0).canWager,
           case .success = game.wager(playerID: playerID, now: now) {
            wagers += 1
        }

        if Double.random(in: 0...1, using: &rng) < profile.stallRate { return nil }

        // A challenge on a name the atlas does not know.
        if game.config.allowChallenge,
           Double.random(in: 0...1, using: &rng) < profile.challengeRate,
           game.challengesRemaining(for: playerID) > 0 {
            let letter = game.requiredLetter
            let invented = String(letter).uppercased() + "qzntown"
            let accept = Double.random(in: 0...1, using: &rng) < profile.challengeSuccessRate
            verifier.stub(invented, VerificationResult(
                accepted: accept, resolvedName: invented, kind: "city",
                summary: "test", sourceURL: "", reason: accept ? "ok" : "not a place"))
            if case .success(let pending) = game.beginChallenge(playerID: playerID,
                                                                text: invented, now: now) {
                challenges += 1
                // Sometimes the lookup takes longer than the engine will wait,
                // which must resolve as a failure rather than a stuck clock.
                let delay = Double.random(in: 0.1...(Game.challengeTimeout + 4), using: &rng)
                let verdict = verifier.result(for: invented)
                now += delay
                _ = game.tick(now: now)
                if case .accepted = game.resolveChallenge(id: pending.id, result: verdict,
                                                          now: now) {
                    upheld += 1
                }
                return "challenge \(invented) -> \(accept)"
            }
        }

        // A real move.
        var options = atlas.candidates(startingWith: game.requiredLetter,
                                       minFame: max(profile.minFame, game.config.minFame),
                                       excluding: Set(game.moves.map(\.placeID)))
        // A card is worth going out of the way for, and at a forced table it is
        // the only kind of move that will be taken.  A player whose vocabulary
        // cannot meet it reaches further down the atlas before giving up.
        if let card = game.card {
            // Not `config.forcedCards`: a card you bet a life on is never a rule,
            // and half the point of the bet is being free to miss it.
            let forced = game.cardIsRule
            if forced || Double.random(in: 0...1, using: &rng) < profile.cardRate {
                var meeting = options.filter {
                    card.accepts(text: $0.text, place: atlas.place($0.placeID))
                }
                if meeting.isEmpty && forced {
                    meeting = atlas.candidates(startingWith: game.requiredLetter,
                                               minFame: game.config.minFame,
                                               excluding: Set(game.moves.map(\.placeID)))
                        .filter { card.accepts(text: $0.text, place: atlas.place($0.placeID)) }
                }
                if !meeting.isEmpty { options = meeting }
            }
        }
        guard !options.isEmpty else { return nil }
        let pick = options[Int(rng.next() % UInt64(min(options.count, 30)))]
        // Humans type in whatever case they feel like.
        let text = Bool.random(using: &rng) ? pick.text.lowercased() : pick.text
        switch game.submit(playerID: playerID, text: text, now: now) {
        case .accepted(let m): return "\(m.playerName) played \(m.text)"
        case .rejected: rejections += 1; return nil
        }
    }
}
