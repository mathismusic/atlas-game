import Foundation

/// The Atlas rules engine.
///
/// The engine owns no timers of its own.  Every entry point takes the current
/// time as a parameter and ``tick(now:)`` is what actually makes deadlines fire
/// and bots move.  A live server calls `tick` from a repeating timer; tests and
/// the simulator call it with fabricated clocks, so both exercise identical
/// code.
public final class Game: @unchecked Sendable {

    public let atlas: Atlas
    private let lock = NSRecursiveLock()

    private var _phase: GamePhase = .lobby
    private var _players: [Player] = []
    private var _config: GameConfig
    private var _moves: [Move] = []
    private var _log: [LogEntry] = []
    private var _used: Set<Int> = []
    private var _requiredLetter: Character = "a"
    private var _turn: Int = 0
    private var _deadline: Double = 0
    private var _pausedRemaining: Double?
    private var _pending: PendingChallenge?
    private var _challengeCount: [String: Int] = [:]
    private var _winnerID: String?
    private var _version: Int = 0
    private var _seq: Int = 0
    private var _startedAt: Double = 0
    private var _soloMode = false
    private var _card: Card?
    /// Set when the player to move summoned this turn's card by betting a life
    /// on it.  Cleared at the start of every turn, so a bet lives and dies
    /// inside the turn that made it.
    private var _wagered = false
    /// Memo for ``hardCardFeasibleLocked()``, thrown away every turn.
    private var _wagerFeasible: Bool?
    private var _rounds: Int = 0
    /// Letters abandoned by the dead-letter rule, so the engine never walks
    /// back into one it has already given up on.
    private var _deadLetters: Set<Character> = []

    private var rng: SeededRNG
    private var botPlan: (text: String?, actAt: Double)?

    /// A challenge left unanswered this long resolves as a failure.
    public static let challengeTimeout: Double = 12

    public init(atlas: Atlas, config: GameConfig = GameConfig(), seed: UInt64 = 0x5EED) {
        self.atlas = atlas
        self._config = config
        self.rng = SeededRNG(seed: seed)
    }

    // MARK: - Accessors

    public var phase: GamePhase { lock.withLock { _phase } }
    public var players: [Player] { lock.withLock { _players } }
    public var config: GameConfig { lock.withLock { _config } }
    public var moves: [Move] { lock.withLock { _moves } }
    public var log: [LogEntry] { lock.withLock { _log } }
    public var version: Int { lock.withLock { _version } }
    public var winnerID: String? { lock.withLock { _winnerID } }
    public var requiredLetter: Character { lock.withLock { _requiredLetter } }
    public var pendingChallenge: PendingChallenge? { lock.withLock { _pending } }
    public var usedCount: Int { lock.withLock { _used.count } }
    /// The card the player to move has to beat, if this turn was dealt one.
    public var card: Card? { lock.withLock { _card } }
    /// True while a life is riding on the card in play.
    public var wagerInPlay: Bool { lock.withLock { _wagered } }
    /// Whether the card in play must be obeyed to move at all.  A wagered card
    /// never is: being able to fail it is the entire bet.
    public var cardIsRule: Bool { lock.withLock { _config.forcedCards && !_wagered } }

    public var currentPlayerID: String? {
        lock.withLock {
            guard _phase == .playing, _players.indices.contains(_turn) else { return nil }
            return _players[_turn].id
        }
    }

    public func timeLeft(now: Double) -> Double {
        lock.withLock {
            guard _phase == .playing else { return 0 }
            if let paused = _pausedRemaining { return paused }
            return max(0, _deadline - now)
        }
    }

    // MARK: - Lobby

    @discardableResult
    public func addPlayer(_ player: Player, now: Double = 0) -> Bool {
        lock.withLock {
            guard _phase == .lobby else { return false }
            guard !_players.contains(where: { $0.id == player.id }) else { return false }
            guard _players.count < 8 else { return false }
            var p = player
            p.lives = _config.lives
            _players.append(p)
            note("join", "\(p.name) joined", p.id, now)
            return true
        }
    }

