import AtlasCore
import AtlasServer
import Foundation

let args = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool { args.contains("--\(name)") }

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func intOption(_ name: String, _ fallback: Int) -> Int { option(name).flatMap(Int.init) ?? fallback }
func doubleOption(_ name: String, _ fallback: Double) -> Double {
    option(name).flatMap(Double.init) ?? fallback
}

let usage = """
atlas — the place-chaining game

  atlas serve   [--port 8080] [--host 0.0.0.0] [--offline] [--no-harvest]
                Start the game server.  Open the printed URL on your phone.

  atlas sim     [--games 200] [--seed 1] [--seats bots|mixed|humans|solo]
                [--turn 30] [--lives 2] [--verbose]
                [--cards 0.4] [--forced-cards] [--tiers easy,medium,hard]
                [--decay 0] [--no-rescue]
                Play games against a virtual clock and check every invariant.

  atlas soak    [--seconds 30] [--threads 8]
                Hammer one game from many threads looking for races.

  atlas verify  <place name>
                Run the live challenge lookup against Wikipedia.

  atlas stats   Show what is in the bundled atlas.

  atlas media   [status] [--limit 500] [--interval 0.4]
                Fetch pictures and quirky facts, one place at a time.  Safe to
                stop and re-run: it picks up where it left off.

  atlas play    [--difficulty hard] [--turn 30] [--lives 2] [--name Krishna]
                [--mode classic|cards|forced|blitz|marathon|brutal]
                Play in the terminal, no browser needed.
"""

// MARK: - Shared

func loadAtlas() -> Atlas {
    Atlas.standard(learnedFile: AtlasPaths.learnedFile)
}

// MARK: - Commands

func cmdStats() {
    let atlas = loadAtlas()
    print("places   \(atlas.placeCount)")
    print("surfaces \(atlas.surfaceCount)   (names players may type)")
    let learned = atlas.learnedPlaces
    print("learned  \(learned.count)\(learned.isEmpty ? "" : "  " + learned.map(\.name).joined(separator: ", "))")

    var kinds: [String: Int] = [:]
    for p in atlas.allPlaces { kinds[p.kind, default: 0] += 1 }
    print("\nby kind")
    for (k, v) in kinds.sorted(by: { $0.value > $1.value }) {
        // Padded in Swift rather than with printf's %s, which needs a C string
        // and an NSString bridge to get one — deprecated, and a bridge that
        // does not exist away from Apple's Foundation.
        print("  " + k.padding(toLength: 10, withPad: " ", startingAt: 0)
              + String(format: "%4d", v))
    }

    print("\nreplies available per letter (whole atlas / famous only)")
    for letter in "abcdefghijklmnopqrstuvwxyz" {
        let all = atlas.replyCount(for: letter)
        let famous = atlas.replyCount(for: letter, minFame: 88)
        let bar = String(repeating: "▉", count: min(40, all / 4))
        print(String(format: "  %@  %4d / %3d  %@", String(letter), all, famous, bar))
    }
}

