import Foundation
import AtlasCore

/// A challenge is a player insisting a place is real.  The engine pauses the
/// clock, someone else does the web lookup, and the verdict comes back here.
enum ChallengeTests {

    private static let opening = GameConfig(turnSeconds: 30, lives: 2, startLetter: "s")

    private static func makeGame(config: GameConfig = opening) -> Game {
        let atlas = Atlas(places: [
            Place(name: "Sydney", kind: "city", fame: 95),
            Place(name: "Yemen", kind: "country", fame: 80),
        ])
        let game = Game(atlas: atlas, config: config, seed: 7)
        for (i, name) in ["Ann", "Ben"].enumerated() {
            game.addPlayer(Player(id: "p\(i)", name: name, lives: config.lives))
        }
        if !game.start(now: 0) { fail("the game refused to start") }
        return game
    }

    private static func upheld(_ name: String) -> VerificationResult {
        VerificationResult(accepted: true, resolvedName: name, kind: "city",
                           summary: "a town", sourceURL: "https://example.org",
                           reason: "confirmed")
    }

    private static let refused = VerificationResult(accepted: false, reason: "not a place")

    private static func begin(_ game: Game, _ text: String, at now: Double,
                              player: String = "p0") -> PendingChallenge? {
        if case .success(let pending) = game.beginChallenge(playerID: player, text: text,
                                                            now: now) {
            return pending
        }
        return nil
    }