    @discardableResult
    public func removePlayer(id: String, now: Double = 0) -> Bool {
        lock.withLock {
            guard let idx = _players.firstIndex(where: { $0.id == id }) else { return false }
            let name = _players[idx].name
            if _phase == .lobby {
                _players.remove(at: idx)
            } else {
                // Mid-game departures forfeit rather than reshuffle the order.
                guard !_players[idx].eliminated else { return false }
                _players[idx].eliminated = true
                _players[idx].lives = 0
                if idx == _turn { advanceTurnLocked(now: now) }
            }
            note("leave", "\(name) left", id, now)
            checkGameOverLocked(now: now)
            bump()
            return true
        }
    }

    public func setConnected(id: String, _ connected: Bool) {
        lock.withLock {
            guard let idx = _players.firstIndex(where: { $0.id == id }) else { return }
            guard _players[idx].connected != connected else { return }
            _players[idx].connected = connected
            bump()
        }
    }

    public func updateConfig(_ config: GameConfig) {
        lock.withLock {
            guard _phase == .lobby else { return }
            _config = config
            for i in _players.indices { _players[i].lives = config.lives }
            bump()
        }
    }

    @discardableResult
    public func start(now: Double) -> Bool {
        lock.withLock {
            guard _phase == .lobby, !_players.isEmpty else { return false }
            _phase = .playing
            _startedAt = now
            _soloMode = _players.count == 1
            _turn = 0
            _requiredLetter = resolveStartLetter()
            note("start", "Game on — first letter is \(String(_requiredLetter).uppercased())", nil, now)
            beginTurnLocked(now: now)
            bump()
            return true
        }
    }

    /// Prefer an opening letter that leaves everyone plenty of room.
    private func resolveStartLetter() -> Character {
        if let s = _config.startLetter, let c = Normalize.letters(s).first { return c }
        let roomy = atlas.startingLetters.filter {
            atlas.replyCount(for: $0, minFame: max(_config.minFame, 74)) >= 25
        }
        let pool = roomy.isEmpty ? atlas.startingLetters : roomy
        return pool.isEmpty ? "s" : pool[Int(rng.next() % UInt64(pool.count))]
    }

    // MARK: - Playing

    public func submit(playerID: String, text: String, now: Double) -> SubmitOutcome {
        lock.withLock {
            let typed = Normalize.displayCase(text)
            if let reason = validateLocked(playerID: playerID, text: typed) {
                note("reject", "\(nameOf(playerID)): \(reason.message)", playerID, now)
                bump()
                return .rejected(reason)
            }
            guard let surface = atlas.surface(matching: typed) else {
                return .rejected(.notInAtlas)   // unreachable; validate covers it
            }
            return .accepted(applyLocked(surface: surface, typed: typed,
                                         playerID: playerID, viaChallenge: false, now: now))
        }
    }

    /// Runs every rule against a submission without mutating anything.
    /// Returns `nil` when the move is legal.
    private func validateLocked(playerID: String, text: String) -> RejectReason? {
        guard _phase == .playing else { return .gameNotRunning }
        guard _pending == nil else { return .challengeInFlight }
        guard _players.indices.contains(_turn), _players[_turn].id == playerID else {
            return .notYourTurn
        }
        let letters = Normalize.letters(text)
        if letters.isEmpty { return .empty }
        if letters.count < 2 { return .tooShort }
        guard let first = letters.first else { return .empty }
        if first != _requiredLetter { return .wrongLetter(expected: _requiredLetter, got: first) }
        guard let surface = atlas.surface(matching: text) else { return .notInAtlas }
        if _used.contains(surface.placeID) {
            return .alreadyUsed(name: atlas.place(surface.placeID)?.name ?? text)
        }
        if surface.fame < _config.minFame {
            return .tooObscure(name: text, fame: surface.fame)
        }
        // A wagered card is never a rule — see `wager(playerID:now:)`.
        if _config.forcedCards, !_wagered, let card = _card,
           !card.accepts(text: text, place: atlas.place(surface.placeID)) {
            return .cardNotMet(demand: card.demand)
        }
        return nil
    }

