import Foundation
import AtlasCore

/// The engine owns no timers: every entry point is handed the current time, so
/// these tests drive whole games in microseconds and are perfectly repeatable.
enum GameTests {

    /// A tiny hand-built atlas, so each test can reason about every legal move.
    /// Chain letters: sydney→y, yemen→n, norway→y, nepal→l, lima→a, angola→a.
    private static func tinyAtlas() -> Atlas {
        Atlas(places: [
            Place(name: "Sydney", kind: "city", fame: 95),
            Place(name: "Yemen", kind: "country", fame: 80),
            Place(name: "Norway", kind: "country", fame: 90),
            Place(name: "Nepal", kind: "country", fame: 85),
            Place(name: "Lima", kind: "capital", fame: 82),
            Place(name: "Angola", kind: "country", fame: 70),
            Place(name: "Mumbai", kind: "city", fame: 92, aliases: ["Bombay"]),
        ])
    }

    private static let opening = GameConfig(turnSeconds: 30, lives: 2, startLetter: "s")

    private static func makeGame(players: [String] = ["Ann", "Ben"],
                                 config: GameConfig = opening) -> Game {
        let game = Game(atlas: tinyAtlas(), config: config, seed: 42)
        for (i, name) in players.enumerated() {
            var p = Player(id: "p\(i)", name: name, lives: config.lives)
            p.connected = true
            game.addPlayer(p)
        }
        if !game.start(now: 0) { fail("the game refused to start") }
        return game
    }

    private static func reason(_ outcome: SubmitOutcome) -> RejectReason? {
        if case .rejected(let r) = outcome { return r }
        return nil
    }

