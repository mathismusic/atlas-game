import Foundation

/// One real-world place.  A place has a canonical display name plus any number
/// of alternative surface forms (`Bombay` for `Mumbai`, `USA` for
/// `United States`).  All surfaces resolve to the same identity, so a place can
/// only be played once no matter which name is used — but the chain letter
/// comes from the surface the player actually typed.
public struct Place: Codable, Sendable, Equatable {
    public var name: String
    public var kind: String
    public var country: String
    /// 0-100 recognisability score.  Gates bot difficulty, never legality.
    public var fame: Int
    public var aliases: [String]
    /// True for places learned at runtime through a challenge.
    public var learned: Bool

    // Everything below is what the game needs to say a sentence about a place,
    // and what the card deck makes its rules out of.  All of it is optional:
    // a place admitted by a challenge arrives with a name and nothing else, and
    // has to keep working.

    /// Country the place is in, spelled out.  Empty for countries themselves
    /// and for anything spanning more than one — the Danube, the Andes.
    public var countryName: String
    /// `AF`, `AS`, `EU`, `NA`, `SA`, `OC`, `AN`, or empty for the oceans.
    public var continent: String
    /// The language a player would name for the country, already readable:
    /// "French", "Hindi and English".
    public var language: String
    /// Which part of its country the place sits in: "north-west", "centre".
    /// For a country, which part of its continent.
    public var side: String
    public var latitude: Double?
    public var longitude: Double?

    enum CodingKeys: String, CodingKey {
        case name = "n", kind = "k", country = "c", fame = "f", aliases = "a"
        case learned = "l", countryName = "cn", continent = "t", language = "g"
        case side = "w", latitude = "y", longitude = "x"
    }

    public init(name: String, kind: String, country: String = "", fame: Int,
                aliases: [String] = [], learned: Bool = false,
                countryName: String = "", continent: String = "",
                language: String = "", side: String = "",
                latitude: Double? = nil, longitude: Double? = nil) {
        self.name = name
        self.kind = kind
        self.country = country
        self.fame = fame
        self.aliases = aliases
        self.learned = learned
        self.countryName = countryName
        self.continent = continent
        self.language = language
        self.side = side
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "place"
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? ""
        fame = try c.decodeIfPresent(Int.self, forKey: .fame) ?? 60
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        learned = try c.decodeIfPresent(Bool.self, forKey: .learned) ?? false
        countryName = try c.decodeIfPresent(String.self, forKey: .countryName) ?? ""
        continent = try c.decodeIfPresent(String.self, forKey: .continent) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        side = try c.decodeIfPresent(String.self, forKey: .side) ?? ""
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
    }

    /// Only the fields worth keeping for a learned place: the rest would be
    /// empty anyway, and `learned.json` is written on every admitted challenge.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        if !country.isEmpty { try c.encode(country, forKey: .country) }
        if fame != 60 { try c.encode(fame, forKey: .fame) }
        if !aliases.isEmpty { try c.encode(aliases, forKey: .aliases) }
        if learned { try c.encode(learned, forKey: .learned) }
        if !countryName.isEmpty { try c.encode(countryName, forKey: .countryName) }
        if !continent.isEmpty { try c.encode(continent, forKey: .continent) }
        if !language.isEmpty { try c.encode(language, forKey: .language) }
        if !side.isEmpty { try c.encode(side, forKey: .side) }
        try c.encodeIfPresent(latitude, forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
    }
}

/// The one-line geography lesson a place gets when it is played.
///
/// The point is to learn something in passing, so the sentence leads with the
/// country and works outwards, and simply stops early when a fact is missing
/// rather than printing a gap.  A place that arrived through a challenge knows
/// nothing about itself and gets no line at all.
extension Place {
    /// "eastern", "north-western", "central" — the adjective for `side`.
    static func adjective(_ side: String) -> String {
        switch side {
        case "centre": return "central"
        case "north": return "northern"
        case "south": return "southern"
        case "east": return "eastern"
        case "west": return "western"
        default:
            // "north-west" -> "north-western"
            return side.hasSuffix("east") || side.hasSuffix("west")
                ? side + "ern"
                : side
        }
    }