    private func applyLocked(surface: Atlas.Surface, typed: String, playerID: String,
                             viaChallenge: Bool, now: Double) -> Move {
        let place = atlas.place(surface.placeID)
        let card = _card
        let wagered = _wagered
        let met = card?.accepts(text: typed, place: place) ?? false
        let points = met ? (card?.multiplier ?? 1) : 1
        let move = Move(playerID: playerID, playerName: nameOf(playerID), text: typed,
                        placeID: surface.placeID, kind: place?.kind ?? "place",
                        country: place?.country ?? "", viaChallenge: viaChallenge, at: now,
                        blurb: place?.blurb ?? "", points: points,
                        card: card, metCard: met, wagered: wagered)
        _moves.append(move)
        _used.insert(surface.placeID)
        _requiredLetter = surface.last

        if let index = _players.firstIndex(where: { $0.id == playerID }) {
            _players[index].score += points
            _players[index].placesPlayed += 1
            if met {
                _players[index].cardsMet += 1
                // The life is the whole reason to take a hard card on.
                if card?.grantsLife == true { _players[index].lives += 1 }
            }
        }
        note("move", "\(move.playerName) played \(typed)", playerID, now)
        if let card, met {
            let bonus = card.grantsLife ? " and an extra life" : ""
            let what = wagered ? "won the bet" : "met the card"
            note("card_met", "\(move.playerName) \(what) — \(points) points\(bonus)",
                 playerID, now)
        }
        // The other half of a bet: the card missed costs the life staked on it.
        if wagered, !met, let index = _players.firstIndex(where: { $0.id == playerID }) {
            _players[index].lives -= 1
            if _players[index].lives <= 0 {
                _players[index].eliminated = true
                note("eliminated", "\(move.playerName) lost the bet — out of the game",
                     playerID, now)
            } else {
                let left = _players[index].lives
                note("wager_lost",
                     "\(move.playerName) lost the bet — \(left) \(left == 1 ? "life" : "lives") left",
                     playerID, now)
            }
        }
        advanceTurnLocked(now: now)
        checkGameOverLocked(now: now)
        if _phase == .playing { beginTurnLocked(now: now) }
        bump()
        return move
    }

    /// The clock for the turn about to start.  A table with `turnDecay` set
    /// tightens as the game goes on, which is the whole point of a blitz.
    private var currentTurnSeconds: Double {
        let seats = max(1, _players.filter { !$0.eliminated }.count)
        let rounds = Double(_moves.count / seats)
        // The floor may never *raise* the clock: a table that asked for three
        // seconds a turn gets three, not the five the floor would like.
        let floor = min(_config.minimumTurnSeconds, _config.turnSeconds)
        return max(floor, _config.turnSeconds - _config.turnDecay * rounds)
    }

    private func beginTurnLocked(now: Double) {
        guard _phase == .playing, _players.indices.contains(_turn) else { return }
        _deadline = now + currentTurnSeconds
        _pausedRemaining = nil
        botPlan = nil
        // A bet belongs to the turn that made it, and to no other.
        _wagered = false
        _wagerFeasible = nil
        let player = _players[_turn]
        dealCardLocked(to: player, now: now)

        guard player.isBot else { return }
        let difficulty = player.difficulty ?? .medium
        let brain = Bot(atlas: atlas, difficulty: difficulty)
        let choice = brain.choose(letter: _requiredLetter, used: _used,
                                  minFame: _config.minFame, card: _card,
                                  mustMeetCard: _config.forcedCards, rng: &rng)
        let think = Double.random(in: difficulty.thinkRange, using: &rng)
        if choice == nil {
            // No move (or a deliberate blunder): let the clock run out naturally.
            botPlan = (nil, _deadline + 0.001)
        } else {
            botPlan = (choice, now + min(think, max(0.2, currentTurnSeconds - 0.5)))
        }
    }

    /// Deals this turn's card, if the table plays them and the letter can
    /// answer one.  A starved letter is left alone: the deck refuses to make a
    /// hard turn harder.
    private func dealCardLocked(to player: Player, now: Double) {
        _card = nil
        guard _config.cardChance > 0, !_config.cardTiers.isEmpty else { return }
        guard Double.random(in: 0..<1, using: &rng) < _config.cardChance else { return }
        guard let card = CardDeck.deal(atlas: atlas, letter: _requiredLetter, used: _used,
                                       minFame: _config.minFame,
                                       tiers: _config.cardTiers, rng: &rng) else { return }
        _card = card
        let reward = card.grantsLife
            ? "×\(card.multiplier) and a life"
            : "×\(card.multiplier)"
        note("card", "\(player.name) draws a card — the place must \(card.demand) (\(reward))",
             player.id, now)
    }

