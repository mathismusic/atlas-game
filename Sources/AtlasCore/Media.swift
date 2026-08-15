import Foundation
// URLSession lives in a separate module on Linux, which is where a deployed
// server runs even though every one of these was written on a Mac.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A picture and a quirky line for one place.
///
/// Kept apart from ``Place`` on purpose.  The atlas is the rulebook — it decides
/// what may be played and is compiled into the binary — while this is decoration
/// that arrives late, over the network, and can be thrown away and fetched
/// again.  Mixing them would mean a game could not start until Wikipedia
/// answered.
public struct PlaceMedia: Codable, Sendable, Equatable {
    /// The place's name as the atlas spells it, so a hand-edited file can be read.
    public var name: String
    /// One sentence worth knowing, or empty if the article had nothing quirky.
    public var fact: String
    /// A thumbnail URL on Wikimedia, or empty.
    public var image: String
    public var width: Int
    public var height: Int
    /// The article both came from, for the curious and for blame.
    public var source: String
    /// Whether the lookup happened at all.  A place with no picture and no fact
    /// is not the same as a place nobody has looked up yet, and without this the
    /// harvester would ask about the dull ones for ever.
    public var checked: Bool

    public init(name: String, fact: String = "", image: String = "",
                width: Int = 0, height: Int = 0, source: String = "",
                checked: Bool = true) {
        self.name = name
        self.fact = fact
        self.image = image
        self.width = width
        self.height = height
        self.source = source
        self.checked = checked
    }

    enum CodingKeys: String, CodingKey {
        case name = "n", fact = "q", image = "i", width = "w", height = "h"
        case source = "s", checked = "c"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        fact = try c.decodeIfPresent(String.self, forKey: .fact) ?? ""
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        checked = try c.decodeIfPresent(Bool.self, forKey: .checked) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        if !fact.isEmpty { try c.encode(fact, forKey: .fact) }
        if !image.isEmpty {
            try c.encode(image, forKey: .image)
            try c.encode(width, forKey: .width)
            try c.encode(height, forKey: .height)
        }
        if !source.isEmpty { try c.encode(source, forKey: .source) }
        if !checked { try c.encode(checked, forKey: .checked) }
    }

    /// Whether there is anything here worth showing a player.
    public var isEmpty: Bool { fact.isEmpty && image.isEmpty }
}

// MARK: - Picking the quirky line

/// Turns a Wikipedia opening paragraph into the one line worth reading aloud.
///
/// The game already says where a place is — *Chiclayo is a city in north-west
/// Peru* — so the definition sentence is exactly the sentence not to use.  What
/// is wanted is the next thing along: the oldest, the largest, the only one, the
/// thing it is known for.
public enum Quirk {

    /// Phrases that make a sentence worth repeating.  Ordered by how reliably
    /// the sentence they appear in turns out to be interesting.
    static let markers: [String] = [
        "known for", "famous for", "best known", "renowned", "home to",
        "named after", "birthplace", "world's", "oldest", "largest", "smallest",
        "highest", "deepest", "longest", "only", "unesco",
        "world heritage", "nickname", "nicknamed", "legend", "founded in",
        "ancient", "the site of", "known as", "referred to as",
    ]

    /// Phrases that sharpen a sentence which already had something to say, but
    /// that cannot earn a sentence its place on their own.
    ///
    /// *One of the* and *first* are the two that had to be demoted.  They read
    /// like superlatives and are not: *Niger is one of the poorest countries in
    /// the world* and *the first Anglo-Afghan War* both scored as quotable on
    /// the strength of nothing but those words.  Kept as tie-breakers, because
    /// *one of the oldest continuously inhabited cities* really is better than
    /// the same sentence without them.
    static let nuance: [String] = ["one of the", "first"]

    /// The markers that describe a place rather than merely rank it, and that
    /// are worth keeping even in a sentence that also quotes a population.
    ///
    /// *Ushuaia claims the title of world's southernmost city* is the whole
    /// reason anyone mentions Ushuaia, and it was being thrown away for saying
    /// "population of 89,606" in the same breath — losing to "it is the only
    /// municipality in the Department of Ushuaia".
    static let superlatives: [String] = [
        "world's", "unesco", "world heritage", "oldest", "highest", "deepest",
        "longest", "smallest", "birthplace", "known for", "famous for",
        "best known", "renowned",
    ]

