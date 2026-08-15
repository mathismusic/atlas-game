import Foundation
import AtlasCore

enum BotTests {

    private static var atlas: Atlas { AtlasTests.shared }

    /// Plays `rounds` single turns on `letter` and reports the fraction that
    /// produced a move.  Every bot has a deliberate blunder rate, so behaviour
    /// is only meaningful in aggregate.
    private static func hitRate(_ difficulty: BotDifficulty, letter: Character,
                                rounds: Int = 400, used: Set<Int> = []) -> Double {
        let bot = Bot(atlas: atlas, difficulty: difficulty)
        var rng = SeededRNG(seed: 99)
        var found = 0
        for _ in 0..<rounds {
            if bot.choose(letter: letter, used: used, minFame: 0, rng: &rng) != nil { found += 1 }
        }
        return Double(found) / Double(rounds)
    }

    static func run() {
        Harness.suite("the computer players") {

            Harness.test("only ever play legal moves") {
                for difficulty in BotDifficulty.allCases {
                    let bot = Bot(atlas: atlas, difficulty: difficulty)
                    var rng = SeededRNG(seed: 4)
                    var used = Set<Int>()
                    var letter: Character = "s"
                    for turn in 0..<300 {
                        guard let pick = bot.choose(letter: letter, used: used, minFame: 0,
                                                    rng: &rng) else { continue }
                        guard let surface = atlas.surface(matching: pick) else {
                            fail("\(difficulty) played \(pick), which is not in the atlas")
                            break
                        }
                        expectEqual(surface.first, letter,
                                    "\(difficulty) broke the chain on turn \(turn) with \(pick)")
                        expect(!used.contains(surface.placeID),
                               "\(difficulty) repeated \(pick) on turn \(turn)")
                        used.insert(surface.placeID)
                        letter = surface.last
                    }
                }
            }

            Harness.test("respect the table's fame floor, however hard they are") {
                // The floor is the table's rule, not a difficulty setting.
                for difficulty in BotDifficulty.allCases {
                    let bot = Bot(atlas: atlas, difficulty: difficulty)
                    var rng = SeededRNG(seed: 11)
                    for letter in "abcdefghijklmnopqrstuvwxyz" {
                        for _ in 0..<20 {
                            guard let pick = bot.choose(letter: letter, used: [], minFame: 85,
                                                        rng: &rng),
                                  let surface = atlas.surface(matching: pick) else { continue }
                            expectAtLeast(surface.fame, 85,
                                          "\(difficulty) played \(pick) below the floor")
                        }
                    }
                }
            }

            Harness.test("answer starved letters at least sometimes") {
                // X, Q, O, Y and Z have almost nothing famous starting them.  A
                // bot pinned to its fame tier would concede on those letters
                // every single time, which reads as a broken opponent rather
                // than an easy one.
                for letter in "xqoyz" {
                    expectGreater(hitRate(.easy, letter: letter), 0.2,
                                  "an easy bot almost always gives up on \(letter)")
                    expectGreater(hitRate(.medium, letter: letter), 0.5,
                                  "a medium bot almost always gives up on \(letter)")
                    expectGreater(hitRate(.hard, letter: letter), 0.95,
                                  "a hard bot gave up on \(letter)")
                }
            }

            Harness.test("give up only when there is genuinely nothing left") {
                let allQ = Set(atlas.candidates(startingWith: "q", minFame: 0,
                                                excluding: []).map(\.placeID))
                for difficulty in BotDifficulty.allCases {
                    expectEqual(hitRate(difficulty, letter: "q", rounds: 50, used: allQ), 0,
                                "\(difficulty) invented a move out of nothing")
                }
            }

            Harness.test("sound less obvious the harder they are") {
                func averageFame(_ difficulty: BotDifficulty) -> Double {
                    let bot = Bot(atlas: atlas, difficulty: difficulty)
                    var rng = SeededRNG(seed: 3)
                    var total = 0.0, count = 0.0
                    for letter in "abcdefgmnprst" {
                        for _ in 0..<40 {
                            guard let pick = bot.choose(letter: letter, used: [], minFame: 0,
                                                        rng: &rng),
                                  let surface = atlas.surface(matching: pick) else { continue }
                            total += Double(surface.fame); count += 1
                        }
                    }
                    return count == 0 ? 0 : total / count
                }
                expectGreater(averageFame(.easy), averageFame(.medium))
                expectGreater(averageFame(.medium), averageFame(.hard))
            }

            Harness.test("hunt for the thinnest reply when playing hard") {
                let hard = Bot(atlas: atlas, difficulty: .hard)
                let easy = Bot(atlas: atlas, difficulty: .easy)
                var hardRNG = SeededRNG(seed: 5), easyRNG = SeededRNG(seed: 5)

                func averageReplies(_ bot: Bot, _ rng: inout SeededRNG) -> Double {
                    var total = 0.0, count = 0.0
                    for letter in "abcdefgmnprst" {
                        for _ in 0..<10 {
                            guard let pick = bot.choose(letter: letter, used: [], minFame: 0,
                                                        rng: &rng),
                                  let surface = atlas.surface(matching: pick) else { continue }
                            total += Double(atlas.replyCount(for: surface.last, minFame: 0,
                                                             excluding: [surface.placeID]))
                            count += 1
                        }
                    }
                    return count == 0 ? 0 : total / count
                }
                expectLess(averageReplies(hard, &hardRNG), averageReplies(easy, &easyRNG),
                           "the hard bot is not playing the letter economy")
            }

            Harness.test("play the same game from the same seed") {
                func transcript(seed: UInt64) -> [String] {
                    let bot = Bot(atlas: atlas, difficulty: .medium)
                    var rng = SeededRNG(seed: seed)
                    var used = Set<Int>(), letter: Character = "s", played: [String] = []
                    for _ in 0..<60 {
                        guard let pick = bot.choose(letter: letter, used: used, minFame: 0,
                                                    rng: &rng),
                              let surface = atlas.surface(matching: pick) else { break }
                        played.append(pick); used.insert(surface.placeID); letter = surface.last
                    }
                    return played
                }
                expectEqual(transcript(seed: 1234), transcript(seed: 1234))
                expectNotEqual(transcript(seed: 1234), transcript(seed: 5678))
            }
        }
    }
}