    private func advanceTurnLocked(now: Double) {
        guard !_players.isEmpty else { return }
        for step in 1..._players.count {
            let idx = (_turn + step) % _players.count
            if !_players[idx].eliminated { _turn = idx; return }
        }
        // Everyone is out.
        _phase = .finished
    }

    /// A place under the current letter that nobody has played yet, ignoring
    /// fame.  This is Ada's answer when a player gives up: proof the turn was
    /// playable after all.
    ///
    /// At a forced table the card is part of what makes an answer legal, so an
    /// answer that broke it would prove nothing — and a letter whose every
    /// remaining place breaks the card is as dead as an empty one, which is
    /// what returning nil here says.
    private func rescueAnswerLocked() -> String? {
        let options = atlas.candidates(startingWith: _requiredLetter, minFame: 0,
                                       excluding: _used)
        if _config.forcedCards, !_wagered, let card = _card {
            return options.first {
                card.accepts(text: $0.text, place: atlas.place($0.placeID))
            }?.text
        }
        return options.first?.text
    }

    /// Undoes the move that set the current letter and hands the turn back.
    ///
    /// The rule the table plays by: if you cannot go, Ada has to show you one.
    /// When even Ada has nothing the letter itself was the problem, not you —
    /// so the place that led here is taken off the board, the player who said
    /// it gets the turn again, and they have to find something else.  Nobody
    /// loses a life for a letter with no answers.
    ///
    /// Returns false when there is nothing to give back — the opening letter,
    /// or a chain already unwound once — and the caller takes the life instead.
    private func retractLastMoveLocked(now: Double) -> Bool {
        guard let last = _moves.last,
              let index = _players.firstIndex(where: { $0.id == last.playerID }),
              !_players[index].eliminated,
              !_deadLetters.contains(_requiredLetter) else { return false }

        let stuckOn = String(_requiredLetter).uppercased()
        _deadLetters.insert(_requiredLetter)
        _moves.removeLast()
        _used.remove(last.placeID)
        _players[index].score -= last.points
        _players[index].placesPlayed -= 1
        if last.metCard {
            _players[index].cardsMet -= 1
            if last.card?.grantsLife == true { _players[index].lives -= 1 }
        }
        // Back to whatever letter that player was answering.
        _requiredLetter = _moves.last.flatMap { Normalize.letters($0.text).last }
            ?? resolveStartLetter()
        _turn = index
        note("dead_letter",
             "Nothing left starting with \(stuckOn) — \(last.text) is taken back "
                 + "and \(_players[index].name) plays again",
             last.playerID, now)
        beginTurnLocked(now: now)
        bump()
        return true
    }

    // MARK: - Wagers

    /// Bets a life on a hard card of the player's own summoning.
    ///
    /// The card *is* the bet.  Meeting it pays exactly what a hard card always
    /// pays — five times the points, and the extra life a hard card grants —
    /// and missing it costs the life that was staked.  So a wagered card is
    /// never a rule, even at a table where cards are rules: being allowed to
    /// fail it is the whole of the bet.
    ///
    /// Running out of time voids it.  The clock has already taken a life by
    /// then, and taking two for one turn reads as a bug however it is worded.
    @discardableResult
    public func wager(playerID: String, now: Double) -> Result<Card, RejectReason> {
        lock.withLock {
            if let reason = wagerRefusalLocked(playerID: playerID) { return .failure(reason) }
            guard let card = CardDeck.deal(atlas: atlas, letter: _requiredLetter, used: _used,
                                           minFame: _config.minFame, tiers: [.hard],
                                           rng: &rng) else {
                return .failure(.wagerRefused(noHardCardHere))
            }
            _card = card
            _wagered = true
            note("wager", "\(nameOf(playerID)) bets a life — the place must \(card.demand) "
                    + "(×\(card.multiplier) and a life if it does)",
                 playerID, now)
            bump()
            return .success(card)
        }
    }