    static func run() {
        Harness.suite("the lobby") {

            Harness.test("an empty table cannot start") {
                let game = Game(atlas: tinyAtlas(), config: GameConfig())
                expect(!game.start(now: 0))
                expectEqual(game.phase, .lobby)
            }

            Harness.test("a running game cannot be started again") {
                let game = makeGame()
                expect(!game.start(now: 1), "a second start would reset a live game")
            }

            Harness.test("a duplicate player id is refused") {
                let game = Game(atlas: tinyAtlas(), config: GameConfig())
                expect(game.addPlayer(Player(id: "p0", name: "Ann")))
                expect(!game.addPlayer(Player(id: "p0", name: "Impostor")))
                expectEqual(game.players.count, 1)
            }

            Harness.test("moves are refused before the game starts") {
                let game = Game(atlas: tinyAtlas(), config: GameConfig())
                game.addPlayer(Player(id: "p0", name: "Ann"))
                expectEqual(reason(game.submit(playerID: "p0", text: "Sydney", now: 0)),
                            .gameNotRunning)
            }
        }

        Harness.suite("the rules") {

            Harness.test("a valid move sets the next letter and passes the turn") {
                let game = makeGame()
                expectEqual(game.requiredLetter, "s")
                guard case .accepted(let move) = game.submit(playerID: "p0", text: "sydney",
                                                             now: 1) else {
                    return fail("Sydney was refused")
                }
                expectEqual(move.text, "Sydney", "the name should be tidied for display")
                expectEqual(game.requiredLetter, "y")
                expectEqual(game.currentPlayerID, "p1")
                expectEqual(game.usedCount, 1)
            }

            Harness.test("a wrong letter is refused, and says which was wanted") {
                let game = makeGame()
                expectEqual(reason(game.submit(playerID: "p0", text: "Norway", now: 1)),
                            .wrongLetter(expected: "s", got: "n"))
                expectEqual(game.currentPlayerID, "p0", "a refusal must not cost the turn")
            }

            Harness.test("out-of-turn moves are refused") {
                let game = makeGame()
                expectEqual(reason(game.submit(playerID: "p1", text: "Sydney", now: 1)),
                            .notYourTurn)
                expectEqual(reason(game.submit(playerID: "ghost", text: "Sydney", now: 1)),
                            .notYourTurn)
            }

            Harness.test("empty and too-short submissions are refused") {
                let game = makeGame()
                expectEqual(reason(game.submit(playerID: "p0", text: "   ", now: 1)), .empty)
                expectEqual(reason(game.submit(playerID: "p0", text: "🌍", now: 1)), .empty)
                expectEqual(reason(game.submit(playerID: "p0", text: "S", now: 1)), .tooShort)
            }

            Harness.test("unknown places are refused but marked challengeable") {
                let game = makeGame()
                guard let why = reason(game.submit(playerID: "p0", text: "Sqzlandia", now: 1))
                else { return fail("nonsense was accepted") }
                expectEqual(why, .notInAtlas)
                expect(why.isChallengeable)
            }

            Harness.test("places cannot repeat") {
                let game = makeGame()
                _ = game.submit(playerID: "p0", text: "Sydney", now: 1)     // s → y
                _ = game.submit(playerID: "p1", text: "Yemen", now: 2)      // y → n
                _ = game.submit(playerID: "p0", text: "Nepal", now: 3)      // n → l
                _ = game.submit(playerID: "p1", text: "Lima", now: 4)       // l → a
                _ = game.submit(playerID: "p0", text: "Angola", now: 5)     // a → a
                expectEqual(reason(game.submit(playerID: "p1", text: "angola", now: 6)),
                            .alreadyUsed(name: "Angola"))
            }

            Harness.test("an alias spends its canonical name too") {
                let bStart = GameConfig(turnSeconds: 30, lives: 2, startLetter: "b")
                let mStart = GameConfig(turnSeconds: 30, lives: 2, startLetter: "m")
                let game = makeGame(config: bStart)
                guard case .accepted(let move) = game.submit(playerID: "p0", text: "Bombay",
                                                             now: 1) else {
                    return fail("Bombay was refused")
                }
                expectEqual(move.text, "Bombay", "the chain shows what the player typed")
                expectEqual(game.requiredLetter, "y", "the chain follows the typed surface")

                let other = makeGame(config: mStart)
                _ = other.submit(playerID: "p0", text: "Mumbai", now: 1)    // m → i
                // Bombay is the same place, so it is spent even though the
                // other spelling was the one played.
                expectEqual(reason(other.submit(playerID: "p1", text: "Bombay", now: 2)),
                            .wrongLetter(expected: "i", got: "b"))
            }

            Harness.test("a fame floor rejects obscure places") {
                let config = GameConfig(turnSeconds: 30, lives: 2, startLetter: "a", minFame: 80)
                let game = makeGame(config: config)
                guard let why = reason(game.submit(playerID: "p0", text: "Angola", now: 1))
                else { return fail("a fame-70 place slipped past a fame-80 floor") }
                expectEqual(why, .tooObscure(name: "Angola", fame: 70))
            }
        }

        Harness.suite("the clock") {

            Harness.test("counts down, and timing out costs a life") {
                let game = makeGame()
                expectClose(game.timeLeft(now: 0), 30)
                expectClose(game.timeLeft(now: 10), 20)

                expect(!game.tick(now: 29), "the deadline had not passed yet")
                expect(game.tick(now: 31), "the deadline passed and nothing happened")

                expectEqual(game.players[0].lives, 1)
                expect(!game.players[0].eliminated)
                expectEqual(game.currentPlayerID, "p1")
                expectClose(game.timeLeft(now: 31), 30, "a fresh turn gets a fresh clock")
            }

            Harness.test("never shows negative time") {
                expectClose(makeGame().timeLeft(now: 10_000), 0)
            }

            Harness.test("one late tick catches up on every missed deadline") {
                // The server's timer can be starved — laptop lid closed, process
                // suspended — and must then resolve every deadline it slept
                // through, not just the first.
                let config = GameConfig(turnSeconds: 5, lives: 1, startLetter: "s")
                let game = makeGame(config: config)
                expect(game.tick(now: 500))
                expectEqual(game.phase, .finished)
            }

            Harness.test("losing every life ends the game") {
                let config = GameConfig(turnSeconds: 10, lives: 1, startLetter: "s")
                let game = makeGame(config: config)
                _ = game.tick(now: 11)
                expect(game.players[0].eliminated)
                expectEqual(game.phase, .finished)
                expectEqual(game.winnerID, "p1")
            }

            Harness.test("the turn order skips eliminated players") {
                let config = GameConfig(turnSeconds: 10, lives: 1, startLetter: "s")
                let game = makeGame(players: ["Ann", "Ben", "Cal"], config: config)
                _ = game.tick(now: 11)                                      // Ann is out
                expectEqual(game.currentPlayerID, "p1")
                _ = game.submit(playerID: "p1", text: "Sydney", now: 12)     // s → y
                expectEqual(game.currentPlayerID, "p2", "Ann must be skipped")
                _ = game.submit(playerID: "p2", text: "Yemen", now: 13)      // y → n
                expectEqual(game.currentPlayerID, "p1", "and skipped on the wrap too")
            }

            Harness.test("a solo game ends when the lone player is out") {
                let config = GameConfig(turnSeconds: 10, lives: 1, startLetter: "s")
                let game = makeGame(players: ["Ann"], config: config)
                _ = game.submit(playerID: "p0", text: "Sydney", now: 1)
                expectEqual(game.currentPlayerID, "p0", "solo play keeps handing you the turn")
                _ = game.tick(now: 12)
                expectEqual(game.phase, .finished)
                expectNil(game.winnerID, "there is nobody to beat in solo mode")
            }

            Harness.test("the next wakeup tracks the deadline") {
                let game = makeGame()
                guard let wake = game.nextWakeup(now: 0) else {
                    return fail("no wakeup was scheduled")
                }
                expectClose(wake, 30)

                let config = GameConfig(turnSeconds: 10, lives: 1, startLetter: "s")
                let over = makeGame(players: ["Ann"], config: config)
                _ = over.tick(now: 11)
                expectNil(over.nextWakeup(now: 11), "a finished game needs no more ticks")
            }
        }

        Harness.suite("leaving") {

            Harness.test("removing the current player passes the turn on") {
                let game = makeGame(players: ["Ann", "Ben", "Cal"])
                expectEqual(game.currentPlayerID, "p0")
                expect(game.removePlayer(id: "p0", now: 1))
                expectNotEqual(game.currentPlayerID, "p0")
                expectEqual(game.phase, .playing)
                guard let current = game.currentPlayerID else {
                    return fail("nobody holds the turn")
                }
                if case .rejected(let why) = game.submit(playerID: current, text: "Sydney",
                                                         now: 2) {
                    fail("the surviving player could not move: \(why)")
                }
            }

            Harness.test("the game ends when everyone but one leaves") {
                let game = makeGame()
                expect(game.removePlayer(id: "p1", now: 1))
                expectEqual(game.phase, .finished)
                expectEqual(game.winnerID, "p0")
            }
        }

        Harness.suite("snapshots and hints") {

            Harness.test("the view matches the engine state") {
                let game = makeGame()
                _ = game.submit(playerID: "p0", text: "Sydney", now: 1)
                let view = game.view(now: 2)
                expectEqual(view.phase, "playing")
                expectEqual(view.requiredLetter, "y")
                expectEqual(view.currentPlayerID, "p1")
                expectEqual(view.chainLength, 1)
                expectEqual(view.moves.last?.text, "Sydney")
                expectClose(view.timeLeft, 29, "the turn began a second ago")
                expect(!view.paused)
                expectNil(view.pending)
            }

            Harness.test("the version only rises on real changes") {
                let game = makeGame()
                let before = game.version
                _ = game.view(now: 1)
                expectEqual(game.version, before, "reading the state must not dirty it")
                _ = game.submit(playerID: "p0", text: "Sydney", now: 1)
                expectGreater(game.version, before)
            }

            Harness.test("hints are always legal moves") {
                let game = makeGame()
                _ = game.submit(playerID: "p0", text: "Sydney", now: 1)   // now needs Y
                let hints = game.hints(limit: 5, now: 2)
                expect(!hints.isEmpty)
                for hint in hints {
                    expectEqual(Normalize.firstLetter(hint), "y",
                                "\(hint) does not fit the chain")
                    expectNotEqual(Normalize.key(hint), Normalize.key("Sydney"))
                }
            }

            Harness.test("hints dry up when nothing is left") {
                // Yemen is the only Y; once it is gone there is nothing to offer.
                let game = makeGame()
                _ = game.submit(playerID: "p0", text: "Sydney", now: 1)   // s → y
                _ = game.submit(playerID: "p1", text: "Yemen", now: 2)    // y → n
                _ = game.submit(playerID: "p0", text: "Norway", now: 3)   // n → y
                expectEqual(game.requiredLetter, "y")
                expect(game.hints(limit: 5, now: 4).isEmpty)
            }
        }
    }
}