    static let continentNames = [
        "AF": "Africa", "AS": "Asia", "EU": "Europe", "NA": "North America",
        "SA": "South America", "OC": "Oceania", "AN": "Antarctica",
    ]

    public var continentName: String { Place.continentNames[continent] ?? "" }

    /// Countries that are always spoken of with a "the".
    static let definiteArticle: Set<String> = [
        "Netherlands", "Philippines", "Maldives", "Bahamas", "Gambia",
        "Comoros", "Seychelles", "Congo", "DR Congo", "Ivory Coast",
        "Côte d'Ivoire", "Vatican", "Hague", "Sudan",
    ]

    /// Splits a country name into its article and the rest, so the article can
    /// be moved in front of an adjective — "the western Netherlands", not
    /// "western The Netherlands".  GeoNames spells a few countries with the
    /// article attached, which is where the capital T comes from.
    static func article(_ region: String) -> (the: String, name: String) {
        if region.hasPrefix("The ") { return ("the ", String(region.dropFirst(4))) }
        let bare = region
        let takesThe = definiteArticle.contains(bare)
            || bare.hasPrefix("United ")
            || bare.hasSuffix(" Islands")
            || bare.hasSuffix(" Republic")
        return (takesThe ? "the " : "", bare)
    }

    /// Where the place is, as a phrase: "eastern France", "west Africa",
    /// "the western Netherlands".
    var whereabouts: String {
        let full = countryName.isEmpty ? continentName : countryName
        // Africa is not in Africa.
        guard !full.isEmpty, full != name else { return "" }
        let (the, region) = Place.article(full)
        guard !side.isEmpty else { return the + region }
        // A country is described relative to its continent, which reads better
        // bare — "west Africa", not "western Africa".
        return countryName.isEmpty
            ? "\(side) \(region)"
            : "\(the)\(Place.adjective(side)) \(region)"
    }

    public var blurb: String {
        // A capital is more interesting as what it is the capital *of*.
        if kind == "capital", !countryName.isEmpty {
            let (the, region) = Place.article(countryName)
            let line = "the capital of \(the)\(region)"
            let placed = side.isEmpty ? line : "\(line), in the \(side)"
            guard !language.isEmpty else { return placed }
            return "\(placed), where \(language) \(spokenVerb)"
        }
        let noun = name.hasSuffix("Ocean") ? "ocean" : kind
        let article = "aeiou".contains(noun.first ?? "x") ? "an" : "a"
        let place = whereabouts.isEmpty ? noun : "\(noun) in \(whereabouts)"
        guard !language.isEmpty else { return "\(article) \(place)" }
        return "\(article) \(place), where \(language) \(spokenVerb)"
    }

    private var spokenVerb: String {
        language.contains(" and ") || language.contains(", ") ? "are spoken" : "is spoken"
    }
}

/// Index of every place identity, keyed by every surface form.
public final class Atlas: @unchecked Sendable {

    /// A playable name string bound to a place identity.
    public struct Surface: Sendable {
        public let text: String
        public let placeID: Int
        public let first: Character
        public let last: Character
        public let fame: Int
        public let isCanonical: Bool
    }

    private let lock = NSLock()
    private var _places: [Place] = []
    private var _surfaces: [Surface] = []
    /// normalized surface key -> index into `_surfaces`
    private var keyToSurface: [String: Int] = [:]
    /// first letter -> indices of *canonical* surfaces, fame-descending
    private var canonicalByLetter: [Character: [Int]] = [:]

    public init(places: [Place] = []) {
        for p in places { insert(p) }
    }

    // MARK: - Loading

    private struct Payload: Codable { var version: Int; var places: [Place] }

    /// The atlas compiled into the binary.
    public static func bundled() throws -> Atlas {
        let data = Data(AtlasResource.atlas_json)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return Atlas(places: payload.places)
    }