    private var noHardCardHere: String {
        "No hard card fits \(String(_requiredLetter).uppercased()) — nothing to bet on."
    }

    /// Why the seat to move cannot bet right now, or nil if it can.  Passing a
    /// player checks it is their seat; passing none asks about the seat itself,
    /// which is what the snapshot needs.
    private func wagerRefusalLocked(playerID: String? = nil) -> RejectReason? {
        guard _config.allowWager else {
            return .wagerRefused("This table does not play bets.")
        }
        guard _phase == .playing, _players.indices.contains(_turn) else {
            return .wagerRefused("The game is not running.")
        }
        guard _pending == nil else { return .challengeInFlight }
        let seat = _players[_turn]
        if let playerID, playerID != seat.id { return .notYourTurn }
        guard !seat.isBot else { return .wagerRefused("Only a player can bet.") }
        guard !_wagered else { return .wagerRefused("You have already bet this turn.") }
        guard hardCardFeasibleLocked() else { return .wagerRefused(noHardCardHere) }
        return nil
    }

    /// Whether a hard card exists for the letter in play.  Asked on every
    /// snapshot, so the answer is worked out once a turn and remembered — and
    /// worked out without the dealer's randomness, or merely drawing the button
    /// would change which cards the rest of the game gets.
    private func hardCardFeasibleLocked() -> Bool {
        if let known = _wagerFeasible { return known }
        let feasible = CardDeck.canDeal(atlas: atlas, letter: _requiredLetter, used: _used,
                                        minFame: _config.minFame, tiers: [.hard])
        _wagerFeasible = feasible
        return feasible
    }

    private func timeoutLocked(now: Double) {
        guard _phase == .playing, _players.indices.contains(_turn) else { return }
        if _wagered {
            note("wager_off", "\(_players[_turn].name) ran out of time — the bet is off",
                 _players[_turn].id, now)
        }

        if _config.deadLetterRescue {
            if let answer = rescueAnswerLocked() {
                // Named after whichever bot is at the table, so the line reads
                // as a person showing you up rather than as machinery.
                let oracle = _players.first(where: { $0.isBot })?.name ?? "The atlas"
                note("rescue", "\(oracle) would have said \(answer)", nil, now)
            } else if retractLastMoveLocked(now: now) {
                return
            }
        }

        let name = _players[_turn].name
        let id = _players[_turn].id
        _players[_turn].lives -= 1
        if _players[_turn].lives <= 0 {
            _players[_turn].eliminated = true
            // Phrased without a verb agreeing with the name, since the name is
            // sometimes "You" and "You is eliminated" reads badly.
            note("eliminated", "\(name) ran out of time — out of the game", id, now)
        } else {
            let left = _players[_turn].lives
            note("timeout", "\(name) ran out of time — \(left) \(left == 1 ? "life" : "lives") left",
                 id, now)
        }
        advanceTurnLocked(now: now)
        checkGameOverLocked(now: now)
        if _phase == .playing { beginTurnLocked(now: now) }
        bump()
    }

    private func checkGameOverLocked(now: Double) {
        guard _phase == .playing else { return }
        let active = _players.filter { !$0.eliminated }
        if _soloMode {
            guard active.isEmpty else { return }
            _phase = .finished
            _winnerID = nil
            note("end", "Chain ended at \(_moves.count) places", nil, now)
        } else {
            guard active.count <= 1 else { return }
            _phase = .finished
            _winnerID = active.first?.id
            if let w = active.first {
                note("win", "\(w.name) wins", w.id, now)
            } else {
                note("end", "Everyone is out", nil, now)
            }
        }
        bump()
    }

    // MARK: - Challenges