func cmdSim() {
    let games = intOption("games", 200)
    let baseSeed = UInt64(intOption("seed", 1))
    let verbose = flag("verbose")
    let kind = option("seats") ?? "mixed"
    let atlas = loadAtlas()

    var config = GameConfig()
    config.turnSeconds = doubleOption("turn", 30)
    config.lives = intOption("lives", 2)
    config.cardChance = doubleOption("cards", 0.4)
    config.forcedCards = flag("forced-cards")
    config.turnDecay = doubleOption("decay", 0)
    if flag("no-rescue") { config.deadLetterRescue = false }
    if let tiers = option("tiers") {
        config.cardTiers = Set(tiers.split(separator: ",").compactMap {
            CardTier(rawValue: String($0).trimmingCharacters(in: .whitespaces))
        })
    }

    func seats(for kind: String, seed: UInt64) -> [Simulator.Seat] {
        switch kind {
        case "bots":
            return [.bot("Ada", .hard), .bot("Bo", .medium), .bot("Cy", .easy)]
        case "humans":
            return [.human("Ann"), .human("Ben"), .human("Cal")]
        case "solo":
            return [.human("Solo")]
        case "duel":
            return [.human("You"), .bot("Ada", .hard)]
        case "big":
            return [.human("A"), .bot("B", .hard), .human("C"), .bot("D", .medium),
                    .human("E"), .bot("F", .easy), .human("G"), .bot("H", .hard)]
        default:
            // Vary the table between games so one shape cannot hide a bug.
            var rng = SeededRNG(seed: seed)
            let n = 2 + Int(rng.next() % 5)
            return (0..<n).map { i in
                if rng.next() % 2 == 0 {
                    let d = BotDifficulty.allCases[Int(rng.next() % 3)]
                    return .bot("Bot\(i)", d)
                }
                var profile = FuzzProfile()
                profile.minFame = [0, 60, 74, 88][Int(rng.next() % 4)]
                return .human("Hum\(i)", profile)
            }
        }
    }

    var totalViolations: [String] = []
    var totalMoves = 0, totalTurns = 0, totalRejections = 0
    var totalChallenges = 0, totalUpheld = 0, totalTimeouts = 0
    var totalCards = 0, totalMet = 0, totalPoints = 0, totalDead = 0
    var totalBets = 0, totalBetsWon = 0
    var longest = 0
    var winners: [String: Int] = [:]
    let started = Date()

    for g in 0..<games {
        let seed = baseSeed &+ UInt64(g)
        let result = Simulator.run(seats: seats(for: kind, seed: seed), config: config,
                                   seed: seed, atlas: atlas, recordTranscript: verbose)
        totalMoves += result.moves
        totalTurns += result.turns
        totalRejections += result.rejections
        totalChallenges += result.challenges
        totalUpheld += result.challengesUpheld
        totalTimeouts += result.timeouts
        totalCards += result.cardsDealt
        totalMet += result.cardsMet
        totalBets += result.wagersMade
        totalBetsWon += result.wagersWon
        totalPoints += result.points
        totalDead += result.deadLetters
        longest = max(longest, result.moves)
        winners[result.winnerName ?? "—", default: 0] += 1
        if !result.violations.isEmpty {
            totalViolations.append("game #\(g) seed \(seed): \(result.violations.joined(separator: "; "))")
            if verbose {
                for line in result.transcript.suffix(20) { print("    \(line)") }
            }
        }
        if verbose && g == 0 {
            print("--- transcript of game #0 ---")
            for line in result.transcript { print("  \(line)") }
            print("--- end ---\n")
        }
    }

    let elapsed = Date().timeIntervalSince(started)
    print("""
    simulated \(games) games in \(String(format: "%.2f", elapsed))s  \
    (\(String(format: "%.0f", Double(games) / max(elapsed, 0.001)))/s)
      seats        \(kind)
      moves        \(totalMoves) total, \(String(format: "%.1f", Double(totalMoves) / Double(games))) avg, \(longest) longest chain
      turns        \(totalTurns)
      rejections   \(totalRejections)   (junk that was refused cleanly)
      timeouts     \(totalTimeouts)
      challenges   \(totalChallenges), \(totalUpheld) upheld
      cards        \(totalCards) dealt, \(totalMet) met \
    (\(String(format: "%.0f%%", 100 * Double(totalMet) / Double(max(totalCards, 1)))))
      bets         \(totalBets) placed, \(totalBetsWon) won \
    (\(String(format: "%.0f%%", 100 * Double(totalBetsWon) / Double(max(totalBets, 1)))))
      points       \(totalPoints) total, \
    \(String(format: "%.2f", Double(totalPoints) / Double(max(totalMoves, 1)))) a move
      dead letters \(totalDead)
    """)
    let ranking = winners.sorted { $0.value > $1.value }
        .map { "\($0.key)×\($0.value)" }.joined(separator: "  ")
    print("  winners      \(ranking)")

    if totalViolations.isEmpty {
        print("\n  ✅ no invariant violations")
    } else {
        print("\n  ❌ \(totalViolations.count) games broke an invariant:")
        for v in totalViolations.prefix(20) { print("     \(v)") }
        exit(1)
    }
}

