import Foundation
import AtlasCore

/// Cards, scoring, the dead-letter rescue and the one-line geography — the
/// features that turn a letter chain into a game with a scoreboard.
enum CardTests {

    /// Places chosen so that every rule below has both an answer and a
    /// counter-example under the same letter.
    private static func deckAtlas() -> Atlas {
        Atlas(places: [
            Place(name: "Sydney", kind: "city", country: "AU", fame: 95,
                  countryName: "Australia", continent: "OC", language: "English",
                  side: "south-east", latitude: -33.9, longitude: 151.2),
            Place(name: "Seoul", kind: "capital", country: "KR", fame: 93,
                  countryName: "South Korea", continent: "AS", language: "Korean",
                  side: "north-west", latitude: 37.6, longitude: 127.0),
            Place(name: "Somalia", kind: "country", country: "SO", fame: 78,
                  continent: "AF", language: "Somali", side: "east",
                  latitude: 5.2, longitude: 46.2),
            Place(name: "Sahara", kind: "desert", country: "", fame: 88,
                  continent: "AF", latitude: 23.0, longitude: 12.0),
            Place(name: "San Marino", kind: "country", country: "SM", fame: 72,
                  continent: "EU", language: "Italian", latitude: 43.9, longitude: 12.5),
            Place(name: "Yemen", kind: "country", country: "YE", fame: 80,
                  continent: "AS", language: "Arabic", latitude: 15.6, longitude: 48.5),
            Place(name: "Norway", kind: "country", country: "NO", fame: 90,
                  continent: "EU", language: "Norwegian", latitude: 62.0, longitude: 10.0),
            Place(name: "Ottawa", kind: "capital", country: "CA", fame: 84,
                  countryName: "Canada", continent: "NA", language: "English and French",
                  side: "south-east", latitude: 45.4, longitude: -75.7),
            Place(name: "Accra", kind: "capital", country: "GH", fame: 70,
                  countryName: "Ghana", continent: "AF", language: "English",
                  side: "south", latitude: 5.6, longitude: -0.2),
            Place(name: "Amsterdam", kind: "capital", country: "NL", fame: 91,
                  countryName: "The Netherlands", continent: "EU", language: "Dutch",
                  side: "north-west", latitude: 52.4, longitude: 4.9),
        ])
    }

    private static func place(_ atlas: Atlas, _ name: String) -> Place? {
        atlas.surface(matching: name).flatMap { atlas.place($0.placeID) }
    }