    /// Validates a challenge request and pauses the clock.  The caller performs
    /// the actual lookup and reports back via ``resolveChallenge(id:result:now:)``.
    public func beginChallenge(playerID: String, text: String,
                               now: Double) -> Result<PendingChallenge, RejectReason> {
        lock.withLock {
            let typed = Normalize.displayCase(text)
            guard _config.allowChallenge else { return .failure(.notInAtlas) }
            guard _pending == nil else { return .failure(.challengeInFlight) }
            guard let reason = validateLocked(playerID: playerID, text: typed) else {
                // Already legal — nothing to challenge.
                return .failure(.alreadyUsed(name: typed))
            }
            guard reason.isChallengeable else { return .failure(reason) }
            let used = _challengeCount[playerID, default: 0]
            if _config.challengesPerPlayer > 0, used >= _config.challengesPerPlayer {
                return .failure(.tooObscure(name: typed, fame: 0))
            }
            _challengeCount[playerID] = used + 1
            _pausedRemaining = max(0, _deadline - now)
            let pending = PendingChallenge(id: "ch\(_seq)-\(playerID)", playerID: playerID,
                                           text: typed, startedAt: now)
            _pending = pending
            // "\(name) is checking" breaks when the name is "You", which is what
            // the terminal client calls its player.
            note("challenge", "\(nameOf(playerID)) — checking \(typed) online…", playerID, now)
            bump()
            return .success(pending)
        }
    }

    /// Applies a lookup verdict.  On success the place joins the atlas
    /// permanently and the move is played; on failure the clock resumes.
    @discardableResult
    public func resolveChallenge(id: String, result: VerificationResult,
                                 now: Double) -> SubmitOutcome? {
        lock.withLock {
            guard let pending = _pending, pending.id == id else { return nil }
            _pending = nil
            if let remaining = _pausedRemaining {
                _deadline = now + remaining
                _pausedRemaining = nil
            }
            guard result.accepted else {
                note("challenge_failed", "\(pending.text) was not confirmed — \(result.reason)",
                     pending.playerID, now)
                bump()
                return .rejected(.notInAtlas)
            }

            let canonical = result.resolvedName.isEmpty ? pending.text : result.resolvedName
            var aliases: [String] = []
            if Normalize.key(canonical) != Normalize.key(pending.text) {
                aliases.append(pending.text)
            }
            let learned = Place(name: canonical, kind: result.kind, country: "",
                                fame: 70, aliases: aliases, learned: true)
            atlas.insert(learned)
            note("challenge_ok", "\(canonical) confirmed and added to the atlas",
                 pending.playerID, now)

            // Re-validate: the challenge may have been resolved after a timeout.
            if let reason = validateLocked(playerID: pending.playerID, text: pending.text) {
                note("reject", "\(nameOf(pending.playerID)): \(reason.message)",
                     pending.playerID, now)
                bump()
                return .rejected(reason)
            }
            guard let surface = atlas.surface(matching: pending.text) else {
                bump()
                return .rejected(.notInAtlas)
            }
            return .accepted(applyLocked(surface: surface, typed: pending.text,
                                         playerID: pending.playerID,
                                         viaChallenge: true, now: now))
        }
    }

    /// How many challenges this player has left, or `Int.max` at a table that
    /// does not ration them.  Callers only ever ask whether it is above zero.
    public func challengesRemaining(for playerID: String) -> Int {
        lock.withLock {
            guard _config.challengesPerPlayer > 0 else { return .max }
            return max(0, _config.challengesPerPlayer - _challengeCount[playerID, default: 0])
        }
    }

    // MARK: - Clock

    /// Advances the world to `now`.  Returns true when anything changed.
    /// Safe to call at any rate; several events may fire in one call.
    @discardableResult
    public func tick(now: Double) -> Bool {
        lock.withLock {
            var changed = false
            // Bounded so a pathological state can never spin forever.
            for _ in 0..<64 {
                guard _phase == .playing else { break }

                if let pending = _pending {
                    guard now - pending.startedAt >= Game.challengeTimeout else { break }
                    _pending = nil
                    if let remaining = _pausedRemaining {
                        _deadline = now + remaining
                        _pausedRemaining = nil
                    }
                    note("challenge_failed",
                         "\(pending.text) could not be checked in time", pending.playerID, now)
                    changed = true
                    bump()
                    continue
                }

                if let plan = botPlan, let text = plan.text, now >= plan.actAt {
                    botPlan = nil
                    let id = _players[_turn].id
                    if let surface = atlas.surface(matching: text),
                       validateLocked(playerID: id, text: text) == nil {
                        _ = applyLocked(surface: surface, typed: text, playerID: id,
                                        viaChallenge: false, now: now)
                    } else {
                        // Someone took the bot's pick while it was thinking; re-plan.
                        beginTurnLocked(now: now)
                    }
                    changed = true
                    continue
                }

                if now >= _deadline {
                    timeoutLocked(now: now)
                    changed = true
                    continue
                }
                break
            }
            return changed
        }
    }

