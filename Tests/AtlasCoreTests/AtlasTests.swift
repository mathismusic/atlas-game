import Foundation
import AtlasCore

enum AtlasTests {

    static let shared: Atlas = {
        do { return try Atlas.bundled() }
        catch { fatalError("bundled atlas failed to load: \(error)") }
    }()

    static func run() {
        let atlas = shared

        Harness.suite("the shipped atlas") {

            Harness.test("is big enough to play with") {
                expectGreater(atlas.placeCount, 1_000)
                expectGreater(atlas.surfaceCount, atlas.placeCount)
            }

            Harness.test("contains the places everybody names first") {
                for name in ["Sydney", "Paris", "Tokyo", "New York", "Cairo", "Iceland",
                             "Amazon", "Sahara", "Antarctica", "Kerala", "Everest"] {
                    expectNotNil(atlas.surface(matching: name), "missing \(name)")
                }
            }

            Harness.test("accepts landmarks with or without their title") {
                // "Mount Everest" and "Everest" are the same mountain but start
                // on different letters, so both have to be playable.
                for (bare, titled) in [("Everest", "Mount Everest"), ("Fuji", "Mount Fuji"),
                                       ("Uluru", "Ayers Rock"),
                                       ("Saint Lucia", "St Lucia")] {
                    guard let left = atlas.surface(matching: bare),
                          let right = atlas.surface(matching: titled) else {
                        fail("\(bare)/\(titled) are not both present")
                        continue
                    }
                    expectEqual(left.placeID, right.placeID)
                    expectEqual(right.first, Normalize.firstLetter(titled))
                }
            }

            Harness.test("treats common alternative names as one place") {
                for (a, b) in [("Bombay", "Mumbai"), ("Peking", "Beijing"),
                               ("Holland", "Netherlands"), ("Burma", "Myanmar")] {
                    guard let left = atlas.surface(matching: a),
                          let right = atlas.surface(matching: b) else {
                        fail("\(a)/\(b) are not both present")
                        continue
                    }
                    expectEqual(left.placeID, right.placeID, "\(a) and \(b) should be one place")
                }
            }

            Harness.test("lets an alias keep its own chain letter") {
                // The chain follows what the player typed, not the canonical
                // name: saying "Bombay" hands the next player a Y, not an I.
                guard let bombay = atlas.surface(matching: "bombay") else {
                    return fail("no Bombay")
                }
                expectEqual(bombay.last, "y")
                expectEqual(bombay.first, "b")
            }

            Harness.test("has no dead-end letters") {
                // If some place ends in a letter no place begins with, a player
                // can be handed an unanswerable turn through no fault of theirs.
                var endings = Set<Character>()
                for place in atlas.allPlaces {
                    for name in [place.name] + place.aliases {
                        if let last = Normalize.lastLetter(name) { endings.insert(last) }
                    }
                }
                let stranded = endings.subtracting(Set(atlas.startingLetters))
                expect(stranded.isEmpty, "dead ends: \(stranded.sorted())")
            }

            Harness.test("has sane fields on every entry") {
                for place in atlas.allPlaces {
                    expect(!place.name.isEmpty, "a place has no name")
                    expect((0...100).contains(place.fame), "\(place.name) fame \(place.fame)")
                    expectNotNil(Normalize.firstLetter(place.name),
                                 "\(place.name) has no letters")
                }
            }

            Harness.test("is forgiving about how a name is typed") {
                for typed in ["  sYdNeY ", "SYDNEY", "sydney"] {
                    expectNotNil(atlas.surface(matching: typed),
                                 "failed on \(typed.debugDescription)")
                }
                expectNil(atlas.surface(matching: "Sydneyy"))
                expectNil(atlas.surface(matching: ""))
            }
        }

        Harness.suite("atlas queries") {

            Harness.test("candidates respect letter, fame floor and exclusions") {
                let options = atlas.candidates(startingWith: "s", minFame: 0, excluding: [])
                expect(!options.isEmpty)
                expect(options.allSatisfy { $0.first == "s" })

                let famous = atlas.candidates(startingWith: "s", minFame: 80, excluding: [])
                expect(famous.allSatisfy { $0.fame >= 80 })
                expectLess(famous.count, options.count)

                let excluded = Set(options.prefix(5).map(\.placeID))
                let left = atlas.candidates(startingWith: "s", minFame: 0, excluding: excluded)
                expect(left.allSatisfy { !excluded.contains($0.placeID) })
            }

            Harness.test("candidates come back fame-descending") {
                let fames = atlas.candidates(startingWith: "b", minFame: 0,
                                             excluding: []).map(\.fame)
                expectEqual(fames, fames.sorted(by: >))
            }

            Harness.test("reply counts match the candidate lists") {
                for letter in "abcxyz" {
                    let expected = atlas.candidates(startingWith: letter, minFame: 40,
                                                    excluding: []).count
                    expectEqual(atlas.replyCount(for: letter, minFame: 40, excluding: []),
                                expected, "mismatch on \(letter)")
                }
            }
        }

        Harness.suite("growing the atlas") {

            Harness.test("an inserted place is playable immediately") {
                let local = Atlas(places: [Place(name: "Sydney", kind: "city", fame: 95)])
                expectNil(local.surface(matching: "Yarralumla"))
                _ = local.insert(Place(name: "Yarralumla", kind: "city", fame: 70, learned: true))

                guard let found = local.surface(matching: "yarralumla") else {
                    return fail("insert did not index the place")
                }
                expectEqual(found.first, "y")
                expectEqual(local.candidates(startingWith: "y", minFame: 0, excluding: []).count, 1)
                expectEqual(local.learnedPlaces.map(\.name), ["Yarralumla"])
            }

            Harness.test("inserting a duplicate merges rather than doubling") {
                let local = Atlas(places: [Place(name: "Sydney", kind: "city", fame: 95)])
                let before = local.placeCount
                let id = local.insert(Place(name: "sydney", kind: "city", fame: 60,
                                            aliases: ["Sinny"]))
                expectEqual(local.placeCount, before, "a duplicate created a second place")
                expectEqual(local.surface(matching: "Sydney")?.placeID, id)
                expectEqual(local.surface(matching: "Sinny")?.placeID, id, "the alias was dropped")
            }
        }
    }
}