    /// Boilerplate: refused outright, whatever else the sentence carries.
    ///
    /// This is the group that had to be learned the hard way.  Every country's
    /// article says which of its cities is the biggest, in a sentence carrying
    /// the word *largest* — so a naive superlative hunt comes back from two
    /// hundred countries with two hundred identical lines about capital cities.
    /// These are the exact phrasings that boilerplate takes; they are narrow on
    /// purpose, so that a real superlative — Beijing being the world's most
    /// populous capital — is not refused with them.
    /// The second group is economics.  A country's lead always ranks its
    /// economy, always in a sentence carrying *largest* — and because a
    /// superlative is exactly what lifts the statistics penalty below, those
    /// sentences kept winning: Mexico by nominal GDP, Thailand by purchasing
    /// power parity, South Africa by Gini coefficient.  There is no arrangement
    /// of those words that is a quirky fact, so they are refused outright rather
    /// than merely marked down.
    static let boilerplate: [String] = [
        "capital and largest", "country's capital", "country's largest city",
        "largest city of", "is the capital", "subdivided into", "federal state",
        "nation's political", "and largest city,", "administrative centre of",
        "administrative center of", "is divided into", "consists of",
        // ...and every rephrasing of it a real harvest turned up.  Which
        // settlement is the biggest is the one thing the game never needs told.
        "also its largest city", "largest and most populous", "most populous city",
        "most populous municipality", "most populous island", "largest city in",
        "largest metropolitan area is", "second-largest city",
        "largest city by population", "the largest city and",
        // economics
        "gdp", "purchasing power parity", "gini", "gross domestic product",
        "developing country", "developed country", "newly industrialized",
        "economic output", "economic growth", "foreign private investment",
        "immigrant population",
    ]

    /// Statistics: penalised heavily, but not fatal — a sentence that has
    /// something to say may still quote a number while saying it.
    static let dry: [String] = [
        "population of", "census", "metropolitan area had", "square kilometres",
        "square miles", "as of", "per capita",
    ]

    /// Refused outright: the register a party game should not be in.
    ///
    /// Reading a whole lead rather than two sentences finds far better facts and
    /// also finds much worse ones, because the back half of a country's lead is
    /// its wars and its politics.  A first run of this came back with Goma
    /// "occupied by the M23 rebels", the Anglo-Afghan wars, Juche, and Niger
    /// being one of the poorest countries in the world — every one of them
    /// scored as interesting, because *the site of*, *first* and *one of the*
    /// are exactly the phrases that make a sentence quotable.
    ///
    /// A place that has nothing else to say keeps its picture and says nothing,
    /// which is the right outcome: silence is better than a war under a place
    /// name in a game about spelling.
    ///
    /// Deliberately no bare "war" — Warsaw contains it — hence the spacing.
    static let unsuitable: [String] = [
        // violence
        "massacre", "genocide", "atrocit", "killed", "death toll", "executed",
        "slaughter", "terrorist", "assassinat", "bombing", "concentration camp",
        "ethnic cleansing", "casualties", "died in the", "deaths",
        " war ", " war,", " war.", " wars", "warfare", "anglo-", "invasion",
        "invaded", "occupied", "rebel", "insurgen", "militia", "conflict",
        "strife", "armed forces", "military", "nuclear",
        // rule
        "coup", "regime", "dictator", "authoritarian", "junta", "communist",
        "one-party", "consolidated power", "great power", "middle power",
        "president", "prime minister", "sanctions",
        // hardship
        "famine", "epidemic", "poorest", "poverty", "refugee", "corruption",
        "slave", "least developed", "lowest of any", "underdevelop",
        "humanitarian", "in need of", "economic crisis", "unequal",
        "inequality", "displaced",
        // empire.  Not a bare "colony": the best fact about half the islands in
        // the atlas is the size of the penguin colony on them.  These are the
        // phrasings that mean the other thing.
        "colonial", "colonis", "coloniz", "colony of the", "crown colony",
        "colony known as", "established rule", "german colony",
        "british colony", "french colony", "spanish colony", "portuguese colony",
        "protectorate", "evacuation", "attacks", "forced to flee",
    ]

