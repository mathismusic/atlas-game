import Foundation
import AtlasCore

/// Pictures and facts are decoration, but the code that chooses them is not
/// forgiving: it reads prose written by strangers, and the one thing it must
/// never do is put a sentence about a footballer under a city, or cut *St.
/// Petersburg* in half and print the fragment.
enum MediaTests {

    /// Openings in the shape Wikipedia actually writes them.
    static let aizawl = """
        Aizawl is the capital and the largest city of the Indian state of \
        Mizoram. It is located north of the Tropic of Cancer in the northern \
        part of Aizawl district. The city is perched on ridges 1,132 metres \
        above sea level, and is known for its Sunday silence, when almost \
        every shop closes and the streets empty for church.
        """

    static let dull = """
        Nowhereville is a city in the state of Somewhere. It has a population \
        of 43,102 as of the 2011 census. It is divided into fourteen wards.
        """

    static func run() {
        Harness.suite("pictures and facts") {

            Harness.test("the definition sentence is never the fact") {
                let fact = Quirk.pick(from: aizawl, name: "Aizawl")
                expect(!fact.hasPrefix("Aizawl is the capital"),
                       "took the sentence the game already says: \(fact)")
            }

            Harness.test("the quirky sentence is the one that gets picked") {
                let fact = Quirk.pick(from: aizawl, name: "Aizawl")
                expect(fact.contains("Sunday silence"), "picked: \(fact)")
            }

            Harness.test("an article with nothing to say says nothing") {
                expectEqual(Quirk.pick(from: dull, name: "Nowhereville"), "")
            }

            Harness.test("one sentence is never enough") {
                expectEqual(Quirk.pick(from: "Ooty is a town in Tamil Nadu.",
                                       name: "Ooty"), "")
                expectEqual(Quirk.pick(from: "", name: "Nowhere"), "")
            }

            Harness.test("abbreviations do not end a sentence") {
                let text = "Foo is a place. It is near St. Petersburg and is "
                    + "known for the oldest tram in the region."
                let parts = Quirk.sentences(text)
                expectEqual(parts.count, 2, "split into \(parts)")
                expect(parts.last?.contains("St. Petersburg") == true,
                       "St. Petersburg was cut: \(parts)")
            }

            // Rhode Island's fact, as it was actually served to a phone, read
            // "Rhode Island is the smallest U.S." — the stop after the S looked
            // like the end of a sentence.  Colorado lost its lead the same way.
            Harness.test("a dotted acronym does not end a sentence") {
                let text = "Rhode Island is a state. It is the smallest U.S. state "
                    + "by area and is known as the Ocean State."
                let parts = Quirk.sentences(text)
                expectEqual(parts.count, 2, "split into \(parts)")
                expect(parts.last?.contains("U.S. state by area") == true,
                       "cut at the acronym: \(parts)")
                let fact = Quirk.pick(from: text, name: "Rhode Island")
                expect(fact.contains("Ocean State"), "truncated fact: \(fact)")
            }

            // Two shapes the capital-after test alone got wrong, from the corpus:
            // Zapopan was cut at "C.D." and Ciudad Juárez at "Mexico–U.S.".
            Harness.test("a club and a hyphenated acronym are not ends either") {
                let zapopan = Quirk.sentences("Zapopan is a city. It is home to the "
                    + "Estadio Akron, C.D. Guadalajara's official stadium.")
                expect(zapopan.last?.contains("Guadalajara's") == true, "\(zapopan)")
                let juarez = Quirk.sentences("Juárez is a city. It forms the second "
                    + "largest binational metropolitan area on the Mexico–U.S. border.")
                expect(juarez.last?.hasSuffix("border.") == true, "\(juarez)")
            }

            // The other half of the same judgement: a lead really does often end
            // on an acronym, and those two sentences must not be welded together.
            Harness.test("but a sentence may still end on one") {
                let text = "Alaska is the largest state in the U.S. It is known "
                    + "for the highest peak in North America."
                let parts = Quirk.sentences(text)
                expectEqual(parts.count, 2, "split into \(parts)")
                expect(parts.first?.hasSuffix("U.S.") == true, "\(parts)")
            }

            Harness.test("pronunciation clutter is thrown away") {
                let cleaned = Quirk.clean("Ürümqi (Chinese: 烏魯木齊; /uːˈruːmtʃi/) "
                                          + "is known for being the city furthest "
                                          + "from any ocean on earth.")
                expect(!cleaned.contains("/uː"), "kept the IPA: \(cleaned)")
                expect(cleaned.hasPrefix("Ürümqi is"), "mangled the name: \(cleaned)")
            }

            Harness.test("a fact is short enough to read on a phone") {
                let long = "A is a city. " + String(repeating: "It is known for something. ",
                                                    count: 20)
                let fact = Quirk.pick(from: long, name: "A")
                expect(fact.count <= 190, "\(fact.count) characters")
            }

            // ---- the boilerplate every country article shares
            //
            // These are the sentences a first attempt actually came back with,
            // from twelve real articles.  Each one carries a superlative, which
            // is what let it through, and each one says only which city is the
            // biggest — which the game already tells you.

            Harness.test("which city is the biggest is not a quirky fact") {
                let cases = [
                    ("Afghanistan", "Afghanistan is a country in Asia. Kabul is the "
                        + "country's capital and largest city."),
                    ("Bangladesh", "Bangladesh is a country in South Asia. Dhaka, the "
                        + "capital and largest city, is the nation's political, "
                        + "financial, and cultural centre."),
                    ("Colombia", "Colombia is a country in South America. The Capital "
                        + "District of Bogotá is the country's largest city hosting the "
                        + "main financial and cultural hub."),
                    ("Argentina", "Argentina is a country in South America. Argentina is "
                        + "a federal state subdivided into twenty-three provinces, and "
                        + "one autonomous city, which is the federal capital."),
                ]
                for (name, article) in cases {
                    expectEqual(Quirk.pick(from: article, name: name), "",
                                "\(name) kept its boilerplate")
                }
            }

            Harness.test("a real superlative still survives the cull") {
                let beijing = "Beijing is the capital of China. With more than 21.8 "
                    + "million residents, it is the world's most populous national "
                    + "capital city."
                expect(Quirk.pick(from: beijing, name: "Beijing").contains("most populous"),
                       "threw away a fact worth keeping")
                let australia = "Australia is a country. It has a land area of 7,688,287 "
                    + "km2, making it the sixth-largest country in the world, and is the "
                    + "world's flattest and driest inhabited continent."
                expect(Quirk.pick(from: australia, name: "Australia").contains("flattest"),
                       "threw away a fact worth keeping")
            }

            // ---- a number in the sentence is not the same as a dull sentence
            //
            // Both of these are real leads.  The first was being thrown away for
            // quoting a population in the same breath as the only thing anyone
            // knows about the place, and losing to the sentence below it.

            Harness.test("a superlative outranks the statistic beside it") {
                let ushuaia = "Ushuaia is the capital of Tierra del Fuego. With a "
                    + "population of 89,606 and a location below the 54th parallel "
                    + "south latitude, Ushuaia claims the title of world's "
                    + "southernmost city. It is the only municipality in the "
                    + "Department of Ushuaia and has an area of 9,390 km2."
                let fact = Quirk.pick(from: ushuaia, name: "Ushuaia")
                expect(fact.contains("southernmost"), "picked: \(fact)")
            }

            Harness.test("a statistic on its own is still nothing") {
                let text = "Nowhereville is a town. The town had a population of "
                    + "12,004 as of the 2011 census."
                expectEqual(Quirk.pick(from: text, name: "Nowhereville"), "")
            }

            // ---- reading a whole lead finds better facts, and worse ones
            //
            // Two sentences of summary never reached a war.  A full lead does,
            // by the third paragraph, and "the site of" is scored as
            // interesting — so this is the sentence that must never be chosen.

            Harness.test("nothing grim goes under a place name") {
                let text = "Oradour-sur-Glane is a commune in western France. The "
                    + "village was the site of a massacre in 1944, in which 643 "
                    + "people were killed. The ruins have been kept as a memorial."
                expectEqual(Quirk.pick(from: text, name: "Oradour-sur-Glane"), "")
            }

            Harness.test("Warsaw is not a war") {
                let text = "Warsaw is the capital of Poland. It is known for its "
                    + "Old Town, rebuilt brick by brick and now a UNESCO site."
                expect(Quirk.pick(from: text, name: "Warsaw").contains("Old Town"),
                       "the grim filter matched the name of the city")
            }

            // ---- every rephrasing of "which city is the biggest"
            //
            // The four patterns above caught the country articles.  Three hundred
            // real places found four more phrasings of the same sentence, and it
            // is worth nothing in any of them: the game has just said the place.

            Harness.test("which city is the biggest, said four other ways") {
                let cases = [
                    ("Serbia", "Serbia is a country in Southeast Europe. Belgrade, "
                        + "Serbia's capital, is also its largest city."),
                    ("South Africa", "South Africa is a country. The largest and "
                        + "most populous city is Johannesburg, followed by Cape "
                        + "Town and Durban."),
                    ("Taiwan", "Taiwan is an island in East Asia. The largest "
                        + "metropolitan area is formed by Taipei, New Taipei "
                        + "City, and Keelung."),
                    ("Nigeria", "Nigeria is a country in West Africa. The largest "
                        + "city in Nigeria by population is Lagos, one of the "
                        + "largest metropolitan areas in the world."),
                ]
                for (name, article) in cases {
                    expectEqual(Quirk.pick(from: article, name: name), "",
                                "\(name) kept its boilerplate")
                }
            }

            // ---- the second reading of a real harvest
            //
            // With the grim filter in place, forty real country articles came
            // back clean of wars — and still handed back two sentences no one
            // wants under a place name in a party game.

            Harness.test("a country is not introduced by how poor it is") {
                let text = "Afghanistan is a landlocked country in South Asia. "
                    + "Afghanistan remains among the world's least developed "
                    + "countries with its economic output per capita among the "
                    + "lowest of any country."
                expectEqual(Quirk.pick(from: text, name: "Afghanistan"), "")
            }

            Harness.test("whose colony a place used to be is not the fact") {
                let text = "Cameroon is a country in Central Africa. Cameroon "
                    + "became a German colony in 1884 known as Kamerun. It is "
                    + "home to the oldest known human remains in the region."
                expect(Quirk.pick(from: text, name: "Cameroon").contains("human remains"),
                       "took the colony sentence")
            }

            Harness.test("a colony of an empire, however it is phrased") {
                let text = "Samoa is a country in Polynesia. The country became "
                    + "a colony of the German Empire in 1899 after the "
                    + "Tripartite Convention, and was known as German Samoa."
                expectEqual(Quirk.pick(from: text, name: "Samoa"), "")
            }

            Harness.test("a live conflict never reaches the screen") {
                let text = "The Palestinian Territory is a region in West Asia. "
                    + "Gaza was its largest city prior to the forced "
                    + "evacuations of 2023, following the October 7 attacks."
                expectEqual(Quirk.pick(from: text, name: "Palestinian Territory"), "")
            }

            Harness.test("a penguin colony is still a colony") {
                let text = "South Georgia is an island in the South Atlantic. "
                    + "St Andrews Bay is home to the largest king penguin "
                    + "colony on the island, with some 150,000 birds."
                expect(Quirk.pick(from: text, name: "South Georgia").contains("penguin"),
                       "the empire filter ate the penguins")
            }

            Harness.test("a humanitarian crisis is not a fact for a party game") {
                let cases = [
                    ("Yemen", "Yemen is a country in West Asia. In 2019, the United "
                        + "Nations reported that Yemen had the highest number of "
                        + "people in need of humanitarian aid."),
                    ("Lebanon", "Lebanon is a country in West Asia. The World Bank "
                        + "has defined Lebanon's economic crisis as one of the "
                        + "world's worst since the 19th century."),
                ]
                for (name, article) in cases {
                    expectEqual(Quirk.pick(from: article, name: name), "",
                                "\(name) kept it")
                }
            }

            // ---- the economy is never the quirky bit
            //
            // A superlative lifts the statistics penalty, which is what Ushuaia
            // needs — and it was also lifting it for every country's GDP ranking,
            // since those are written with "largest" too.  Economics is refused
            // outright instead of merely marked down.

            Harness.test("a GDP ranking loses to anything at all") {
                let text = "Mexico is a country in North America. Mexico is a "
                    + "newly industrialized country, with the world's "
                    + "15th-largest economy by nominal GDP. Mexico is home to "
                    + "the largest number of UNESCO World Heritage Sites in "
                    + "the Americas."
                expect(Quirk.pick(from: text, name: "Mexico").contains("UNESCO"),
                       "took the GDP sentence")
            }

            Harness.test("a GDP ranking on its own is nothing") {
                let text = "Thailand is a country in Southeast Asia. Thailand's "
                    + "economy is the second-largest in the region and the 23rd "
                    + "globally by purchasing power parity."
                expectEqual(Quirk.pick(from: text, name: "Thailand"), "")
            }

            // ---- weak markers cannot carry a sentence on their own
            //
            // "One of the" and "first" read like superlatives and are not.  They
            // are what let "one of the poorest countries in the world" and "the
            // first Anglo-Afghan War" score as quotable.

            Harness.test("one of the, on its own, is not a fact") {
                let text = "Nowhereville is a town in the north. It is one of "
                    + "the towns in the northern part of the province."
                expectEqual(Quirk.pick(from: text, name: "Nowhereville"), "")
            }

            Harness.test("one of the sharpens a fact that had one already") {
                let text = "Varanasi is a city on the Ganges. It is one of the "
                    + "oldest continuously inhabited cities in the world."
                expect(Quirk.pick(from: text, name: "Varanasi").contains("continuously"),
                       "threw away a fact worth keeping")
            }

            // ---- flags are not photographs

            Harness.test("a flag, an emblem or a map is not a picture of a place") {
                let drawings = [
                    "https://upload.wikimedia.org/…/Flag_of_Algeria.svg/330px-x.png",
                    "https://upload.wikimedia.org/…/Coat_of_arms_of_Peru.svg/x.png",
                    "https://upload.wikimedia.org/…/Afghanistan_(orthographic_projection).svg/x.png",
                    "https://upload.wikimedia.org/…/India_-_Location_Map.svg/x.png",
                    "File:Emblem_of_Kazakhstan.svg",
                ]
                for drawing in drawings {
                    expect(!WikipediaMedia.isPhotograph(drawing), "let through: \(drawing)")
                }
            }

            Harness.test("a photograph of somewhere is kept") {
                let photographs = [
                    "https://upload.wikimedia.org/…/Nomads_in_Badghis_Province.jpg/500px-x.jpg",
                    "https://upload.wikimedia.org/…/Skyline_of_Beijing_CBD.jpg",
                    "File:Aizawl_city_view.JPG",
                ]
                for photograph in photographs {
                    expect(WikipediaMedia.isPhotograph(photograph), "rejected: \(photograph)")
                }
            }

            // ---- the library

            Harness.test("what is remembered is what comes back") {
                let library = MediaLibrary()
                library.remember(PlaceMedia(name: "Aizawl", fact: "Sunday silence.",
                                            image: "https://x/y.jpg", width: 320, height: 200),
                                 for: "Aizawl")
                // Found under any spelling the atlas would accept.
                expectEqual(library.media(for: "  aizawl ")?.fact, "Sunday silence.")
                expectNil(library.media(for: "Imphal"))
                expectEqual(library.count, 1)
                expectEqual(library.withPictures, 1)
            }

            Harness.test("a place looked up and found dull is not looked up again") {
                let library = MediaLibrary()
                library.remember(PlaceMedia(name: "Nowhereville"), for: "Nowhereville")
                expectEqual(library.unchecked(from: ["Nowhereville", "Aizawl"]), ["Aizawl"])
            }

            Harness.test("the file survives a round trip") {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("atlas-media-test-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: url) }
                let writing = MediaLibrary(overlayFile: url)
                writing.remember(PlaceMedia(name: "Aizawl", fact: "Sunday silence.",
                                            image: "https://x/y.jpg", width: 320, height: 200,
                                            source: "https://en.wikipedia.org/wiki/Aizawl"),
                                 for: "Aizawl")
                expect(writing.save(), "nothing was written")
                let reading = MediaLibrary()
                expectEqual(reading.load(url), 1)
                expectEqual(reading.media(for: "Aizawl")?.image, "https://x/y.jpg")
                expectEqual(reading.media(for: "Aizawl")?.width, 320)
            }

            Harness.test("nothing is written when nothing changed") {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("atlas-media-test-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: url) }
                let library = MediaLibrary(overlayFile: url)
                library.remember(PlaceMedia(name: "Aizawl"), for: "Aizawl")
                expect(library.save(), "the first save should write")
                expect(!library.save(), "the second save had nothing to do")
            }

            // ---- the trickle

            Harness.test("a country with no picture borrows its capital's") {
                var japan = Place(name: "Japan", kind: "country", fame: 99)
                japan.country = "JP"
                var tokyo = Place(name: "Tokyo", kind: "capital", fame: 95)
                tokyo.country = "JP"
                let atlas = Atlas(places: [japan, tokyo])
                let library = MediaLibrary()
                let source = StubMediaSource()
                // What Wikipedia really does: the country has prose but only a
                // flag, which the fetcher has already thrown away.
                source.stub("Japan", PlaceMedia(name: "Japan", fact: "It has 6,852 islands."))
                source.stub("Tokyo", PlaceMedia(name: "Tokyo", image: "https://x/tokyo.jpg",
                                                width: 500, height: 333))
                let harvester = MediaHarvester(atlas: atlas, library: library,
                                               source: source, interval: 0)
                harvester.start()
                let deadline = Date().addingTimeInterval(5)
                while library.count < 2 && Date() < deadline { usleep(2000) }
                harvester.stop()
                let record = library.media(for: "Japan")
                expectEqual(record?.image, "https://x/tokyo.jpg")
                expectEqual(record?.width, 500)
                // Its own fact is kept: only the missing picture was borrowed.
                expectEqual(record?.fact, "It has 6,852 islands.")
            }

            Harness.test("the harvester asks about the famous places first") {
                let atlas = Atlas(places: [
                    Place(name: "Obscuria", kind: "city", fame: 10),
                    Place(name: "Everyone Knows It", kind: "country", fame: 95),
                    Place(name: "Middling", kind: "city", fame: 50),
                ])
                let library = MediaLibrary()
                let source = StubMediaSource()
                source.stub("Everyone Knows It",
                            PlaceMedia(name: "Everyone Knows It", fact: "It is known."))
                let harvester = MediaHarvester(atlas: atlas, library: library,
                                               source: source, interval: 0)
                harvester.start()
                let deadline = Date().addingTimeInterval(5)
                while library.count < 3 && Date() < deadline { usleep(2000) }
                harvester.stop()
                expectEqual(library.count, 3)
                expectEqual(source.asked.first, "Everyone Knows It")
                expectEqual(library.media(for: "Everyone Knows It")?.fact, "It is known.")
                // Everything was looked at, so a second pass has nothing to do.
                harvester.refillQueue()
                expectEqual(harvester.progress.left, 0)
            }
        }
    }
}
