import Foundation
// URLSession lives in a separate module on Linux, which is where a deployed
// server runs even though every one of these was written on a Mac.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Decides whether a challenged name is a real place.
public protocol PlaceVerifier: Sendable {
    func verify(_ text: String, completion: @escaping @Sendable (VerificationResult) -> Void)
}

/// Vocabulary used to tell "a place" from "a thing that happens to have a map pin".
enum PlaceWords {
    /// A hit here, combined with map coordinates, means yes.
    static let positive: [String] = [
        "city", "cities", "town", "township", "village", "hamlet", "settlement",
        "capital", "country", "nation", "sovereign state", "state", "province", "region",
        "district", "municipality", "commune", "county", "prefecture", "canton",
        "oblast", "krai", "emirate", "republic", "kingdom", "territory",
        "governorate", "department", "borough", "suburb", "locality", "ward",
        "metropolis", "conurbation", "agglomeration", "urban area", "port",
        "island", "islands", "archipelago", "atoll", "peninsula", "isthmus",
        "river", "stream", "tributary", "lake", "loch", "lagoon", "reservoir",
        "sea", "ocean", "bay", "gulf", "strait", "channel", "fjord", "delta",
        "mountain", "mount", "peak", "summit", "massif", "range", "volcano",
        "hill", "plateau", "highland", "valley", "canyon", "gorge", "pass",
        "desert", "oasis", "steppe", "savanna", "tundra", "glacier", "plain",
        "forest", "national park", "nature reserve", "continent", "subcontinent",
        "colony", "protectorate", "county seat", "administrative", "geographic",
    ]

    /// Anything here disqualifies the page outright.
    static let negative: [String] = [
        "disambiguation", "given name", "surname", "family name", "album",
        "song", "single by", "film", "movie", "television series", "tv series",
        "novel", "book by", "video game", "band", "musician", "singer",
        "actor", "actress", "politician", "footballer", "company", "brand",
        "genus", "species", "spacecraft", "asteroid", "crater on", "fictional",
        "character in", "manga", "anime", "magazine", "newspaper", "software",
        "programming language", "ship", "aircraft", "locomotive", "hurricane",
        "cyclone", "typhoon", "battle of", "treaty of",
    ]

    /// Whether any of `needles` appears in `haystack` as a whole word.
    ///
    /// Whole words, not substrings.  Matching anywhere is how a Polish city came
    /// to be refused for being a **ship** — the word hides inside *Voivodeship*,
    /// which is in the description of every one of them.  Songkhla was a *song*,
    /// Lubango was a *band* by way of Sá da Bandeira, and every American township
    /// was a ship as well.  A trailing "s" still counts, so a needle need not be
    /// listed twice to match its plural.
    static func contains(_ haystack: String, any needles: [String]) -> Bool {
        let words = haystack.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let padded = " " + words.joined(separator: " ") + " "
        return needles.contains { padded.contains(" \($0) ") || padded.contains(" \($0)s ") }
    }
}

/// Looks names up on Wikipedia.
///
/// Two signals have to agree before a name is admitted: the article must carry
/// map coordinates, and its description must read like geography rather than a
/// person, a film or a building.  Either one alone is too loose — the Eiffel
/// Tower has coordinates, and "Casablanca" the film does not have a river in it.
public final class WikipediaVerifier: PlaceVerifier {

    private let session: URLSession
    private let cache = ResultCache()