    static let maxLength = 190
    static let minLength = 30

    /// Splits on sentence ends, keeping abbreviations whole.
    ///
    /// A plain split on ". " cuts *St. Petersburg* in half and turns every
    /// article about a saint into a fragment.
    public static func sentences(_ text: String) -> [String] {
        let abbreviations: Set<String> = [
            "st", "mt", "ft", "no", "co", "inc", "ltd", "dr", "mr", "mrs", "ms",
            "approx", "est", "c", "ca", "e.g", "i.e", "vs", "etc", "jr", "sr",
        ]
        var out: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let next = text.index(after: index)
                let follows = next < text.endIndex ? text[next] : " "
                // A full stop only ends a sentence when a space and a capital
                // follow it, and when the word before it is not an abbreviation.
                // Hyphens count as word breaks: the last word of *the Mexico–U.S.
                // border* is the acronym, not the whole compound.
                let lastWord = current
                    .split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "-"
                                             || $0 == "–" || $0 == "—" }).last
                    .map { String($0).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,")) } ?? ""
                // A lone initial — the J. R. R. of a name — never ends a sentence.
                let isInitial = lastWord.count == 1 && lastWord.first?.isLetter == true
                // A dotted acronym: U.S., D.C., U.K.  Rhode Island's whole fact
                // used to be "Rhode Island is the smallest U.S." because the stop
                // after the S looked like the end of a sentence.  These cannot be
                // refused outright the way St. is, because a sentence really does
                // often end on one — "…the smallest state in the U.S. It was…" —
                // so the capital that follows decides.
                let pieces = lastWord.split(separator: ".", omittingEmptySubsequences: true)
                let isAcronym = lastWord.contains(".") && pieces.count > 1
                    && pieces.allSatisfy { $0.count == 1 && $0.first?.isLetter == true }
                // Except the football clubs, which are never the last thing said:
                // the capital after them is the town the club is named for —
                // *the Estadio Akron, C.D. Guadalajara's official stadium*.
                let clubs: Set<String> = ["f.c", "c.d", "a.c", "s.c", "a.s", "s.v", "c.f"]
                let isAbbreviation = abbreviations.contains(lastWord) || isInitial
                    || clubs.contains(lastWord)
                    || (isAcronym && !startsSentence(text, from: next))
                if !isAbbreviation, follows == " " || follows == "\n" {
                    out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                }
            }
            index = text.index(after: index)
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out.filter { !$0.isEmpty }
    }

    /// Whether the next word after `from` reads like the opening of a sentence.
    ///
    /// Only consulted for the ambiguous stops — the ones after an acronym — where
    /// a capital is the only evidence there is.  End of text counts as a start, so
    /// a lead ending "…in the U.S." keeps its last sentence.
    private static func startsSentence(_ text: String, from: String.Index) -> Bool {
        var i = from
        while i < text.endIndex, text[i] == " " || text[i] == "\n" { i = text.index(after: i) }
        guard i < text.endIndex else { return true }
        return text[i].isUppercase
    }

    /// Strips the pronunciation clutter Wikipedia opens with — the IPA, the
    /// native spellings, the "listen" links — which is unreadable on a phone.
    public static func clean(_ sentence: String) -> String {
        var s = sentence
        // Bracketed asides, innermost first, so nesting unwinds.
        while let open = s.range(of: "(", options: .backwards),
              let close = s.range(of: ")", range: open.upperBound..<s.endIndex) {
            s.removeSubrange(open.lowerBound..<close.upperBound)
        }
        s = s.replacingOccurrences(of: " ,", with: ",")
        s = s.replacingOccurrences(of: "  ", with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The best line in `extract` about a place called `name`, or "" for none.
    public static func pick(from extract: String, name: String) -> String {
        let all = sentences(extract)
        guard all.count > 1 else { return "" }
        var best = ""
        var bestScore = 0
        // The first sentence is the definition, which the game already says in
        // its own words; start at the second.
        for raw in all.dropFirst() {
            let sentence = clean(raw)
            guard sentence.count >= minLength, sentence.count <= maxLength else { continue }
            guard sentence.hasSuffix(".") || sentence.hasSuffix("!") else { continue }
            let low = sentence.lowercased()
            if boilerplate.contains(where: { low.contains($0) }) { continue }
            if unsuitable.contains(where: { low.contains($0) }) { continue }
            var score = 1
            var strong = 0
            for marker in markers where low.contains(marker) { strong += 1 }
            score += strong * 3
            // Only once the sentence has earned its place on a real marker.
            if strong > 0 {
                for marker in nuance where low.contains(marker) { score += 1 }
            }
            // A statistic drags a sentence down, unless the sentence is quoting
            // it in the course of saying something worth hearing.
            if !superlatives.contains(where: { low.contains($0) }) {
                for statistic in dry where low.contains(statistic) { score -= 4 }
            }
            // A sentence that opens with a pronoun reads oddly on its own, but
            // is still better than nothing.
            if low.hasPrefix("it ") || low.hasPrefix("its ") { score -= 1 }
            // Naming the place makes the line stand alone.
            if low.contains(name.lowercased()) { score += 1 }
            if score > bestScore {
                bestScore = score
                best = sentence
            }
        }
        // Something merely factual is not worth the screen space: a line has to
        // have earned at least one marker.
        return bestScore >= 4 ? best : ""
    }
}

// MARK: - The library

/// Everything known about pictures and facts, in memory, with a file behind it.
///
/// Two files, in fact: one shipped with the game and one written as the game
/// learns, exactly as the atlas has `atlas.json` and `learned.json`.  A free
/// host with a disk that empties on restart therefore still starts up knowing
/// five thousand facts.
public final class MediaLibrary: @unchecked Sendable {

    private let lock = NSLock()
    private var records: [String: PlaceMedia] = [:]
    /// Records added since the last save, so a trickle does not rewrite the
    /// whole file every second.
    private var dirty = false
    private let overlayFile: URL?

    public init(overlayFile: URL? = nil) {
        self.overlayFile = overlayFile
    }

    /// Loads a file of records, keeping anything already known.  Later calls
    /// win, so load the shipped file first and the overlay second.
    @discardableResult
    public func load(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode([String: PlaceMedia].self, from: data)
        else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        for (key, value) in payload { records[key] = value }
        return payload.count
    }

    public func media(for name: String) -> PlaceMedia? {
        let key = Normalize.key(name)
        lock.lock()
        defer { lock.unlock() }
        return records[key]
    }

    public func remember(_ media: PlaceMedia, for name: String) {
        let key = Normalize.key(name)
        guard !key.isEmpty else { return }
        lock.lock()
        records[key] = media
        dirty = true
        lock.unlock()
    }

    /// Names, in the order given, that nobody has looked up yet.
    public func unchecked(from names: [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return names.filter { records[Normalize.key($0)] == nil }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }

    public var withPictures: Int {
        lock.lock(); defer { lock.unlock() }
        return records.values.filter { !$0.image.isEmpty }.count
    }

    public var withFacts: Int {
        lock.lock(); defer { lock.unlock() }
        return records.values.filter { !$0.fact.isEmpty }.count
    }

    /// Writes the overlay if anything has changed.  Safe to call often.
    @discardableResult
    public func save(force: Bool = false) -> Bool {
        guard let url = overlayFile else { return false }
        lock.lock()
        guard dirty || force else { lock.unlock(); return false }
        let snapshot = records
        dirty = false
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Write beside and rename: a harvester killed mid-write must not leave
        // half a file where five thousand facts used to be.
        let temporary = url.appendingPathExtension("tmp")
        guard (try? data.write(to: temporary)) != nil else { return false }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: temporary)
        return true
    }

    /// Everything, for writing a shippable file elsewhere.
    public var all: [String: PlaceMedia] {
        lock.lock(); defer { lock.unlock() }; return records
    }
}

// MARK: - Fetching

/// Where a picture and a fact come from.  A protocol so the tests never touch
/// the network and the simulator never waits for it.
public protocol MediaSource: Sendable {
    func look(_ name: String, country: String,
              completion: @escaping @Sendable (PlaceMedia?) -> Void)
}

/// Wikipedia's REST summary, which carries a thumbnail and an opening paragraph
/// in one request — the same endpoint the challenge lookup already uses.
public final class WikipediaMedia: MediaSource {

    private let session: URLSession

    public init(timeout: TimeInterval = 8) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 3
        cfg.httpAdditionalHeaders = [
            "User-Agent": "AtlasGame/1.0 (local hotseat game; contact: local user)",
            "Accept": "application/json",
        ]
        session = URLSession(configuration: cfg)
    }

    /// One article, as the action API returns it under `formatversion=2`.
    ///
    /// The obvious endpoint is the REST one, `/page/summary`, and that is what
    /// this used to ask.  It is the wrong endpoint: it is *defined* to return
    /// the first two or three sentences of the lead, and the first of those is
    /// the definition the game already says in its own words.  So Kyoto came
    /// back as its population, Bruges as which end of Belgium it is in, and
    /// Timbuktu with nothing at all — one place in three had a fact, and most
    /// of those were demographics.
    ///
    /// This asks for the whole lead section instead, which is where an article
    /// puts the reason anyone has heard of the place, and takes the picture,
    /// the canonical URL and the disambiguation flag from the same request, so
    /// it costs no more traffic than the endpoint it replaced.
    private struct Article: Decodable {
        struct Image: Decodable { var source: String?; var width: Int?; var height: Int? }
        var title: String?
        var description: String?
        var extract: String?
        var thumbnail: Image?
        var fullurl: String?
        var missing: Bool?
        /// Asked for as `ppprop=disambiguation`, so the only key that can
        /// appear is that one, and its value is the empty string.
        var pageprops: [String: String]?
    }

    private struct ActionReply: Decodable {
        struct Query: Decodable { var pages: [Article]? }
        var query: Query?
    }

    public func look(_ name: String, country: String,
                     completion: @escaping @Sendable (PlaceMedia?) -> Void) {
        // The bare name first: for a place famous enough to be in this atlas it
        // is usually the article.  Qualifying every name with its country would
        // send "France" to "France, France".
        fetch(title: name) { [weak self] first in
            guard let self else { return completion(nil) }
            if let first, self.isAboutAPlace(first) {
                return self.illustrate(self.record(name: name, from: first),
                                       title: first.title ?? name, then: completion)
            }
            // A disambiguation page, a person, or nothing: ask again the way a
            // player would have to — "Tanga, Tanzania".
            guard !country.isEmpty else { return completion(first == nil ? nil : .init(name: name)) }
            self.fetch(title: "\(name), \(country)") { second in
                guard let second, self.isAboutAPlace(second) else {
                    // Looked up, nothing usable.  Recorded as checked so the
                    // harvester does not come back to it every night.
                    return completion(PlaceMedia(name: name))
                }
                self.illustrate(self.record(name: name, from: second),
                                title: second.title ?? name, then: completion)
            }
        }
    }

    /// Finds a photograph for a record that has none.
    ///
    /// Every country's article leads with its flag, and the summary endpoint
    /// hands back exactly that: ask two hundred countries for a picture and get
    /// two hundred flags, which is a quiz about vexillology and not a game about
    /// places.  The list of everything on the page usually has a photograph a
    /// few items down, past the flag, the arms and the locator map.
    private func illustrate(_ record: PlaceMedia, title: String,
                            then completion: @escaping @Sendable (PlaceMedia?) -> Void) {
        guard record.image.isEmpty else { return completion(record) }
        pictures(title: title) { picture in
            var filled = record
            filled.image = picture ?? ""
            completion(filled)
        }
    }

    /// Wikipedia hangs analytics parameters off the image URLs it hands out.
    /// The game has no business passing those on to a player's phone, and the
    /// bare URL is the one that caches.
    public static func tidy(_ url: String) -> String {
        let bare = url.split(separator: "?").first.map(String.init) ?? url
        return bare.hasPrefix("//") ? "https:" + bare : bare
    }

    /// Whether a URL or file name looks like a photograph of somewhere rather
    /// than a drawing of a flag, an emblem or a map.  Wikipedia renders all of
    /// those from SVG, so the extension alone catches most of them.
    public static func isPhotograph(_ reference: String) -> Bool {
        let low = reference.lowercased()
        if low.contains(".svg") { return false }
        let drawings = ["flag_", "flag of", "coat_of_arms", "arms_of", "emblem",
                        "seal_of", "location_map", "locator", "orthographic",
                        "logo", "map_of", "_map.", "-map.", "blank_", "icon"]
        return !drawings.contains { low.contains($0) }
    }

    private struct MediaList: Decodable {
        struct Item: Decodable {
            struct Source: Decodable { var src: String? }
            var title: String?
            var type: String?
            var showInGallery: Bool?
            var srcset: [Source]?
        }
        var items: [Item]?
    }

    private func pictures(title: String,
                          completion: @escaping @Sendable (String?) -> Void) {
        guard let url = restURL(path: "media-list", title: title) else {
            return completion(nil)
        }
        session.dataTask(with: url) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
                  let list = try? JSONDecoder().decode(MediaList.self, from: data)
            else { return completion(nil) }
            for item in list.items ?? [] where item.type == "image" {
                guard item.showInGallery != false,
                      let source = item.srcset?.first?.src,
                      Self.isPhotograph(item.title ?? ""), Self.isPhotograph(source)
                else { continue }
                completion(Self.tidy(source))
                return
            }
            completion(nil)
        }.resume()
    }

    /// Guards against illustrating Georgia the country with Georgia the state,
    /// and against a disambiguation page's stub picture.
    private func isAboutAPlace(_ a: Article) -> Bool {
        if a.missing == true || a.pageprops?["disambiguation"] != nil { return false }
        // Only the opening is judged, not the whole lead.  This asks whether the
        // article is about a place, and a long enough lead about a real city
        // will mention a footballer or a band sooner or later — which used to be
        // impossible, back when the text was three sentences long, and would now
        // throw away good articles for a word in their fourth paragraph.
        let opening = Quirk.sentences(a.extract ?? "").prefix(2).joined(separator: " ")
        let blob = [a.description ?? "", opening].joined(separator: " ")
        if PlaceWords.contains(blob, any: PlaceWords.negative) { return false }
        return PlaceWords.contains(blob, any: PlaceWords.positive)
    }

    private func record(name: String, from a: Article) -> PlaceMedia {
        // A flag is not a picture of anywhere.  Dropping it here is what sends
        // the record on to `illustrate` to go looking for a real photograph.
        let usable = (a.thumbnail?.source).flatMap { Self.isPhotograph($0) ? a.thumbnail : nil }
        return PlaceMedia(
            name: name,
            fact: Quirk.pick(from: a.extract ?? "", name: name),
            image: usable.map { Self.tidy($0.source ?? "") } ?? "",
            width: usable?.width ?? 0,
            height: usable?.height ?? 0,
            source: a.fullurl ?? "")
    }

    private func restURL(path: String, title: String) -> URL? {
        let escaped = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard !escaped.isEmpty else { return nil }
        return URL(string:
            "https://en.wikipedia.org/api/rest_v1/page/\(path)/\(escaped)?redirect=true")
    }

    /// The lead section, the lead image, the canonical URL and whether the page
    /// is a disambiguation, in one request.
    private func articleURL(title: String) -> URL? {
        let escaped = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard !escaped.isEmpty else { return nil }
        return URL(string: "https://en.wikipedia.org/w/api.php?action=query&format=json"
            + "&formatversion=2&redirects=1"
            + "&prop=extracts%7Cpageimages%7Cinfo%7Cdescription%7Cpageprops"
            // `exintro` is the whole lead and no further: past it an article is
            // history, and history is where the fact stops being quirky.
            + "&exintro=1&explaintext=1"
            + "&piprop=thumbnail&pithumbsize=640&inprop=url&ppprop=disambiguation"
            + "&titles=\(escaped)")
    }

    private func fetch(title: String,
                       completion: @escaping @Sendable (Article?) -> Void) {
        guard let url = articleURL(title: title) else { return completion(nil) }
        session.dataTask(with: url) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let reply = try? JSONDecoder().decode(ActionReply.self, from: data),
                  let article = reply.query?.pages?.first
            else { return completion(nil) }
            completion(article)
        }.resume()
    }
}