    static func run() {
        Harness.suite("card rules") {

            Harness.test("letter rules read what the player typed, not the atlas entry") {
                // Bombay is filed under Mumbai, but the player said a word
                // ending in Y, and that is the word the card is about.
                let vowel = CardRule.endsInVowel
                expect(vowel.accepts(text: "Mumbai", place: nil))
                expect(!vowel.accepts(text: "Bombay", place: nil))
                expect(CardRule.lengthExactly(6).accepts(text: "Bombay", place: nil))
            }

            Harness.test("punctuation and spaces are not letters") {
                expect(CardRule.lengthExactly(9).accepts(text: "San Marino", place: nil),
                       "the space does not count toward the length")
                expect(CardRule.sameFirstAndLast.accepts(text: "Accra", place: nil))
                expect(CardRule.wordsAtLeast(2).accepts(text: "San Marino", place: nil))
                expect(!CardRule.singleWord.accepts(text: "San Marino", place: nil))
            }

            Harness.test("double letters are spotted") {
                expect(CardRule.doubleLetter.accepts(text: "Ottawa", place: nil))
                expect(!CardRule.doubleLetter.accepts(text: "Norway", place: nil))
            }

            Harness.test("place rules read the atlas entry") {
                let atlas = deckAtlas()
                let sydney = place(atlas, "Sydney")
                expect(CardRule.inContinent("OC").accepts(text: "Sydney", place: sydney))
                expect(!CardRule.inContinent("EU").accepts(text: "Sydney", place: sydney))
                expect(CardRule.southOfEquator.accepts(text: "Sydney", place: sydney))
                expect(!CardRule.northOfEquator.accepts(text: "Sydney", place: sydney))
                expect(CardRule.languageSpoken("English")
                    .accepts(text: "Ottawa", place: place(atlas, "Ottawa")),
                       "a bilingual country counts for either language")
                expect(CardRule.ofKind(["capital"]).accepts(text: "Seoul",
                                                            place: place(atlas, "Seoul")))
            }

            Harness.test("a place the atlas knows nothing about fails a place rule") {
                // A challenged-in place has no coordinates, so it cannot claim
                // to be north of the equator just because zero is not negative.
                expect(!CardRule.southOfEquator.accepts(text: "Zzyzx", place: nil))
                expect(!CardRule.fameAtMost(50).accepts(text: "Zzyzx", place: nil))
            }

            Harness.test("every card can say what it wants in English") {
                for template in CardDeck.templates {
                    expect(!template.rule.demand.isEmpty, "\(template.rule) has no demand")
                    expect(!template.rule.headline.isEmpty, "\(template.rule) has no headline")
                    expect(template.rule.demand.first?.isUppercase != true,
                           "\(template.rule): the demand is read mid-sentence")
                }
            }
        }

        Harness.suite("dealing cards") {

            Harness.test("a dealt card always has answers under the letter in play") {
                let atlas = Atlas.standard()
                var rng = SeededRNG(seed: 9)
                var dealt = 0
                for letter in "abcdefghijklmnopqrstuvwxyz" {
                    for _ in 0..<12 {
                        guard let card = CardDeck.deal(atlas: atlas, letter: letter, used: [],
                                                       minFame: 0,
                                                       tiers: Set(CardTier.allCases),
                                                       rng: &rng) else { continue }
                        dealt += 1
                        let answers = atlas.candidates(startingWith: letter, minFame: 0)
                            .filter { card.accepts(text: $0.text, place: atlas.place($0.placeID)) }
                        expect(!answers.isEmpty,
                               "\(String(letter)): \(card.headline) has no answer at all")
                        expectAtLeast(card.answers, 1, card.headline)
                    }
                }
                expectGreater(dealt, 200, "the deck should deal on nearly every letter")
            }

            Harness.test("a hard card is genuinely scarce, an easy one is not") {
                let atlas = Atlas.standard()
                var rng = SeededRNG(seed: 4)
                var seen: [CardTier: Int] = [:]
                for letter in "abcdefghijklmnopqrstuvwxyz" {
                    let pool = atlas.candidates(startingWith: letter, minFame: 0)
                        .prefix(140).count
                    for tier in CardTier.allCases {
                        guard let card = CardDeck.deal(atlas: atlas, letter: letter, used: [],
                                                       minFame: 0, tiers: [tier],
                                                       rng: &rng) else { continue }
                        seen[tier, default: 0] += 1
                        expectEqual(card.tier, tier, "asked for \(tier), got \(card.tier)")
                        // The share is measured against the same window the
                        // dealer scanned, which is what the tier promises.
                        let share = Double(card.answers) / Double(max(pool, 1))
                        expect(share <= 0.9, "\(card.headline) covers \(share) of \(letter)")
                        if tier == .hard {
                            expect(share <= 0.25,
                                   "a hard card covering \(share) of \(letter) is not hard")
                        }
                    }
                }
                for tier in CardTier.allCases {
                    expectGreater(seen[tier] ?? 0, 10, "\(tier) barely ever deals")
                }
            }

            Harness.test("already-played places do not count as answers") {
                let atlas = Atlas.standard()
                var rng = SeededRNG(seed: 3)
                let used = Set(atlas.candidates(startingWith: "s", minFame: 0)
                    .prefix(120).map(\.placeID))
                if let card = CardDeck.deal(atlas: atlas, letter: "s", used: used,
                                            minFame: 0, tiers: Set(CardTier.allCases),
                                            rng: &rng) {
                    let live = atlas.candidates(startingWith: "s", minFame: 0, excluding: used)
                        .filter { card.accepts(text: $0.text, place: atlas.place($0.placeID)) }
                    expect(!live.isEmpty, "\(card.headline) is unanswerable once S is picked over")
                }
            }

            Harness.test("a letter with nothing left deals nothing") {
                let atlas = deckAtlas()
                let all = Set(atlas.candidates(startingWith: "s", minFame: 0).map(\.placeID))
                var rng = SeededRNG(seed: 1)
                expectNil(CardDeck.deal(atlas: atlas, letter: "s", used: all, minFame: 0,
                                        tiers: Set(CardTier.allCases), rng: &rng))
            }
        }

        Harness.suite("points and cards in play") {

            /// A table where every turn deals a card, so scoring is not left to
            /// the dice.
            func cardGame(forced: Bool, seed: UInt64 = 7) -> Game {
                var config = GameConfig(turnSeconds: 30, lives: 2, startLetter: "s")
                config.cardChance = 1
                config.forcedCards = forced
                let game = Game(atlas: Atlas.standard(), config: config, seed: seed)
                for (i, name) in ["Ann", "Ben"].enumerated() {
                    game.addPlayer(Player(id: "p\(i)", name: name, lives: 2))
                }
                game.start(now: 0)
                return game
            }

            Harness.test("an ordinary place is worth one point") {
                let game = cardGame(forced: false)
                let atlas = game.atlas
                // Pick something that does *not* meet the card, so the score is
                // the plain one point.
                let card = game.card
                let plain = atlas.candidates(startingWith: game.requiredLetter, minFame: 60)
                    .first { s in
                        card.map { !$0.accepts(text: s.text, place: atlas.place(s.placeID)) } ?? true
                    }
                guard let plain else { return }
                guard case .accepted(let move) = game.submit(playerID: "p0", text: plain.text,
                                                             now: 1) else {
                    return fail("\(plain.text) was refused")
                }
                expectEqual(move.points, 1)
                expect(!move.metCard)
                expectEqual(game.players[0].score, 1)
                expectEqual(game.players[0].placesPlayed, 1)
            }

            Harness.test("meeting a card multiplies the points and is remembered") {
                let game = cardGame(forced: false)
                let atlas = game.atlas
                guard let card = game.card else { return fail("no card was dealt") }
                guard let fits = atlas.candidates(startingWith: game.requiredLetter, minFame: 0)
                    .first(where: { card.accepts(text: $0.text, place: atlas.place($0.placeID)) })
                else { return fail("a dealt card had no answer") }

                guard case .accepted(let move) = game.submit(playerID: "p0", text: fits.text,
                                                             now: 1) else {
                    return fail("\(fits.text) was refused")
                }
                expect(move.metCard)
                expectEqual(move.points, card.multiplier)
                expectEqual(game.players[0].score, card.multiplier)
                expectEqual(game.players[0].cardsMet, 1)
                expect(game.log.contains { $0.kind == "card_met" })
            }

            Harness.test("a hard card pays a life as well") {
                var config = GameConfig(turnSeconds: 30, lives: 2, startLetter: "s")
                config.cardChance = 1
                config.cardTiers = [.hard]
                let game = Game(atlas: Atlas.standard(), config: config, seed: 12)
                game.addPlayer(Player(id: "p0", name: "Ann", lives: 2))
                game.addPlayer(Player(id: "p1", name: "Ben", lives: 2))
                game.start(now: 0)
                guard let card = game.card, card.grantsLife else { return }
                let atlas = game.atlas
                guard let fits = atlas.candidates(startingWith: game.requiredLetter, minFame: 0)
                    .first(where: { card.accepts(text: $0.text, place: atlas.place($0.placeID)) })
                else { return fail("a hard card had no answer") }
                guard case .accepted = game.submit(playerID: "p0", text: fits.text, now: 1) else {
                    return fail("\(fits.text) was refused")
                }
                expectEqual(game.players[0].lives, 3, "a hard card is worth an extra life")
            }

            Harness.test("a forced card refuses a place that does not meet it") {
                let game = cardGame(forced: true)
                let atlas = game.atlas
                guard let card = game.card else { return fail("no card was dealt") }
                guard let wrong = atlas.candidates(startingWith: game.requiredLetter, minFame: 0)
                    .first(where: { !card.accepts(text: $0.text, place: atlas.place($0.placeID)) })
                else { return }
                guard case .rejected(let why) = game.submit(playerID: "p0", text: wrong.text,
                                                            now: 1) else {
                    return fail("\(wrong.text) should have been refused: \(card.demand)")
                }
                expectEqual(why.code, "card_not_met")
                expect(!why.isChallengeable, "a card is not something the web can settle")
                expect(why.message.contains(card.demand))
            }

            Harness.test("a bonus card never blocks a legal place") {
                let game = cardGame(forced: false)
                let atlas = game.atlas
                guard let card = game.card else { return fail("no card was dealt") }
                guard let wrong = atlas.candidates(startingWith: game.requiredLetter, minFame: 0)
                    .first(where: { !card.accepts(text: $0.text, place: atlas.place($0.placeID)) })
                else { return }
                guard case .accepted = game.submit(playerID: "p0", text: wrong.text, now: 1) else {
                    return fail("a card that is only worth points refused a legal move")
                }
            }

            Harness.test("hints answer the card as well as the letter") {
                let game = cardGame(forced: true, seed: 21)
                guard let card = game.card else { return fail("no card was dealt") }
                let hints = game.hints(limit: 5, now: 1)
                expect(!hints.isEmpty, "a forced card must be hintable")
                for hint in hints {
                    guard case .accepted = game.submit(playerID: "p0", text: hint, now: 1) else {
                        return fail("the hint \"\(hint)\" fails its own card: \(card.demand)")
                    }
                    break   // one is enough; the rest of the game is another test
                }
            }

            Harness.test("cards can be turned off entirely") {
                var config = GameConfig(turnSeconds: 30, lives: 2, startLetter: "s")
                config.cardChance = 0
                let game = Game(atlas: Atlas.standard(), config: config, seed: 5)
                game.addPlayer(Player(id: "p0", name: "Ann", lives: 2))
                game.addPlayer(Player(id: "p1", name: "Ben", lives: 2))
                game.start(now: 0)
                expectNil(game.card)
                expectNil(game.view(now: 0).card)
            }
        }

        Harness.suite("the dead-letter rescue") {

            /// Four places, arranged so the chain can paint itself into a
            /// corner in three moves.
            let atlas = Atlas(places: [
                Place(name: "Sydney", kind: "city", fame: 95),
                Place(name: "Yemen", kind: "country", fame: 80),
                Place(name: "Norway", kind: "country", fame: 90),
                Place(name: "Yukon", kind: "region", fame: 70),
            ])

            func stuckGame(rescue: Bool) -> Game {
                var config = GameConfig(turnSeconds: 10, lives: 2, startLetter: "s")
                config.cardChance = 0
                config.deadLetterRescue = rescue
                let game = Game(atlas: atlas, config: config, seed: 3)
                game.addPlayer(Player(id: "p0", name: "Ann", lives: 2))
                game.addPlayer(Player(id: "p1", name: "Ben", lives: 2))
                game.start(now: 0)
                return game
            }

            Harness.test("a letter with an answer left costs a life as usual") {
                let game = stuckGame(rescue: true)
                // S → Y, and Y still has Yemen and Yukon, so timing out is a
                // genuine failure and must be punished.
                guard case .accepted = game.submit(playerID: "p0", text: "Sydney", now: 1) else {
                    return fail("Sydney was refused")
                }
                _ = game.tick(now: 60)
                expectEqual(game.players[1].lives, 1, "Ben had answers and did not find one")
                expect(game.log.contains { $0.kind == "rescue" },
                       "the atlas should say what it would have played")
            }

            /// Sydney → Yemen → Norway → Yukon leaves N, and Norway was the
            /// only N in this atlas.  Nobody could answer that; the engine has
            /// to notice rather than charge a life for it.
            let intoTheCorner = [("p0", "Sydney"), ("p1", "Yemen"),
                                 ("p0", "Norway"), ("p1", "Yukon")]

            Harness.test("an impossible letter is handed back instead of taking a life") {
                let game = stuckGame(rescue: true)
                for (who, text) in intoTheCorner {
                    guard case .accepted = game.submit(playerID: who, text: text, now: 1) else {
                        return fail("\(text) was refused")
                    }
                }
                expectEqual(game.requiredLetter, "n")
                expectEqual(game.currentPlayerID, "p0")
                let livesBefore = game.players.map(\.lives)

                _ = game.tick(now: 60)

                expectEqual(game.players.map(\.lives), livesBefore,
                            "nobody should lose a life over a letter with no answer")
                expectEqual(game.moves.count, 3,
                            "the move that created the dead letter is taken back")
                expectEqual(game.moves.last?.text, "Norway")
                expect(game.log.contains { $0.kind == "dead_letter" })
                expectEqual(game.requiredLetter, "y", "the letter reverts to the one before")
                expectEqual(game.currentPlayerID, "p1", "and so does the turn")
                expectEqual(game.players[1].score, 1, "the retracted move's point goes back too")
                expectEqual(game.players[1].placesPlayed, 1)
            }

            Harness.test("the rescue can be switched off") {
                let game = stuckGame(rescue: false)
                for (who, text) in intoTheCorner {
                    guard case .accepted = game.submit(playerID: who, text: text, now: 1) else {
                        return fail("\(text) was refused")
                    }
                }
                _ = game.tick(now: 60)
                expectEqual(game.players[0].lives, 1, "without the rescue, the letter still bites")
                expectEqual(game.moves.count, 4, "and nothing is taken back")
            }

            Harness.test("at a forced table the rescue obeys the card too") {
                // The rescue exists to prove the turn was playable.  At a
                // forced table a place that breaks the card is not playable,
                // so naming one would prove the opposite of what it claims.
                let world = Atlas.standard()
                for seed in UInt64(1)...12 {
                    var config = GameConfig(turnSeconds: 10, lives: 2)
                    config.cardChance = 1
                    config.forcedCards = true
                    let game = Game(atlas: world, config: config, seed: seed)
                    game.addPlayer(Player(id: "p0", name: "Ann", lives: 2))
                    game.addPlayer(Player(id: "p1", name: "Ben", lives: 2))
                    game.start(now: 0)
                    guard let card = game.card else { continue }

                    _ = game.tick(now: 60)

                    guard let said = game.log.first(where: { $0.kind == "rescue" })?.text
                    else { continue }
                    // "The atlas would have said Somalia" — the name is the tail.
                    let named = said.components(separatedBy: "said ").last ?? said
                    guard let surface = world.surface(matching: named) else {
                        return fail("the rescue named something not in the atlas: \(said)")
                    }
                    expect(card.accepts(text: surface.text, place: world.place(surface.placeID)),
                           "\(named) does not \(card.demand)")
                }
            }

            Harness.test("a game of nothing but dead letters still ends") {
                // Every retraction must make progress, or the engine would hand
                // the turn back and forth for ever.
                let game = stuckGame(rescue: true)
                var guardCounter = 0
                var now = 1.0
                while game.phase == .playing && guardCounter < 4000 {
                    guardCounter += 1
                    now += 5
                    _ = game.tick(now: now)
                }
                expectLess(guardCounter, 4000, "the dead-letter unwind did not terminate")
                expectEqual(game.phase, .finished)
            }
        }

        Harness.suite("one line of geography") {

            Harness.test("a city is placed in its country and its corner of it") {
                let atlas = deckAtlas()
                expectEqual(place(atlas, "Sydney")?.blurb,
                            "a city in south-eastern Australia, where English is spoken")
            }

            Harness.test("a capital says so first") {
                let atlas = deckAtlas()
                expectEqual(place(atlas, "Seoul")?.blurb,
                            "the capital of South Korea, in the north-west, where Korean is spoken")
            }

            Harness.test("countries that take a 'the' get one") {
                let atlas = deckAtlas()
                let line = place(atlas, "Amsterdam")?.blurb ?? ""
                expect(line.contains("the capital of the Netherlands"), line)
                expect(!line.contains("The Netherlands"), "mid-sentence it is lower case: \(line)")
            }

            Harness.test("several languages are spoken, not is spoken") {
                let atlas = deckAtlas()
                let line = place(atlas, "Ottawa")?.blurb ?? ""
                expect(line.contains("English and French are spoken"), line)
            }

            Harness.test("a country is placed on its continent, not inside itself") {
                let atlas = deckAtlas()
                let line = place(atlas, "Norway")?.blurb ?? ""
                expect(line.hasPrefix("a country in Europe"), line)
                let sahara = place(atlas, "Sahara")?.blurb ?? ""
                expect(sahara.hasPrefix("a desert in Africa"), sahara)
            }

            Harness.test("the whole atlas produces a readable line") {
                let atlas = Atlas.standard()
                var withGeography = 0
                for id in 0..<atlas.placeCount {
                    guard let p = atlas.place(id) else { continue }
                    let line = p.blurb
                    expect(!line.isEmpty, "\(p.name) has nothing to say")
                    expect(!line.contains("  "), "\(p.name): \(line)")
                    expect(!line.contains(" in ,"), "\(p.name): \(line)")
                    expect(line.first?.isUppercase != true,
                           "\(p.name): the line is read after 'X is': \(line)")
                    // Whole-word: the Namib really is in Namibia.
                    expect(!line.hasSuffix(" in \(p.name)")
                           && !line.contains(" in \(p.name),"),
                           "\(p.name) is inside itself: \(line)")
                    if line.contains(" in ") { withGeography += 1 }
                }
                expectGreater(withGeography, atlas.placeCount * 3 / 4,
                              "most places should know where they are")
            }

            Harness.test("the chain carries the line with each move") {
                var config = GameConfig(turnSeconds: 30, lives: 2, startLetter: "s")
                config.cardChance = 0
                let game = Game(atlas: Atlas.standard(), config: config, seed: 2)
                game.addPlayer(Player(id: "p0", name: "Ann", lives: 2))
                game.addPlayer(Player(id: "p1", name: "Ben", lives: 2))
                game.start(now: 0)
                guard case .accepted(let move) = game.submit(playerID: "p0", text: "Sydney",
                                                             now: 1) else {
                    return fail("Sydney was refused")
                }
                expect(move.blurb.contains("Australia"), move.blurb)
            }
        }

        Harness.suite("betting a life") {

            /// A table that deals nothing by itself, so every card in these
            /// tests is one somebody asked for.
            func table(lives: Int = 2, forced: Bool = false, seed: UInt64 = 3) -> Game {
                var config = GameConfig(turnSeconds: 30, lives: lives, startLetter: "s")
                config.cardChance = 0
                config.forcedCards = forced
                let game = Game(atlas: Atlas.standard(), config: config, seed: seed)
                for (i, name) in ["Ann", "Ben"].enumerated() {
                    game.addPlayer(Player(id: "p\(i)", name: name, lives: lives))
                }
                game.start(now: 0)
                return game
            }

            /// A place on the letter in play that answers the card, or does not.
            func place(_ game: Game, meeting: Bool) -> String? {
                guard let card = game.card else { return nil }
                return game.atlas.candidates(startingWith: game.requiredLetter, minFame: 0)
                    .first { s in
                        card.accepts(text: s.text, place: game.atlas.place(s.placeID)) == meeting
                    }?.text
            }

            Harness.test("a bet puts a hard card on the table at once") {
                let game = table()
                expectNil(game.card, "the table dealt a card by itself")
                guard case .success(let card) = game.wager(playerID: "p0", now: 1) else {
                    return fail("the bet was refused")
                }
                expectEqual(card.tier, .hard)
                expectEqual(game.card?.demand, card.demand)
                expect(game.wagerInPlay, "the bet did not register")
                expect(game.log.contains { $0.kind == "wager" }, "the bet went unannounced")
            }

            Harness.test("winning the bet pays a hard card's points and a life") {
                let game = table()
                guard case .success(let card) = game.wager(playerID: "p0", now: 1) else {
                    return fail("the bet was refused")
                }
                guard let answer = place(game, meeting: true) else {
                    return fail("a dealt card had no answer")
                }
                guard case .accepted(let move) = game.submit(playerID: "p0", text: answer,
                                                             now: 2) else {
                    return fail("\(answer) was refused")
                }
                expect(move.metCard)
                expect(move.wagered, "the move forgot it was a bet")
                expectEqual(move.points, card.multiplier)
                expectEqual(game.players[0].lives, 3)
            }

            Harness.test("losing the bet costs the life") {
                let game = table()
                guard case .success = game.wager(playerID: "p0", now: 1) else {
                    return fail("the bet was refused")
                }
                guard let answer = place(game, meeting: false) else {
                    return fail("every place met the card")
                }
                guard case .accepted(let move) = game.submit(playerID: "p0", text: answer,
                                                             now: 2) else {
                    return fail("\(answer) was refused")
                }
                expect(!move.metCard)
                expect(move.wagered)
                // The place still counts and still scores: it was a legal move.
                expectEqual(move.points, 1)
                expectEqual(game.players[0].lives, 1)
                expect(game.log.contains { $0.kind == "wager_lost" })
            }

            Harness.test("a bet on your last life can end you") {
                let game = table(lives: 1)
                guard case .success = game.wager(playerID: "p0", now: 1) else {
                    return fail("the bet was refused")
                }
                guard let answer = place(game, meeting: false) else {
                    return fail("every place met the card")
                }
                guard case .accepted = game.submit(playerID: "p0", text: answer, now: 2) else {
                    return fail("\(answer) was refused")
                }
                expect(game.players[0].eliminated, "the lost bet was survivable")
                expectEqual(game.phase, .finished)
                expectEqual(game.winnerID, "p1")
            }

            Harness.test("a wagered card is never a rule, even at a forced table") {
                let game = table(forced: true)
                guard case .success = game.wager(playerID: "p0", now: 1) else {
                    return fail("the bet was refused")
                }
                expect(!game.cardIsRule, "the bet could not be lost")
                expect(!game.view(now: 1).cardIsRule)
                guard let answer = place(game, meeting: false) else {
                    return fail("every place met the card")
                }
                // At a forced table this would be refused outright; here it is
                // the losing half of a bet, which is the point of making one.
                guard case .accepted = game.submit(playerID: "p0", text: answer, now: 2) else {
                    return fail("\(answer) was refused — the bet could not be lost")
                }
                expectEqual(game.players[0].lives, 1)
            }

            Harness.test("running out of time voids the bet rather than doubling it") {
                let game = table()
                guard case .success = game.wager(playerID: "p0", now: 1) else {
                    return fail("the bet was refused")
                }
                _ = game.tick(now: 60)
                // One life for the clock, and none for the bet.
                expectEqual(game.players[0].lives, 1)
                expect(game.log.contains { $0.kind == "wager_off" })
                expect(!game.wagerInPlay, "the bet outlived its turn")
            }

            Harness.test("a bet belongs to one turn only") {
                let game = table()
                guard case .success = game.wager(playerID: "p0", now: 1) else {
                    return fail("the bet was refused")
                }
                guard let answer = place(game, meeting: true) else {
                    return fail("a dealt card had no answer")
                }
                guard case .accepted = game.submit(playerID: "p0", text: answer, now: 2) else {
                    return fail("\(answer) was refused")
                }
                expect(!game.wagerInPlay, "the bet carried into the next turn")
                expectNil(game.card, "the wagered card outstayed its turn")
            }

            Harness.test("one bet a turn, and only by the player to move") {
                let game = table()
                guard case .success = game.wager(playerID: "p0", now: 1) else {
                    return fail("the first bet was refused")
                }
                guard case .failure = game.wager(playerID: "p0", now: 1) else {
                    return fail("a second bet was allowed in one turn")
                }
                guard case .failure(let reason) = game.wager(playerID: "p1", now: 1) else {
                    return fail("someone bet out of turn")
                }
                expectEqual(reason, .notYourTurn)
            }

            Harness.test("a table with no deck offers no bets") {
                var config = TableMode.classic.config
                config.startLetter = "s"
                let game = Game(atlas: Atlas.standard(), config: config, seed: 4)
                game.addPlayer(Player(id: "p0", name: "Ann", lives: 2))
                game.addPlayer(Player(id: "p1", name: "Ben", lives: 2))
                game.start(now: 0)
                expect(!game.view(now: 0).canWager, "classic offered a bet")
                guard case .failure = game.wager(playerID: "p0", now: 1) else {
                    return fail("classic took a bet")
                }
            }

            Harness.test("the button is offered exactly when the bet would be taken") {
                // The phone shows the button from `canWager`, so a mismatch is a
                // player pressing something that then refuses them.
                for seed in UInt64(1)...25 {
                    var config = GameConfig(turnSeconds: 30, lives: 2)
                    config.cardChance = 0
                    let game = Game(atlas: Atlas.standard(), config: config, seed: seed)
                    game.addPlayer(Player(id: "p0", name: "Ann", lives: 2))
                    game.addPlayer(Player(id: "p1", name: "Ben", lives: 2))
                    game.start(now: 0)
                    let offered = game.view(now: 0).canWager
                    let taken: Bool
                    if case .success = game.wager(playerID: "p0", now: 1) { taken = true }
                    else { taken = false }
                    expectEqual(offered, taken,
                                "letter \(game.requiredLetter): offered \(offered), taken \(taken)")
                }
            }

            Harness.test("sudden death is one life and a deck to bet against") {
                let c = TableMode.sudden.config
                expectEqual(c.lives, 1)
                expect(c.allowWager, "sudden death without bets is just a short game")
                expect(c.cardChance > 0, "nothing to bet against")
            }
        }

        Harness.suite("table modes") {

            Harness.test("every mode is a table someone would want to sit at") {
                for mode in TableMode.allCases {
                    let c = mode.config
                    expect(!mode.title.isEmpty)
                    expect(!mode.blurb.isEmpty)
                    expectAtLeast(c.turnSeconds, 5, "\(mode) is too fast to type at")
                    expectAtLeast(c.lives, 1, "\(mode)")
                    expect(c.minimumTurnSeconds <= c.turnSeconds,
                           "\(mode): the floor is above the clock")
                    expect(c.cardChance >= 0 && c.cardChance <= 1, "\(mode)")
                    expect(!c.cardTiers.isEmpty, "\(mode) plays cards from no deck")
                    if c.forcedCards {
                        expectGreater(c.cardChance, 0, "\(mode) forces a card it never deals")
                    }
                }
                expectEqual(TableMode.catalogue.count, TableMode.allCases.count)
            }

            Harness.test("a decaying clock tightens but never runs out") {
                var config = TableMode.blitz.config
                config.startLetter = "s"
                config.cardChance = 0
                let game = Game(atlas: Atlas.standard(), config: config, seed: 8)
                game.addPlayer(Player(id: "p0", name: "Ann", lives: 9))
                game.addPlayer(Player(id: "p1", name: "Ben", isBot: true,
                                      difficulty: .hard, lives: 9))
                game.start(now: 0)
                let opening = game.view(now: 0).turnSeconds
                var now = 0.0
                for _ in 0..<400 where game.phase == .playing {
                    now += 0.5
                    _ = game.tick(now: now)
                }
                let later = game.view(now: now).turnSeconds
                expectAtLeast(later, config.minimumTurnSeconds, "the clock fell through the floor")
                expect(later <= opening, "a blitz clock should not grow")
            }

            Harness.test("classic deals no cards at all") {
                var config = TableMode.classic.config
                config.startLetter = "s"
                let game = Game(atlas: Atlas.standard(), config: config, seed: 6)
                game.addPlayer(Player(id: "p0", name: "Ann", isBot: true,
                                      difficulty: .medium, lives: 2))
                game.addPlayer(Player(id: "p1", name: "Ben", isBot: true,
                                      difficulty: .medium, lives: 2))
                game.start(now: 0)
                var now = 0.0
                for _ in 0..<600 where game.phase == .playing {
                    now += 0.5
                    _ = game.tick(now: now)
                    expectNil(game.card, "classic dealt a card")
                }
                expect(game.moves.allSatisfy { $0.points == 1 })
            }
        }
    }
}