    /// Next moment the engine needs attention — lets the server sleep instead of spin.
    public func nextWakeup(now: Double) -> Double? {
        lock.withLock {
            guard _phase == .playing else { return nil }
            if let pending = _pending { return pending.startedAt + Game.challengeTimeout }
            if let plan = botPlan, plan.text != nil { return min(plan.actAt, _deadline) }
            return _deadline
        }
    }

    // MARK: - Snapshot

    public struct View: Codable, Sendable {
        public var version: Int
        public var phase: String
        public var players: [Player]
        public var config: GameConfig
        public var requiredLetter: String
        public var currentPlayerID: String?
        public var timeLeft: Double
        public var turnSeconds: Double
        public var paused: Bool
        public var moves: [Move]
        public var log: [LogEntry]
        public var winnerID: String?
        public var pending: PendingChallenge?
        public var placesUsed: Int
        public var atlasSize: Int
        public var chainLength: Int
        public var card: Card?
        /// True when the card must be met rather than merely being worth points.
        public var cardIsRule: Bool
        /// True when a life is riding on the card in play.
        public var wagered: Bool
        /// Whether the player to move could bet a life right now.  The phone
        /// hides the button rather than offering a bet that would be refused.
        public var canWager: Bool
    }

    public func view(now: Double, moveLimit: Int = 40, logLimit: Int = 40) -> View {
        lock.withLock {
            View(version: _version,
                 phase: _phase.rawValue,
                 players: _players,
                 config: _config,
                 requiredLetter: String(_requiredLetter),
                 currentPlayerID: _phase == .playing && _players.indices.contains(_turn)
                     ? _players[_turn].id : nil,
                 timeLeft: _phase == .playing
                     ? (_pausedRemaining ?? max(0, _deadline - now)) : 0,
                 turnSeconds: currentTurnSeconds,
                 paused: _pausedRemaining != nil,
                 moves: Array(_moves.suffix(moveLimit)),
                 log: Array(_log.suffix(logLimit)),
                 winnerID: _winnerID,
                 pending: _pending,
                 placesUsed: _used.count,
                 atlasSize: atlas.placeCount,
                 chainLength: _moves.count,
                 card: _card,
                 cardIsRule: _config.forcedCards && !_wagered,
                 wagered: _wagered,
                 canWager: wagerRefusalLocked() == nil)
        }
    }

    /// Hint list for a stuck human player.
    ///
    /// When a card is in play the hints have to answer it too — a hint that
    /// would be refused is worse than no hint.  If the famous tier cannot meet
    /// the card the search drops to the whole atlas rather than coming back
    /// empty, since the deck has already promised the card is answerable.
    public func hints(limit: Int = 5, now: Double) -> [String] {
        lock.withLock {
            func pick(minFame: Int) -> [String] {
                let all = atlas.candidates(startingWith: _requiredLetter,
                                           minFame: minFame, excluding: _used)
                guard let card = _card else { return all.prefix(limit).map(\.text) }
                return all.filter { card.accepts(text: $0.text, place: atlas.place($0.placeID)) }
                    .prefix(limit).map(\.text)
            }
            let famous = pick(minFame: max(_config.minFame, 70))
            return famous.isEmpty ? pick(minFame: _config.minFame) : famous
        }
    }

    // MARK: - Helpers

    private func nameOf(_ id: String) -> String {
        _players.first(where: { $0.id == id })?.name ?? "Someone"
    }

    private func note(_ kind: String, _ text: String, _ playerID: String?, _ at: Double) {
        _seq += 1
        _log.append(LogEntry(seq: _seq, kind: kind, text: text, playerID: playerID, at: at))
        if _log.count > 400 { _log.removeFirst(_log.count - 400) }
    }

    private func bump() { _version += 1 }
}

extension NSRecursiveLock {
    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
