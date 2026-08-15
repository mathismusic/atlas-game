import Foundation
import AtlasCore

/// Whole games played on a virtual clock.  These are the tests that catch rule
/// interactions nobody thought to write a unit test for: the simulator audits
/// every invariant after every single state change.
enum SimulationTests {

    private static let basePlaces: [Place] = AtlasTests.shared.allPlaces

    /// Upheld challenges teach the atlas, so a shared one would make results
    /// depend on which tests ran first.  Every game gets its own copy.
    private static func freshAtlas() -> Atlas { Atlas(places: basePlaces) }

    private static let standard = GameConfig(turnSeconds: 30, lives: 2)

    private static func run(_ seats: [Simulator.Seat], seed: UInt64,
                            config: GameConfig = standard) -> SimResult {
        Simulator.run(seats: seats, config: config, seed: seed, atlas: freshAtlas())
    }

    private static func assertClean(_ result: SimResult, _ label: String) {
        expect(result.violations.isEmpty,
               "\(label): \(result.violations.prefix(3).joined(separator: " | "))")
        expectGreater(result.turns, 0, "\(label) never got going")
    }

    static func run() {
        Harness.suite("simulated games") {

            Harness.test("a table of computer players holds up") {
                for seed in UInt64(1)...20 {
                    let result = run([.bot("Easy", .easy), .bot("Medium", .medium),
                                      .bot("Hard", .hard)], seed: seed)
                    assertClean(result, "bots seed \(seed)")
                    expectNotNil(result.winnerName, "bots seed \(seed) ended with no winner")
                }
            }

            Harness.test("a table of fuzzing humans holds up") {
                // These "players" type junk, stall, challenge nonsense and
                // occasionally play well — everything a phone can send, in
                // every order.
                for seed in UInt64(1)...20 {
                    let result = run([.human("Ann"), .human("Ben"), .human("Cal")], seed: seed)
                    assertClean(result, "humans seed \(seed)")
                    expectGreater(result.rejections, 0, "the fuzzer stopped typing junk")
                }
            }

            Harness.test("mixed tables hold up") {
                for seed in UInt64(1)...20 {
                    assertClean(run([.human("Ann"), .bot("Ada", .hard),
                                     .human("Ben"), .bot("Bo", .easy)], seed: seed),
                                "mixed seed \(seed)")
                }
            }

            Harness.test("solo play holds up") {
                for seed in UInt64(1)...10 {
                    let result = run([.human("Ann")], seed: seed,
                                     config: GameConfig(turnSeconds: 30, lives: 1))
                    assertClean(result, "solo seed \(seed)")
                    expectNil(result.winnerName, "there is nobody to beat in solo mode")
                }
            }

            Harness.test("a big table holds up") {
                let seats = (0..<8).map { i in
                    i.isMultiple(of: 2)
                        ? Simulator.Seat.human("H\(i)")
                        : Simulator.Seat.bot("B\(i)", BotDifficulty.allCases[i % 3])
                }
                for seed in UInt64(1)...5 {
                    assertClean(run(seats, seed: seed), "big seed \(seed)")
                }
            }

            Harness.test("the harshest settings hold up") {
                // One life, a three-second clock and a high fame floor: the
                // shortest, most timeout-heavy games the config allows.
                let config = GameConfig(turnSeconds: 3, lives: 1, startLetter: nil, minFame: 85,
                                        allowChallenge: true, challengesPerPlayer: 1)
                for seed in UInt64(1)...20 {
                    assertClean(run([.human("Ann"), .bot("Ada", .easy)], seed: seed,
                                    config: config), "harsh seed \(seed)")
                }
            }

            Harness.test("every game terminates") {
                // A game that neither ends nor advances hangs the room forever.
                for seed in UInt64(1)...10 {
                    let result = run([.bot("A", .hard), .bot("B", .hard)], seed: seed)
                    expectLess(result.virtualSeconds, Simulator.defaultVirtualLimit,
                               "seed \(seed) ran to the virtual clock limit")
                }
            }

            Harness.test("the same seed replays the same game") {
                let seats: [Simulator.Seat] = [.human("Ann"), .bot("Ada", .medium)]
                let a = Simulator.run(seats: seats, seed: 777, atlas: freshAtlas(),
                                      recordTranscript: true)
                let b = Simulator.run(seats: seats, seed: 777, atlas: freshAtlas(),
                                      recordTranscript: true)
                expectEqual(a.transcript, b.transcript, "the same seed diverged")
                expectEqual(a.moves, b.moves)
            }

            Harness.test("challenges get exercised, and some of them stick") {
                var challenges = 0, upheld = 0
                for seed in UInt64(1)...20 {
                    let result = run([.human("Ann"), .human("Ben")], seed: seed)
                    challenges += result.challenges
                    upheld += result.challengesUpheld
                }
                expectGreater(challenges, 0, "no challenge was ever raised")
                expectGreater(upheld, 0, "no challenge was ever upheld")
                expectLess(upheld, challenges, "every challenge succeeded — nothing is fuzzing")
            }
        }
    }
}