/// A source that answers from a table.  Tests and the simulator use this.
public final class StubMediaSource: MediaSource, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: PlaceMedia] = [:]
    public private(set) var asked: [String] = []

    public init() {}

    public func stub(_ name: String, _ media: PlaceMedia) {
        lock.lock(); answers[Normalize.key(name)] = media; lock.unlock()
    }

    public func look(_ name: String, country: String,
                     completion: @escaping @Sendable (PlaceMedia?) -> Void) {
        lock.lock()
        asked.append(name)
        let answer = answers[Normalize.key(name)] ?? PlaceMedia(name: name)
        lock.unlock()
        completion(answer)
    }
}

// MARK: - The trickle

/// Fills the library in the background, one place at a time, for ever.
///
/// Deliberately slow.  Five thousand places is five thousand requests, and the
/// polite way to take them off a free encyclopedia is one a second while nobody
/// is waiting — the game never blocks on this, and a place with no picture yet
/// simply shows none.
public final class MediaHarvester: @unchecked Sendable {

    private let atlas: Atlas
    private let library: MediaLibrary
    private let source: MediaSource
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "atlas.media.harvest")
    private var running = false
    private var pending: [String] = []
    private var done = 0
    private let lock = NSLock()

    public var progress: (done: Int, left: Int) {
        lock.lock(); defer { lock.unlock() }; return (done, pending.count)
    }

    public init(atlas: Atlas, library: MediaLibrary, source: MediaSource,
                interval: TimeInterval = 1.0) {
        self.atlas = atlas
        self.library = library
        self.source = source
        self.interval = interval
    }

    /// Most famous first: those are the places most likely to be played today,
    /// and the ones whose articles are worth reading.
    public func refillQueue() {
        let names = atlas.allPlaces.sorted { $0.fame > $1.fame }.map(\.name)
        let todo = library.unchecked(from: names)
        lock.lock()
        pending = todo
        lock.unlock()
    }

    public func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        refillQueue()
        step()
    }

    public func stop() {
        lock.lock(); running = false; lock.unlock()
        library.save()
    }

    /// One place, then a pause, then the next.  Written as a chain of
    /// `asyncAfter` rather than a loop with a sleep so that stopping is
    /// immediate and nothing is left blocked on a socket.
    private func step() {
        lock.lock()
        guard running, !pending.isEmpty else {
            let stillRunning = running
            lock.unlock()
            if stillRunning { library.save() }
            return
        }
        let next = pending.removeFirst()
        lock.unlock()

        let place = atlas.surface(matching: next).flatMap { atlas.place($0.placeID) }
        let country = place?.countryName ?? ""
        source.look(next, country: country) { [weak self] media in
            guard let self else { return }
            let record = media ?? PlaceMedia(name: next)
            guard let stand = self.standIn(for: place) else {
                return self.finish(record, for: next)
            }
            // A country: whatever picture came back is from deep in its own
            // article and is almost certainly a battle or a portrait, so the
            // capital's photograph is preferred outright rather than as a
            // fallback.  The country's own picture is the fallback.
            self.source.look(stand, country: country) { other in
                var filled = record
                if let borrowed = other, !borrowed.image.isEmpty {
                    filled.image = borrowed.image
                    filled.width = borrowed.width
                    filled.height = borrowed.height
                }
                self.finish(filled, for: next)
            }
        }
    }

    /// The place to photograph when the place itself has no photograph.
    ///
    /// A country's article opens with its flag, and everything after that is its
    /// history — portraits, battles, maps drawn in 1575.  There is no picture of
    /// *Japan* on the page, and the honest substitute is the one every atlas and
    /// every quiz uses: its capital city, which does have a photograph of a real
    /// street on a real morning.
    private func standIn(for place: Place?) -> String? {
        guard let place, place.kind == "country", !place.country.isEmpty else { return nil }
        return atlas.allPlaces.first {
            $0.kind == "capital" && $0.country == place.country
        }?.name
    }

    private func finish(_ record: PlaceMedia, for name: String) {
        library.remember(record, for: name)
        lock.lock()
        done += 1
        let count = done
        lock.unlock()
        // Often enough that a crash costs a minute of work, rarely enough that
        // the file is not rewritten five thousand times.
        if count % 25 == 0 { library.save() }
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in self?.step() }
    }
}
