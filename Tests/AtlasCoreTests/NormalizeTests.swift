import Foundation
import AtlasCore

/// Normalisation decides two separate things: which typed strings mean the same
/// place (`key`) and which letter the chain continues on (`letters`).  Getting
/// either wrong is invisible until a player is wrongly told they are cheating.
enum NormalizeTests {

    static func run() {
        Harness.suite("normalisation") {

            Harness.test("key ignores punctuation, spacing and case") {
                expectEqual(Normalize.key("St. Lucia"), Normalize.key("  st lucia  "))
                expectEqual(Normalize.key("New-York"), Normalize.key("new york"))
                expectEqual(Normalize.key("Côte d'Ivoire"), Normalize.key("cote divoire"))
                // "St" and "Saint" are different words; the atlas carries both
                // spellings as aliases rather than pretending otherwise here.
                expectNotEqual(Normalize.key("St Lucia"), Normalize.key("Saint Lucia"))
            }

            Harness.test("key folds accents and awkward letters") {
                expectEqual(Normalize.key("Zürich"), "zurich")
                expectEqual(Normalize.key("Tromsø"), "tromso")
                expectEqual(Normalize.key("Reykjavík"), "reykjavik")
                expectEqual(Normalize.key("Łódź"), "lodz")
                expectEqual(Normalize.key("İstanbul"), "istanbul")
            }

            Harness.test("distinct places keep distinct keys") {
                expectNotEqual(Normalize.key("Austria"), Normalize.key("Australia"))
                expectNotEqual(Normalize.key("Niger"), Normalize.key("Nigeria"))
            }

            Harness.test("chain letters ignore digits and punctuation") {
                expectEqual(Normalize.lastLetter("Xi'an"), "n")
                expectEqual(Normalize.firstLetter("  Ürümqi"), "u")
                expectEqual(Normalize.lastLetter("Rio de Janeiro"), "o")
                expectEqual(Normalize.lastLetter("Springfield (1)"), "d")
            }

            Harness.test("letters on empty or symbol-only input") {
                expectNil(Normalize.firstLetter(""))
                expectNil(Normalize.lastLetter("🌍🌎"))
                expectNil(Normalize.firstLetter("!!! 123 !!!"))
            }

            Harness.test("tidy collapses whitespace and trims") {
                expectEqual(Normalize.tidy("  new    delhi \n"), "new delhi")
            }

            Harness.test("display case titles lowercase input only") {
                expectEqual(Normalize.displayCase("new delhi"), "New Delhi")
                // Anything already carrying capitals is left alone — "McMurdo"
                // and "Rio de Janeiro" both lose meaning if re-cased.
                expectEqual(Normalize.displayCase("Rio de Janeiro"), "Rio de Janeiro")
            }
        }
    }
}