    static func run() {
        Harness.suite("raising a challenge") {

            Harness.test("challenging an unknown name pauses the clock") {
                let game = makeGame()
                _ = game.submit(playerID: "p0", text: "Sqzlandia", now: 5)
                guard let pending = begin(game, "Sqzlandia", at: 5) else {
                    return fail("the challenge was refused")
                }
                expectEqual(pending.text, "Sqzlandia")
                expectEqual(game.pendingChallenge, pending)
                // 25 seconds were left; they must still be there however long
                // the lookup takes, or a slow network costs you the round.
                expectClose(game.timeLeft(now: 5), 25)
                expectClose(game.timeLeft(now: 14), 25)
                expect(game.view(now: 14).paused)
            }

            Harness.test("moves are frozen while a challenge is outstanding") {
                let game = makeGame()
                _ = begin(game, "Sqzlandia", at: 5)
                guard case .rejected(let why) = game.submit(playerID: "p0", text: "Sydney",
                                                            now: 6) else {
                    return fail("a move slipped through mid-challenge")
                }
                expectEqual(why, .challengeInFlight)
                expectNil(begin(game, "Sqzlandia2", at: 6), "two challenges ran at once")
            }

            Harness.test("a move that is simply illegal cannot be challenged") {
                let game = makeGame()
                // Right place, wrong letter: no web search makes it legal.
                expectNil(begin(game, "Yemen", at: 1),
                          "a wrong-letter move went to a web lookup")
                // And a perfectly legal move has nothing to challenge.
                expectNil(begin(game, "Sydney", at: 1), "a legal move started a lookup")
                expectNil(game.pendingChallenge)
            }

            Harness.test("by default nobody runs out of challenges") {
                // The atlas being incomplete is not the player's fault, so the
                // ordinary table does not ration the fix.
                let config = GameConfig(turnSeconds: 30, lives: 9, startLetter: "s")
                let game = makeGame(config: config)
                for attempt in 1...12 {
                    guard let pending = begin(game, "Sqzlandia", at: 1) else {
                        return fail("challenge \(attempt) was refused")
                    }
                    _ = game.resolveChallenge(id: pending.id, result: refused, now: 2)
                }
                expect(game.challengesRemaining(for: "p0") > 0, "the count ran down anyway")
            }

            Harness.test("a table may still ration them") {
                let config = GameConfig(turnSeconds: 30, lives: 9, startLetter: "s",
                                        challengesPerPlayer: 2)
                let game = makeGame(config: config)
                for attempt in 1...2 {
                    guard let pending = begin(game, "Sqzlandia", at: 1) else {
                        return fail("challenge \(attempt) was refused")
                    }
                    _ = game.resolveChallenge(id: pending.id, result: refused, now: 2)
                    expectEqual(game.challengesRemaining(for: "p0"), 2 - attempt)
                }
                expectNil(begin(game, "Sqzlandia", at: 3), "the ration was ignored")
            }

            Harness.test("challenges can be turned off for the table") {
                let config = GameConfig(turnSeconds: 30, lives: 2, startLetter: "s",
                                        allowChallenge: false)
                let game = makeGame(config: config)
                expectNil(begin(game, "Sqzlandia", at: 1),
                          "challenges were disabled but one started")
            }
        }

        Harness.suite("resolving a challenge") {

            Harness.test("an upheld challenge plays the move and teaches the atlas") {
                let game = makeGame()
                guard let pending = begin(game, "Sqzlandia", at: 5) else {
                    return fail("the challenge was refused")
                }
                guard case .accepted(let move)? = game.resolveChallenge(
                    id: pending.id, result: upheld("Sqzlandia"), now: 9) else {
                    return fail("an upheld challenge did not play the move")
                }
                expectEqual(move.text, "Sqzlandia")
                expect(move.viaChallenge)
                expectEqual(game.requiredLetter, "a", "the chain follows the new place")
                expectEqual(game.currentPlayerID, "p1")
                expectNil(game.pendingChallenge)
                expect(!game.view(now: 9).paused)

                // The atlas keeps it, so nobody has to challenge for it twice.
                expectNotNil(game.atlas.surface(matching: "sqzlandia"))
                expectEqual(game.atlas.learnedPlaces.map(\.name), ["Sqzlandia"])
            }

            Harness.test("a corrected spelling keeps both forms pointing at one place") {
                let game = makeGame()
                guard let pending = begin(game, "Srinagr", at: 1) else {
                    return fail("the challenge was refused")
                }
                _ = game.resolveChallenge(id: pending.id, result: upheld("Srinagar"), now: 2)

                // Wikipedia redirected the typo to the real article; both must
                // resolve to one place, or the typo becomes a second entry that
                // can be played all over again.
                let typo = game.atlas.surface(matching: "Srinagr")
                let real = game.atlas.surface(matching: "Srinagar")
                expectNotNil(typo)
                expectEqual(typo?.placeID, real?.placeID)
                expectEqual(game.atlas.place(typo?.placeID ?? -1)?.name, "Srinagar")
            }

            Harness.test("a refused challenge resumes the clock where it stopped") {
                let game = makeGame()
                guard let pending = begin(game, "Sqzlandia", at: 5) else {
                    return fail("the challenge was refused")
                }
                guard case .rejected? = game.resolveChallenge(id: pending.id, result: refused,
                                                              now: 11) else {
                    return fail("a bogus place was accepted")
                }
                expectEqual(game.currentPlayerID, "p0", "the player keeps their turn")
                expectClose(game.timeLeft(now: 11), 25)
                expectClose(game.timeLeft(now: 16), 20, "the clock is running again")
                expectNil(game.atlas.surface(matching: "Sqzlandia"))
            }

            Harness.test("a lookup that never returns times out") {
                let game = makeGame()
                guard let pending = begin(game, "Sqzlandia", at: 5) else {
                    return fail("the challenge was refused")
                }
                expect(!game.tick(now: 5 + Game.challengeTimeout - 1))
                expectNotNil(game.pendingChallenge)
                expect(game.tick(now: 5 + Game.challengeTimeout + 0.1))
                expectNil(game.pendingChallenge, "the game hung on a lookup that never returned")
                expectClose(game.timeLeft(now: 5 + Game.challengeTimeout + 0.1), 25)

                // A verdict arriving after the timeout must not be applied.
                expectNil(game.resolveChallenge(id: pending.id, result: upheld("Sqzlandia"),
                                                now: 30))
            }

            Harness.test("stale and unknown challenge ids are ignored") {
                let game = makeGame()
                expectNil(game.resolveChallenge(id: "not-a-challenge",
                                                result: upheld("Sqzlandia"), now: 1))
                guard let pending = begin(game, "Sqzlandia", at: 1) else {
                    return fail("the challenge was refused")
                }
                expectNil(game.resolveChallenge(id: pending.id + "x",
                                                result: upheld("Sqzlandia"), now: 2))
                expectNotNil(game.pendingChallenge,
                             "the real challenge was cancelled by a stray id")
            }

            Harness.test("an upheld challenge is re-checked before it is played") {
                // The verdict is yes, but the place resolves to one already in
                // the chain — it must be refused rather than played twice.
                let game = makeGame()
                _ = game.submit(playerID: "p0", text: "Sydney", now: 1)     // s → y
                _ = game.submit(playerID: "p1", text: "Yemen", now: 2)      // y → n
                guard let pending = begin(game, "Nsydney", at: 3) else {
                    return fail("the challenge was refused")
                }
                guard case .rejected? = game.resolveChallenge(id: pending.id,
                                                              result: upheld("Sydney"),
                                                              now: 4) else {
                    return fail("a place already in the chain was played a second time")
                }
                expectEqual(game.moves.count, 2)
            }

            Harness.test("the stub verifier answers what it was told") {
                let stub = StubVerifier()
                stub.stub("Zermatt", VerificationResult(accepted: true, resolvedName: "Zermatt"))
                expect(stub.result(for: "zermatt").accepted)
                expect(!stub.result(for: "Nowhereville").accepted)
            }

            Harness.test("the exact title wins when nothing has been read yet") {
                let hits = ["Zermatt Glacier Paradise", "Zermatt", "Zermatt, Valais"]
                expectEqual(WikipediaVerifier.chooseHit(from: hits, for: "Zermatt",
                                                        avoiding: []), "Zermatt")
            }

            Harness.test("a disambiguation page steps aside for the real place") {
                // What actually came back for "Tanga": the list of meanings first,
                // the Tanzanian port fifth.  Reading the list again is the one
                // useless thing to do, and it is what the old code did — so the
                // challenge failed on a city of a quarter of a million people.
                let hits = ["Tanga", "Tanga Loa", "Battle of Tanga",
                            "Tanga (currency)", "Tanga, Tanzania"]
                expectEqual(WikipediaVerifier.chooseHit(from: hits, for: "Tanga",
                                                        avoiding: ["tanga"]),
                            "Tanga, Tanzania")
            }

            Harness.test("the name in its own right beats the name in a battle") {
                // Ordering, not mere survival: "Battle of Tanga" is earlier in the
                // list and would win a first-usable-hit rule.
                let hits = ["Battle of Tanga", "Tanga, Tanzania"]
                expectEqual(WikipediaVerifier.chooseHit(from: hits, for: "Tanga",
                                                        avoiding: ["tanga"]),
                            "Tanga, Tanzania")
            }

            Harness.test("the same name wearing a kind still counts") {
                // "Hualien" is a list of meanings; the city is filed under
                // "Hualien City", with no comma for the scoped rule to find.
                let hits = ["Hualien", "Hualien County", "Hualien City",
                            "Hualien Airport"]
                expectEqual(WikipediaVerifier.chooseHit(from: hits, for: "Hualien",
                                                        avoiding: ["hualien"]),
                            "Hualien City")
            }

            Harness.test("a qualifier has to name a kind of place") {
                // Tanga Loa is an island in Tonga and has nothing to do with the
                // Tanzanian port; "Loa" is not a kind of place, so it must not
                // stand in for the name a player typed.
                expectEqual(WikipediaVerifier.chooseHit(from: ["Tanga Loa", "Tanga Bank"],
                                                        for: "Tanga",
                                                        avoiding: ["tanga"]), nil)
            }

            Harness.test("a hyphenated fuller name answers for the short one") {
                // Vitoria's page is a list of meanings and half of it is football
                // clubs; the Basque city is filed under both its names at once.
                let hits = ["Vitoria", "Vitória S.C.", "Vitoria-Gasteiz",
                            "Esporte Clube Vitória"]
                expectEqual(WikipediaVerifier.chooseHit(from: hits, for: "Vitoria",
                                                        avoiding: ["vitoria"]),
                            "Vitoria-Gasteiz")
            }

            Harness.test("a word is not a name") {
                // "Port" is a kind of place, so Port-au-Prince must not answer for
                // it — otherwise the word itself joins the atlas as a place.
                expectEqual(WikipediaVerifier.chooseHit(from: ["Port", "Port-au-Prince",
                                                               "Port City"],
                                                        for: "Port",
                                                        avoiding: ["port"]), nil)
                expectEqual(WikipediaVerifier.chooseHit(from: ["New", "New-York"],
                                                        for: "New", avoiding: ["new"]), nil)
            }

            Harness.test("a search that only returns what was already rejected gives up") {
                expectEqual(WikipediaVerifier.chooseHit(from: ["Tanga"], for: "Tanga",
                                                        avoiding: ["tanga"]), nil)
                expectEqual(WikipediaVerifier.chooseHit(from: [], for: "Tanga",
                                                        avoiding: []), nil)
            }

            Harness.test("a misspelling may be corrected to a differently named page") {
                // Nothing was read, so there is no article under what was typed:
                // the search index is the only thing that can find the place, and
                // it is allowed to answer with a name of its own choosing.
                expectEqual(WikipediaVerifier.chooseHit(from: ["Kolkata", "Kolkata Metro"],
                                                        for: "Kolkatta", avoiding: []),
                            "Kolkata")
            }

            Harness.test("a rejected page is not overturned by an unrelated one") {
                // "Steve Jobs" was read and refused.  The biography of him is a
                // fine search hit and a terrible place, and letting it through
                // would file a man in the atlas under the name a player typed.
                expectEqual(WikipediaVerifier.chooseHit(from: ["Steve Jobs",
                                                               "Steve Jobs (film)",
                                                               "Cupertino, California"],
                                                        for: "Steve Jobs",
                                                        avoiding: ["stevejobs"]), nil)
            }

            Harness.test("accents are not a reason to refuse the article") {
                // `key` folds diacritics, so the old guard — "the search result
                // must differ from what was typed" — threw away the right page
                // whenever the typed name was the unaccented spelling.
                expectEqual(WikipediaVerifier.chooseHit(from: ["São Paulo"],
                                                        for: "Sao Paulo",
                                                        avoiding: []), "São Paulo")
            }

            Harness.test("a word inside a longer word is not that word") {
                // Every one of these refused a real city: a Polish one for being a
                // ship (Voivodeship), Songkhla for being a song, Lubango for being
                // a band (Sá da Bandeira), and every American township for being a
                // ship as well.
                let refused = ["City in Podkarpackie Voivodeship, Poland",
                               "Songkhla is a city in southern Thailand",
                               "Lubango, formerly Sa da Bandeira, is a city in Angola",
                               "Township in Michigan"]
                for description in refused {
                    expect(!WikipediaVerifier.disqualifies(description),
                           "“\(description)” reads as a place")
                    expect(WikipediaVerifier.readsAsPlace(description),
                           "“\(description)” reads as a place")
                }
            }

            Harness.test("the real disqualifiers still disqualify") {
                for description in ["1994 film directed by Luc Besson",
                                    "Studio album by Fleetwood Mac",
                                    "American politician (1946-2020)",
                                    "Battle of the Second World War",
                                    "Ship of the Royal Navy",
                                    "Songs from the musical"] {
                    expect(WikipediaVerifier.disqualifies(description),
                           "“\(description)” is not a place")
                }
            }

            Harness.test("a provincial seat is a city, not a capital") {
                // Both of these were learned during testing and both went into the
                // atlas as capitals, which would announce Chiclayo to the table as
                // though it ran Peru.
                func kind(_ d: String) -> String {
                    WikipediaVerifier.inferKind(description: d, blob: d)
                }
                expectEqual(kind("Capital of Tanga Region, Tanzania"), "city")
                expectEqual(kind("Capital of Lambayeque Region, Peru"), "city")
                expectEqual(kind("Capital city of Nampula Province, Mozambique"), "city")
                expectEqual(kind("Capital of Peru"), "capital")
                expectEqual(kind("Capital and largest city of Iran"), "capital")
            }

            Harness.test("a state is a region and a river is a river") {
                func kind(_ d: String) -> String {
                    WikipediaVerifier.inferKind(description: d, blob: d)
                }
                expectEqual(kind("State of Mexico"), "region")
                expectEqual(kind("River in central Europe"), "river")
                expectEqual(kind("City in Federation of Bosnia and Herzegovina"), "city")
                expectEqual(kind("Country in South America"), "country")
                // The description is read before the body: a city described as
                // sitting "in the region of Imereti" is still a city.
                expectEqual(WikipediaVerifier.inferKind(
                    description: "City in Imereti, Georgia",
                    blob: "Kutaisi is a city in the region of Imereti"), "city")
            }

            Harness.test("silence is remembered by nobody") {
                // Wikipedia rate-limits, and it did during testing: a burst of
                // lookups and every real city came back "no article found".  Two
                // separate wrongs — the wording, and that the wrong answer was
                // then cached, so the name stayed fake long after the throttling
                // passed.  A verdict nobody actually gave must not be kept.
                expect(!WikipediaVerifier.worthRemembering(WikipediaVerifier.silence))
                expect(WikipediaVerifier.worthRemembering(
                    VerificationResult(accepted: false, reason: "no Wikipedia article found")))
                expect(WikipediaVerifier.worthRemembering(
                    VerificationResult(accepted: true, resolvedName: "Kisumu")))
            }

            Harness.test("could-not-ask does not read like a refusal") {
                expect(!WikipediaVerifier.silence.accepted)
                expect(WikipediaVerifier.silence.reason.contains("did not answer"),
                       "the player is told the lookup failed, not that the place is fake")
            }

            Harness.test("a lookup outlives the caller's reference to the verifier") {
                // `WikipediaVerifier().verify(…)` is the natural way to write a
                // one-shot lookup, and it used to answer "cancelled" every time:
                // the verifier died before its own callback ran.  This needs no
                // network — with or without one, a real answer must come back.
                let box = ResultSlot()
                let done = DispatchSemaphore(value: 0)
                WikipediaVerifier(timeout: 4).verify("Qqzzxwlandia") {
                    box.value = $0
                    done.signal()
                }
                guard done.wait(timeout: .now() + 20) == .success else {
                    return fail("the lookup never called back")
                }
                expect(box.value?.reason != "cancelled",
                       "the verifier was deallocated mid-flight")
                expectEqual(box.value?.accepted, false)
            }
        }
    }
}

/// A box for handing a result back from a callback on another thread.
private final class ResultSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: VerificationResult?
    var value: VerificationResult? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