    /// Bundled atlas plus any places learned through past challenges.
    public static func standard(learnedFile: URL? = nil) -> Atlas {
        let atlas = (try? bundled()) ?? Atlas()
        if let url = learnedFile, let data = try? Data(contentsOf: url),
           let learned = try? JSONDecoder().decode([Place].self, from: data) {
            for var p in learned {
                p.learned = true
                atlas.insert(p)
            }
        }
        return atlas
    }

    // MARK: - Mutation

    /// Adds a place.  Returns its id, or the id of the existing entry if any of
    /// its surfaces are already known.  Surfaces that collide with a *different*
    /// place are skipped rather than stolen.
    @discardableResult
    public func insert(_ place: Place) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return insertLocked(place)
    }

    private func insertLocked(_ place: Place) -> Int {
        let canonicalKey = Normalize.key(place.name)
        guard !canonicalKey.isEmpty else { return -1 }
        if let existing = keyToSurface[canonicalKey] {
            let id = _surfaces[existing].placeID
            for alias in place.aliases { addSurfaceLocked(alias, to: id, canonical: false) }
            return id
        }
        guard Normalize.firstLetter(place.name) != nil,
              Normalize.lastLetter(place.name) != nil else { return -1 }
        _places.append(place)
        let id = _places.count - 1
        addSurfaceLocked(place.name, to: id, canonical: true)
        for alias in place.aliases { addSurfaceLocked(alias, to: id, canonical: false) }
        return id
    }

    private func addSurfaceLocked(_ text: String, to placeID: Int, canonical: Bool) {
        let key = Normalize.key(text)
        guard !key.isEmpty, keyToSurface[key] == nil,
              let f = Normalize.firstLetter(text), let l = Normalize.lastLetter(text)
        else { return }
        let s = Surface(text: text, placeID: placeID, first: f, last: l,
                        fame: _places[placeID].fame, isCanonical: canonical)
        _surfaces.append(s)
        let idx = _surfaces.count - 1
        keyToSurface[key] = idx
        if canonical {
            canonicalByLetter[f, default: []].append(idx)
            // keep the per-letter bucket fame-ordered so bots can slice a tier off the front
            canonicalByLetter[f]!.sort { _surfaces[$0].fame > _surfaces[$1].fame }
        }
    }

    // MARK: - Lookup

    public func surface(matching text: String) -> Surface? {
        let key = Normalize.key(text)
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let idx = keyToSurface[key] else { return nil }
        return _surfaces[idx]
    }

    public func place(_ id: Int) -> Place? {
        lock.lock()
        defer { lock.unlock() }
        return _places.indices.contains(id) ? _places[id] : nil
    }

    public var placeCount: Int { lock.lock(); defer { lock.unlock() }; return _places.count }
    public var surfaceCount: Int { lock.lock(); defer { lock.unlock() }; return _surfaces.count }

    public var allPlaces: [Place] {
        lock.lock(); defer { lock.unlock() }; return _places
    }

    public var learnedPlaces: [Place] {
        lock.lock(); defer { lock.unlock() }; return _places.filter { $0.learned }
    }

    /// Canonical surfaces starting with `letter` and famous enough for `minFame`,
    /// excluding place ids in `used`.  Fame-descending.
    public func candidates(startingWith letter: Character, minFame: Int = 0,
                           excluding used: Set<Int> = []) -> [Surface] {
        lock.lock()
        defer { lock.unlock() }
        guard let bucket = canonicalByLetter[letter] else { return [] }
        var out: [Surface] = []
        out.reserveCapacity(bucket.count)
        for i in bucket {
            let s = _surfaces[i]
            if s.fame < minFame { break }   // bucket is fame-sorted
            if used.contains(s.placeID) { continue }
            out.append(s)
        }
        return out
    }

    /// How many legal replies remain for `letter`.  Drives the bot's endgame.
    public func replyCount(for letter: Character, minFame: Int = 0,
                           excluding used: Set<Int> = []) -> Int {
        candidates(startingWith: letter, minFame: minFame, excluding: used).count
    }

    /// Every distinct starting letter present in the atlas.
    public var startingLetters: [Character] {
        lock.lock(); defer { lock.unlock() }
        return canonicalByLetter.keys.sorted()
    }
}