func cmdSoak() {
    let seconds = doubleOption("seconds", 30)
    let threads = intOption("threads", 8)
    let atlas = loadAtlas()
    print("soaking \(threads) threads for \(Int(seconds))s…")

    var config = GameConfig()
    config.turnSeconds = 5
    let game = Game(atlas: atlas, config: config)
    for i in 0..<6 {
        game.addPlayer(Player(id: "p\(i)", name: "P\(i)",
                              isBot: i % 2 == 0, difficulty: .hard, lives: 99))
    }
    let start = Date()
    game.start(now: 0)

    let counter = Counter()
    let group = DispatchGroup()
    for t in 0..<threads {
        DispatchQueue.global().async(group: group) {
            var rng = SeededRNG(seed: UInt64(t) &* 7919 &+ 13)
            while Date().timeIntervalSince(start) < seconds {
                let now = Date().timeIntervalSince(start)
                switch rng.next() % 6 {
                case 0:
                    _ = game.tick(now: now)
                case 1:
                    _ = game.view(now: now)
                case 2:
                    let letter = game.requiredLetter
                    let options = atlas.candidates(startingWith: letter,
                                                   excluding: Set(game.moves.map(\.placeID)))
                    if let pick = options.randomElement(using: &rng),
                       let id = game.currentPlayerID {
                        _ = game.submit(playerID: id, text: pick.text, now: now)
                    }
                case 3:
                    if let id = game.currentPlayerID {
                        _ = game.submit(playerID: id, text: "zzzz\(rng.next())", now: now)
                    }
                case 4:
                    if let id = game.currentPlayerID {
                        let text = "\(game.requiredLetter)qzville"
                        if case .success(let p) = game.beginChallenge(playerID: id, text: text,
                                                                      now: now) {
                            _ = game.resolveChallenge(
                                id: p.id,
                                result: VerificationResult(accepted: rng.next() % 2 == 0,
                                                           resolvedName: text, kind: "city"),
                                now: now)
                        }
                    }
                default:
                    game.setConnected(id: "p\(rng.next() % 6)", rng.next() % 2 == 0)
                }
                counter.bump()
            }
        }
    }
    group.wait()

    let now = Date().timeIntervalSince(start)
    let problems = Invariants.check(game, now: now)
    print("  \(counter.value) operations across \(threads) threads")
    print("  phase \(game.phase), \(game.moves.count) moves, atlas \(atlas.placeCount) places")
    if problems.isEmpty {
        print("\n  ✅ state consistent after concurrent hammering")
    } else {
        print("\n  ❌ \(problems.count) problems:")
        for p in problems.prefix(20) { print("     \(p)") }
        exit(1)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

func cmdVerify() {
    let name = args.dropFirst().filter { !$0.hasPrefix("--") }.joined(separator: " ")
    guard !name.isEmpty else { print("usage: atlas verify <place name>"); exit(2) }

    let atlas = loadAtlas()
    if let s = atlas.surface(matching: name), let p = atlas.place(s.placeID) {
        print("already in the atlas: \(p.name) (\(p.kind), fame \(p.fame))")
        if !p.blurb.isEmpty { print("  \(p.name) is \(p.blurb).") }
        if !p.aliases.isEmpty { print("  also accepts: \(p.aliases.joined(separator: ", "))") }
        return
    }
    print("not in the atlas — asking Wikipedia…")
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox()
    WikipediaVerifier().verify(name) { box.value = $0; semaphore.signal() }
    guard semaphore.wait(timeout: .now() + 20) == .success, let r = box.value else {
        print("  ⏱ lookup timed out")
        exit(1)
    }
    print(r.accepted ? "  ✅ accepted as \(r.resolvedName) (\(r.kind))" : "  ❌ rejected")
    if !r.reason.isEmpty { print("     \(r.reason)") }
    if !r.sourceURL.isEmpty { print("     \(r.sourceURL)") }
}

final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: VerificationResult?
    var value: VerificationResult? {
        get { lock.lock(); defer { lock.unlock() }; return _v }
        set { lock.lock(); _v = newValue; lock.unlock() }
    }
}

func cmdPlay() {
    let atlas = loadAtlas()
    // The table comes first so that --turn and --lives still override it, the
    // same way an explicit setting beats the mode on the phone.
    let mode = option("mode").flatMap { TableMode(rawValue: $0) } ?? .cards
    var config = mode.config
    config.turnSeconds = doubleOption("turn", config.turnSeconds)
    config.lives = intOption("lives", config.lives)
    config.minimumTurnSeconds = min(config.minimumTurnSeconds, config.turnSeconds)
    let difficulty = BotDifficulty(rawValue: option("difficulty") ?? "medium") ?? .medium

    let game = Game(atlas: atlas, config: config, seed: UInt64(Date().timeIntervalSince1970))
    // The log talks about players in the third person — "Ada draws a card" — so
    // a player called "You" reads as broken English.  Borrow the login name.
    let me = option("name") ?? NSUserName().capitalized
    game.addPlayer(Player(id: "you", name: me.isEmpty ? "Player" : me))
    game.addPlayer(Player(id: "bot", name: "Ada", isBot: true, difficulty: difficulty))

    let start = Date()
    func now() -> Double { Date().timeIntervalSince(start) }
    game.start(now: now())

    print("\nAtlas — you versus Ada (\(difficulty.rawValue)), at the \(mode.title.lowercased()) "
          + "table. \(Int(config.turnSeconds))s a turn, "
          + "\(config.lives) \(config.lives == 1 ? "life" : "lives").")
    print("Type a place, `?` for a hint, `$` to bet a life on a hard card, "
          + "or `!name` to challenge a name the atlas does not know.\n")

    var lastSeq = 0
    func drain() {
        for entry in game.log where entry.seq > lastSeq {
            lastSeq = entry.seq
            print("  · \(entry.text)")
        }
    }
    drain()

    let stdinQueue = DispatchQueue(label: "stdin")
    let lineBox = LineBox()
    stdinQueue.async {
        while let line = readLine(strippingNewline: true) { lineBox.push(line) }
        lineBox.close()
    }

    var lastPrompt = ""
    while game.phase == .playing {
        _ = game.tick(now: now())
        drain()
        guard game.phase == .playing else { break }

        if game.currentPlayerID == "you" {
            let left = Int(game.timeLeft(now: now()))
            // The card rides in the prompt rather than the log: it is a
            // condition on the answer being typed, so it belongs where the
            // typing happens.
            // `!` for a card you must obey, `$` for one you bet a life on.
            let mark = game.wagerInPlay ? "$" : (game.config.forcedCards ? "!" : "")
            let card = game.card.map { " · \($0.demand)\(mark)" } ?? ""
            // The loop polls four times a second but the prompt only changes
            // once, and a redraw that is not a redraw is just noise off a TTY.
            let prompt = "  [\(String(game.requiredLetter).uppercased())] \(left)s\(card) > "
            if prompt != lastPrompt {
                lastPrompt = prompt
                print("\r" + prompt, terminator: "")
                fflush(stdout)
            }
            if let line = lineBox.pop(timeout: 0.25) {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text == "?" {
                    print("     try: \(game.hints(limit: 6, now: now()).joined(separator: ", "))")
                } else if text == "$" {
                    switch game.wager(playerID: "you", now: now()) {
                    case .success(let card):
                        print("     a life on it: the place must \(card.demand) "
                              + "(×\(card.multiplier) and a life if it does)")
                        lastPrompt = ""
                    case .failure(let reason):
                        print("     ✗ \(reason.message)")
                    }
                } else if text.hasPrefix("!") {
                    let name = String(text.dropFirst())
                    if case .success(let pending) = game.beginChallenge(playerID: "you",
                                                                        text: name, now: now()) {
                        print("     checking \(name) online…")
                        let sem = DispatchSemaphore(value: 0)
                        let box = ResultBox()
                        WikipediaVerifier().verify(name) { box.value = $0; sem.signal() }
                        _ = sem.wait(timeout: .now() + 15)
                        let r = box.value ?? VerificationResult(accepted: false, reason: "timed out")
                        _ = game.resolveChallenge(id: pending.id, result: r, now: now())
                    } else {
                        print("     cannot challenge that.")
                    }
                } else if !text.isEmpty {
                    if case .rejected(let reason) = game.submit(playerID: "you", text: text,
                                                                now: now()) {
                        print("     ✗ \(reason.message)"
                              + (reason.isChallengeable ? "  (try !\(text) to challenge)" : ""))
                    }
                }
                drain()
            }
        } else {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    _ = game.tick(now: now())
    drain()
    print("\n  chain of \(game.moves.count): \(game.moves.map(\.text).joined(separator: " → "))")
    for player in game.players.sorted(by: { $0.score > $1.score }) {
        print("  \(player.name): \(player.score) points from \(player.placesPlayed) places, "
              + "\(player.cardsMet) with a card")
    }
    exit(0)
}

final class LineBox: @unchecked Sendable {
    private let lock = NSCondition()
    private var lines: [String] = []
    private var closed = false

    func push(_ line: String) { lock.lock(); lines.append(line); lock.signal(); lock.unlock() }
    func close() { lock.lock(); closed = true; lock.broadcast(); lock.unlock() }

    /// Waits the full timeout even after stdin has closed: returning at once
    /// would turn the caller's poll loop into a spin, which is exactly what
    /// happens when the game is driven from a pipe rather than a terminal.
    func pop(timeout: TimeInterval) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if lines.isEmpty { _ = lock.wait(until: Date().addingTimeInterval(timeout)) }
        return lines.isEmpty ? nil : lines.removeFirst()
    }
}

func cmdServe() {
    // A hosting platform hands the port to the process in the environment and
    // routes to whatever it said — a hard-coded 8080 gets the container killed
    // for never answering.  An explicit --port still wins, for a laptop.
    let assigned = ProcessInfo.processInfo.environment["PORT"].flatMap(Int.init)
    let port = UInt16(intOption("port", assigned ?? 8080))
    let host = option("host") ?? "0.0.0.0"
    let verifier: PlaceVerifier = flag("offline")
        ? StubVerifier(defaultResult: VerificationResult(accepted: false,
                                                          reason: "server is in offline mode"))
        : WikipediaVerifier()
    let atlas = loadAtlas()
    let library = loadMedia()
    let server = AtlasServer(atlas: atlas, verifier: verifier,
                             learnedFile: AtlasPaths.learnedFile,
                             media: library)
    do {
        try server.start(host: host, port: port)
    } catch {
        FileHandle.standardError.write(Data("failed to start: \(error)\n".utf8))
        exit(1)
    }

    // The pictures fill themselves in while people play.  Slowly and last:
    // nothing in the game waits for it, so it gets whatever is left over.
    // `--no-harvest` is for the test sweep, which wants the live challenge
    // lookup but not five thousand background requests underneath it.
    if !flag("offline") && !flag("no-harvest") {
        let harvester = MediaHarvester(atlas: atlas, library: library,
                                       source: WikipediaMedia(),
                                       interval: doubleOption("media-interval", 1.0))
        harvester.start()
        let (_, left) = harvester.progress
        if left > 0 {
            print("  pictures     \(library.count) of \(atlas.placeCount) looked up, "
                  + "\(left) to go (one a second, in the background)")
        }
    }
    dispatchMain()
}

/// The shipped file first, then whatever this machine has learned since.
func loadMedia() -> MediaLibrary {
    let library = MediaLibrary(overlayFile: AtlasPaths.mediaFile)
    if let shipped = AtlasPaths.shippedMediaFile { library.load(shipped) }
    library.load(AtlasPaths.mediaFile)
    return library
}

/// Fills the picture-and-fact file without starting a server, so a deployment
/// can ship one that is already full instead of making its first players wait.
func cmdMedia() {
    let atlas = loadAtlas()
    let library = loadMedia()
    if flag("status") || args.contains("status") {
        print("""
            media   \(library.count) of \(atlas.placeCount) places looked up
                    \(library.withPictures) with a picture, \(library.withFacts) with a fact
                    \(AtlasPaths.mediaFile.path)
            """)
        return
    }

    let limit = intOption("limit", 0)
    let harvester = MediaHarvester(atlas: atlas, library: library,
                                   source: WikipediaMedia(),
                                   interval: doubleOption("interval", 0.4))
    harvester.refillQueue()
    let target = limit > 0 ? min(limit, harvester.progress.left) : harvester.progress.left
    guard target > 0 else { print("nothing left to look up"); return }
    print("looking up \(target) places…")

    harvester.start()
    var lastPrinted = -1
    while harvester.progress.done < target {
        let done = harvester.progress.done
        if done / 50 != lastPrinted / 50 {
            lastPrinted = done
            print("  \(done)/\(target)  \(library.withPictures) pictures, "
                  + "\(library.withFacts) facts")
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    harvester.stop()
    library.save(force: true)
    print("done: \(library.count) looked up, \(library.withPictures) pictures, "
          + "\(library.withFacts) facts -> \(AtlasPaths.mediaFile.path)")
}

// MARK: - Dispatch

// `atlas media --help` used to start a five-thousand-request harvest: every
// command reads the flags it knows and ignores the rest, so asking one of them
// how it works ran it instead.  That is a bad trade in any command and a
// genuinely destructive one here, where two harvests writing the same file each
// save their whole copy over the other's.  Asking for help is now answered
// before anything is dispatched.
if args.count > 1, args.contains("--help") || args.contains("-h") {
    print(usage)
    exit(0)
}

switch args.first {
case "serve": cmdServe()
case "sim": cmdSim()
case "soak": cmdSoak()
case "verify": cmdVerify()
case "stats": cmdStats()
case "media": cmdMedia()
case "play": cmdPlay()
case "--help", "-h", "help", nil: print(usage)
default:
    print("unknown command: \(args[0])\n")
    print(usage)
    exit(2)
}