    public init(timeout: TimeInterval = 7) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 3
        cfg.httpAdditionalHeaders = [
            "User-Agent": "AtlasGame/1.0 (local hotseat game; contact: local user)",
            "Accept": "application/json",
        ]
        session = URLSession(configuration: cfg)
    }

    public func verify(_ text: String, completion: @escaping @Sendable (VerificationResult) -> Void) {
        let query = Normalize.tidy(text)
        guard Normalize.letters(query).count >= 3 else {
            return completion(VerificationResult(
                accepted: false, reason: "too short to look up"))
        }
        if let hit = cache.get(Normalize.key(query)) { return completion(hit) }

        let finish: @Sendable (VerificationResult) -> Void = { [cache] result in
            if Self.worthRemembering(result) { cache.put(Normalize.key(query), result) }
            completion(result)
        }

        // `self` is captured strongly on purpose: a lookup in flight must
        // outlive the caller's reference, or `WikipediaVerifier().verify(…)`
        // would answer every question with silence.  Nothing here is stored on
        // the verifier, so the closure chain releases it when the last one runs.
        fetchSummary(title: query) { direct in
            let directVerdict: VerificationResult?
            switch direct {
            case .unreachable:
                // Searching would only be throttled too, and answering "no such
                // place" here would be a lie about the player's word.
                return finish(Self.silence)
            case .article(let summary):
                let verdict = self.judge(summary, query: query)
                if let verdict, verdict.accepted { return finish(verdict) }
                directVerdict = verdict
            case .missing:
                directVerdict = nil
            }

            // No usable article under that exact title: try a search before
            // giving up — but not the same article again.  "Tanga" is a list of
            // meanings; the port the player meant is filed under "Tanga,
            // Tanzania" and is the fifth hit.  Whatever was just read and found
            // wanting is excluded so the search can reach past it.
            let alreadyRead: Set<String>
            if case .article(let summary) = direct {
                alreadyRead = [Normalize.key(query), Normalize.key(summary.title ?? query)]
            } else {
                alreadyRead = []
            }
            let giveUp = directVerdict ?? VerificationResult(
                accepted: false, reason: "no Wikipedia article found")

            self.search(query, avoiding: alreadyRead) { found in
                switch found {
                case .unreachable: finish(directVerdict ?? Self.silence)
                case .missing: finish(giveUp)
                case .article(let title):
                    guard title != query else { return finish(giveUp) }
                    self.fetchSummary(title: title) { second in
                        guard case .article(let summary) = second,
                              let verdict = self.judge(summary, query: query)
                        else {
                            if case .unreachable = second {
                                return finish(directVerdict ?? Self.silence)
                            }
                            return finish(giveUp)
                        }
                        finish(verdict)
                    }
                }
            }
        }
    }

    /// Whether a description rules the page out — a film, a band, a person.
    /// Public only so the suite can check the wording rules without a network.
    public static func disqualifies(_ description: String) -> Bool {
        PlaceWords.contains(description, any: PlaceWords.negative)
    }

    /// Whether a description reads like geography rather than merely sitting
    /// somewhere.  Public for the same reason.
    public static func readsAsPlace(_ description: String) -> Bool {
        PlaceWords.contains(description, any: PlaceWords.positive)
    }

    /// What comes back when Wikipedia will not answer — throttling, no network,
    /// a timeout.  Distinct from a refusal on purpose: the player is owed the
    /// difference between "that is not a place" and "I could not ask".
    public static let silence = VerificationResult(
        accepted: false, reason: "Wikipedia did not answer; try again in a moment")

    /// Whether a verdict is worth keeping.  Silence is not: rate limiting is the
    /// ordinary way it happens and it passes in seconds, so remembering it would
    /// let one throttled moment rule a real place fake for the whole session.
    public static func worthRemembering(_ result: VerificationResult) -> Bool {
        result.reason != silence.reason
    }

    /// The three things a lookup can come back with.  Collapsing the last two
    /// into `nil` is what made a rate-limited server announce that Oaxaca does
    /// not exist.
    private enum Lookup<T> {
        case article(T)
        case missing
        case unreachable
    }

    // MARK: - Wikipedia payloads

    private struct Summary: Decodable {
        struct Coordinates: Decodable { var lat: Double; var lon: Double }
        struct URLs: Decodable {
            struct Page: Decodable { var page: String? }
            var desktop: Page?
        }
        var type: String?
        var title: String?
        var description: String?
        var extract: String?
        var coordinates: Coordinates?
        var content_urls: URLs?
    }

    private func fetchSummary(title: String,
                              completion: @escaping @Sendable (Lookup<Summary>) -> Void) {
        let path = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard !path.isEmpty,
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(path)?redirect=true")
        else { return completion(.missing) }
        session.dataTask(with: url) { data, response, _ in
            guard let http = response as? HTTPURLResponse else {
                return completion(.unreachable)      // no network, or a timeout
            }
            // 404 is Wikipedia saying there is no such page, which is an answer.
            // 429 and the 5xx family are Wikipedia declining to say, which is not.
            guard http.statusCode == 200 else {
                return completion(http.statusCode == 404 ? .missing : .unreachable)
            }
            guard let data, let summary = try? JSONDecoder().decode(Summary.self, from: data)
            else { return completion(.unreachable) }
            completion(.article(summary))
        }.resume()
    }

    private struct SearchPayload: Decodable {
        struct Query: Decodable {
            struct Hit: Decodable { var title: String }
            var search: [Hit]
        }
        var query: Query?
    }

    /// Words a place's own name may be followed by, in the order a player most
    /// likely meant them.
    private static let qualifiers = [
        "city", "town", "village", "island", "river", "lake", "mountain",
        "county", "province", "region", "district", "prefecture", "state",
        "governorate", "oblast", "municipality", "department",
    ]

    /// Words that are a kind of place, or half a name, rather than a name: the
    /// rules that let "Tanga" be answered by "Tanga, Tanzania" would otherwise
    /// let "Port" be answered by "Port-au-Prince".
    private static let notANameOnItsOwn: Set<String> = [
        "port", "lake", "mount", "mountain", "bay", "island", "city", "town",
        "cape", "fort", "villa", "ciudad", "rio", "san", "santa", "saint",
        "new", "north", "south", "east", "west", "great", "little", "upper",
        "lower", "old", "sea", "river", "valley", "gulf", "isle",
    ]

    /// Picks which of the search hits to read.
    ///
    /// `avoiding` carries the keys of pages already read and rejected, which is
    /// what makes a disambiguation page recoverable rather than final: drop the
    /// list-of-meanings and the name-with-its-country underneath it can win.
    ///
    /// Public only so the suite can check the ranking without a network.
    public static func chooseHit(from titles: [String], for text: String,
                                 avoiding: Set<String>) -> String? {
        let wanted = Normalize.key(text)
        let usable = titles.filter { !avoiding.contains(Normalize.key($0)) }
        let exact = usable.first { Normalize.key($0) == wanted }
        // A bare "Port" or "New" is a word, not a name, and must not be answered
        // by the first place that happens to begin with it.  Only the exact rule
        // above may speak for these.
        let nameable = !Self.notANameOnItsOwn.contains(wanted)
        // "Tanga, Tanzania" is the same name wearing its country and
        // "Vitoria-Gasteiz" is the same name wearing its Basque half; every other
        // hit is a different subject that merely mentions the word.
        let scoped = nameable ? usable.first { hit in
            let head = hit.split(whereSeparator: { $0 == "," || $0 == "-" || $0 == "–" })
                .first.map(String.init) ?? hit
            return Normalize.key(head) == wanted
        } : nil
        // The same name wearing a kind instead: "Hualien City", "Hualien County".
        // The trailing word has to name a kind of place, or "Tanga Loa" — an
        // island a thousand miles from Tanga — would answer for Tanga.  The list
        // is in preference order, so a player who types Hualien is handed the
        // city rather than the county around it.
        let qualified = nameable ? Self.qualifiers.lazy.compactMap({ qualifier in
            usable.first { Normalize.key($0) == wanted + qualifier }
        }).first : nil
        // A hit under some other name is only worth reading when the typed title
        // had no article at all — a misspelling, where the search index is doing
        // the correcting.  Once a page has been read and rejected, only another
        // page of the same name may overturn it; anything else is a different
        // subject that merely ranks well for the word.
        return exact ?? scoped ?? qualified ?? (avoiding.isEmpty ? usable.first : nil)
    }

    private func search(_ text: String, avoiding: Set<String> = [],
                        completion: @escaping @Sendable (Lookup<String>) -> Void) {
        var comps = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        comps.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "list", value: "search"),
            .init(name: "srsearch", value: text),
            .init(name: "srlimit", value: "5"),
            .init(name: "format", value: "json"),
        ]
        guard let url = comps.url else { return completion(.missing) }
        session.dataTask(with: url) { data, response, _ in
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let payload = try? JSONDecoder().decode(SearchPayload.self, from: data),
                  let hits = payload.query?.search
            else { return completion(.unreachable) }
            guard let title = Self.chooseHit(from: hits.map(\.title), for: text,
                                             avoiding: avoiding)
            else { return completion(.missing) }   // the index answered: nothing fits
            completion(.article(title))
        }.resume()
    }

    // MARK: - Judgement

    private func judge(_ s: Summary, query: String) -> VerificationResult? {
        let title = s.title ?? query
        let pageURL = s.content_urls?.desktop?.page
            ?? "https://en.wikipedia.org/wiki/\(title.replacingOccurrences(of: " ", with: "_"))"
        let description = s.description ?? ""
        // Only the opening sentences define what the subject *is*; scanning the
        // whole extract would match "…on the Danube river" for any old topic.
        let opening = String((s.extract ?? "").prefix(220))
        let blob = description + " . " + opening

        func no(_ reason: String) -> VerificationResult {
            VerificationResult(accepted: false, resolvedName: title, kind: "place",
                               summary: description.isEmpty ? opening : description,
                               sourceURL: pageURL, reason: reason)
        }

        if (s.type ?? "standard") != "standard" {
            return no("that page is a \(s.type ?? "stub"), not a single place")
        }
        if PlaceWords.contains(blob, any: PlaceWords.negative) {
            return no("Wikipedia describes it as “\(description)”")
        }
        guard s.coordinates != nil else {
            return no("no map coordinates on that article")
        }
        guard PlaceWords.contains(blob, any: PlaceWords.positive) else {
            return no("“\(description)” does not read like a geographic place")
        }
        return VerificationResult(accepted: true, resolvedName: title,
                                  kind: Self.inferKind(description: description, blob: blob),
                                  summary: description.isEmpty ? opening : description,
                                  sourceURL: pageURL,
                                  reason: description.isEmpty ? "confirmed on Wikipedia" : description)
    }

    /// Wikipedia's one-line description ("City in Imereti, Georgia") says what a
    /// page *is*; the extract only says what it is near — "a city in the region
    /// of Imereti" reads as a region if both are weighed the same.  So the
    /// description gets the first word and the body is only a fallback.
    ///
    /// Public only so the suite can check it without a network.
    public static func inferKind(description: String, blob: String) -> String {
        for text in [description, blob] where !text.isEmpty {
            if let kind = kindOf(text) { return kind }
        }
        return "city"
    }

    /// Places whose capital is a town rather than a country's seat.
    private static let subnational = [
        "region", "province", "district", "county", "prefecture", "state of",
        "governorate", "oblast", "department", "canton", "voivodeship",
        "municipality", "emirate", "territory",
    ]

    private static func kindOf(_ text: String) -> String? {
        let b = text.lowercased()
        // "Capital of Peru" is a capital.  "Capital of Tanga Region" is a city
        // that happens to run a province, and announcing it to the table as a
        // capital says something untrue — so the qualifier decides, and either
        // way the answer is a settlement rather than the province itself.
        if b.contains("capital") {
            return Self.subnational.contains(where: { b.contains($0) }) ? "city" : "capital"
        }
        for (needles, kind) in [
            (["city", "town", "village", "municipality", "borough"], "city"),
            (["country", "sovereign state", "nation"], "country"),
            (["river", "tributary", "stream"], "river"),
            (["lake", "loch", "reservoir", "lagoon"], "lake"),
            (["sea", "ocean", "gulf", "bay", "strait"], "sea"),
            (["mountain", "mount ", "peak", "volcano", "massif"], "mountain"),
            (["desert"], "desert"),
            (["island", "archipelago", "atoll"], "island"),
            (["province", "state", "region", "district", "county", "prefecture"], "region"),
        ] where needles.contains(where: { b.contains($0) }) {
            return kind
        }
        return nil
    }
}

/// Small thread-safe memo so repeated challenges cost nothing.
final class ResultCache: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: VerificationResult] = [:]

    func get(_ key: String) -> VerificationResult? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }

    func put(_ key: String, _ value: VerificationResult) {
        lock.lock(); defer { lock.unlock() }
        if store.count > 500 { store.removeAll(keepingCapacity: true) }
        store[key] = value
    }
}

/// Verifier for tests and offline play.
public final class StubVerifier: PlaceVerifier, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: VerificationResult] = [:]
    public var defaultResult: VerificationResult

    public init(defaultResult: VerificationResult =
                VerificationResult(accepted: false, reason: "offline")) {
        self.defaultResult = defaultResult
    }

    public func stub(_ name: String, _ result: VerificationResult) {
        lock.lock(); defer { lock.unlock() }
        answers[Normalize.key(name)] = result
    }

    /// Synchronous form, for simulations that need the verdict inline.
    public func result(for text: String) -> VerificationResult {
        lock.lock(); defer { lock.unlock() }
        return answers[Normalize.key(text)] ?? defaultResult
    }

    public func verify(_ text: String, completion: @escaping @Sendable (VerificationResult) -> Void) {
        completion(result(for: text))
    }
}
