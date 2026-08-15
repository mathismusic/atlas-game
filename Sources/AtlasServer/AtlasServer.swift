import AtlasCore
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

public enum AtlasPaths {

    /// `~/.atlas`, or wherever `ATLAS_DATA_DIR` says — a deployed server gets a
    /// writable directory that is not a home directory, and may get none at all.
    public static var dataDirectory: URL {
        let env = ProcessInfo.processInfo.environment["ATLAS_DATA_DIR"]
        let dir = env.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".atlas", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Places admitted by past challenges, so the atlas grows across sessions.
    public static var learnedFile: URL {
        dataDirectory.appendingPathComponent("learned.json")
    }

    /// Pictures and facts gathered by the background trickle.  Two files, read
    /// in this order: one that may ship with the build and never changes, and
    /// one this machine writes as it learns.
    public static var mediaFile: URL {
        dataDirectory.appendingPathComponent("media.json")
    }

    public static var shippedMediaFile: URL? {
        ProcessInfo.processInfo.environment["ATLAS_MEDIA"].map {
            URL(fileURLWithPath: $0)
        }
    }
}

/// One table of players.
final class Room: @unchecked Sendable {
    let code: String
    let game: Game
    let createdAt: Date
    private let lock = NSLock()
    private var clients: [(id: String, playerID: String, connection: HTTPConnection)] = []
    private var _hostID: String?
    private var lastBroadcastVersion = -1
    var lastActivity: Date
    /// Every push for this table happens here, one at a time and never on a
    /// caller's thread: writing to a client can block for as long as the write
    /// deadline, and the tick loop that drives *all* the tables must not be
    /// the thread that waits.  Serial, so pushes still arrive in order.
    private let pushQueue: DispatchQueue

    init(code: String, atlas: Atlas, config: GameConfig, seed: UInt64) {
        self.code = code
        self.game = Game(atlas: atlas, config: config, seed: seed)
        self.createdAt = Date()
        self.lastActivity = Date()
        self.pushQueue = DispatchQueue(label: "atlas.room.\(code)")
    }

    var hostID: String? {
        get { lock.withLock { _hostID } }
        set { lock.withLock { _hostID = newValue } }
    }

    func addClient(playerID: String, connection: HTTPConnection) -> String {
        let id = UUID().uuidString
        lock.withLock { clients.append((id, playerID, connection)) }
        lastActivity = Date()
        return id
    }

    func removeClient(id: String) {
        lock.withLock { clients.removeAll { $0.id == id } }
    }

    var connectedPlayerIDs: Set<String> {
        lock.withLock { Set(clients.map(\.playerID)) }
    }

    var clientCount: Int { lock.withLock { clients.count } }

    /// Pushes the current state to everyone.  Dead sockets are pruned here,
    /// which is also how a player gets marked disconnected.
    ///
    /// The push itself is queued: the state is read when it runs, so a caller
    /// never waits on someone else's phone and a burst collapses into whatever
    /// is current by the time the queue gets there.
    func broadcast(now: @escaping @autoclosure () -> Double, force: Bool = false) {
        pushQueue.async { [self] in
            let version = game.version
            if !force && version == lastBroadcastVersion { return }
            lastBroadcastVersion = version

            let view = game.view(now: now())
            guard let json = try? JSONEncoder().encode(view),
                  let payload = String(data: json, encoding: .utf8) else { return }

            let snapshot = lock.withLock { clients }
            var dead: [String] = []
            for client in snapshot where !client.connection.send(event: "state", data: payload) {
                dead.append(client.id)
            }
            guard !dead.isEmpty else { return }
            lock.withLock { clients.removeAll { dead.contains($0.id) } }
            syncPresence()
        }
    }

    func heartbeat() {
        pushQueue.async { [self] in
            let snapshot = lock.withLock { clients }
            var dead: [String] = []
            for client in snapshot where !client.connection.comment("ping") {
                dead.append(client.id)
            }
            guard !dead.isEmpty else { return }
            lock.withLock { clients.removeAll { dead.contains($0.id) } }
            syncPresence()
        }
    }

    /// Reflects who currently holds an open event stream onto the roster.
    func syncPresence() {
        let live = connectedPlayerIDs
        for player in game.players where !player.isBot {
            game.setConnected(id: player.id, live.contains(player.id))
        }
    }
}

public final class AtlasServer: @unchecked Sendable {

    private let atlas: Atlas
    private let verifier: PlaceVerifier
    private let learnedFile: URL?
    private var http: HTTPServer?
    private let lock = NSLock()
    private var rooms: [String: Room] = [:]
    private var seedCounter: UInt64 = UInt64(Date().timeIntervalSince1970)
    private let startDate = Date()
    private var ticker: DispatchSourceTimer?
    private var heartbeatCounter = 0

    private var now: Double { Date().timeIntervalSince(startDate) }

    /// Pictures and facts, if this server has any.  Nil in tests and in any
    /// build that never harvests: a place with no record simply shows none, and
    /// nothing about the game changes.
    private let media: MediaLibrary?

    public init(atlas: Atlas, verifier: PlaceVerifier, learnedFile: URL? = nil,
                media: MediaLibrary? = nil) {
        self.atlas = atlas
        self.verifier = verifier
        self.learnedFile = learnedFile
        self.media = media
    }

    // MARK: - Lifecycle

    /// Prints the "here is your address" banner on start.  Off for tests, which
    /// boot servers on scratch ports and would drown in it.
    public var announces = true

    public func start(host: String, port: UInt16) throws {
        let server = HTTPServer { [weak self] request, connection in
            guard let self else { return .text("shutting down", status: 500) }
            return self.route(request, connection)
        }
        try server.start(host: host, port: port)
        http = server

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "atlas.tick"))
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.tickAll() }
        timer.resume()
        ticker = timer

        if announces { printBanner(port: port) }
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
        http?.stop()
    }

    /// Advances every room and pushes anything that changed.
    private func tickAll() {
        let t = now
        let snapshot = lock.withLock { Array(rooms.values) }
        heartbeatCounter += 1
        let beat = heartbeatCounter % 150 == 0     // every 15s
        for room in snapshot {
            room.game.tick(now: t)
            room.broadcast(now: t)
            if beat {
                room.heartbeat()
                room.broadcast(now: t, force: true)   // resync clocks
            }
        }
        if beat { reapRooms() }
    }

    private func reapRooms() {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        lock.withLock {
            rooms = rooms.filter { _, room in
                room.clientCount > 0 || room.lastActivity > cutoff
            }
        }
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest, _ connection: HTTPConnection) -> HTTPResponse? {
        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, headers: corsHeaders)
        }
        let path = request.path
        if path == "/api/health" {
            return .json(JSONObject(["ok": true, "rooms": lock.withLock { rooms.count },
                          "places": atlas.placeCount]))
        }
        if path.hasPrefix("/api/") {
            return api(request, connection)
        }
        return staticFile(path)
    }

    private var corsHeaders: [String: String] {
        ["Access-Control-Allow-Origin": "*",
         "Access-Control-Allow-Headers": "Content-Type",
         "Access-Control-Allow-Methods": "GET, POST, OPTIONS"]
    }

    // MARK: - API

    /// The knobs a host may turn, in every shape of request that carries them.
    /// Kept as one type so `/api/room`, `/api/quick` and `/api/room/:code/config`
    /// cannot drift apart — a mode the lobby can pick but the config screen
    /// cannot change would be a bug nobody notices until a rematch.
    private struct TableBody: Decodable {
        var mode: String?
        var turnSeconds: Double?
        var lives: Int?
        var minFame: Int?
        var allowChallenge: Bool?
        var cardChance: Double?
        var forcedCards: Bool?
        var cardTiers: [String]?
        var deadLetterRescue: Bool?
        var allowWager: Bool?
        var turnDecay: Double?
        var minimumTurnSeconds: Double?
    }
    private struct CreateBody: Decodable { var name: String?; var table: TableBody? }
    private struct JoinBody: Decodable { var name: String?; var playerID: String? }
    private struct SubmitBody: Decodable { var playerID: String; var text: String }
    private struct BotBody: Decodable { var difficulty: String?; var name: String? }
    private struct ConfigBody: Decodable { var playerID: String?; var table: TableBody? }
    private struct PlayerBody: Decodable { var playerID: String }
    private struct QuickBody: Decodable { var name: String?; var difficulty: String?
                                          var bots: Int?; var table: TableBody? }

    /// Applies a request body to a config.  `base` is the mode's config when the
    /// body names one, otherwise whatever the room already had.
    private func applyTable(_ body: TableBody?, to existing: GameConfig) -> GameConfig {
        guard let body else { return existing }
        var c = body.mode.flatMap { TableMode(rawValue: $0)?.config } ?? existing
        if let t = body.turnSeconds { c.turnSeconds = clampTurn(t) }
        if let l = body.lives { c.lives = max(1, min(9, l)) }
        if let f = body.minFame { c.minFame = max(0, min(99, f)) }
        if let a = body.allowChallenge { c.allowChallenge = a }
        if let x = body.cardChance { c.cardChance = max(0, min(1, x)) }
        if let f = body.forcedCards { c.forcedCards = f }
        if let tiers = body.cardTiers {
            let parsed = Set(tiers.compactMap { CardTier(rawValue: $0) })
            // An empty set would deal nothing while still claiming to play
            // cards; treat "no tiers" as "cards off" instead.
            if parsed.isEmpty { c.cardChance = 0 } else { c.cardTiers = parsed }
        }
        if let r = body.deadLetterRescue { c.deadLetterRescue = r }
        if let w = body.allowWager { c.allowWager = w }
        if let d = body.turnDecay { c.turnDecay = max(0, min(5, d)) }
        if let m = body.minimumTurnSeconds { c.minimumTurnSeconds = clampTurn(m) }
        // The floor must never exceed the clock it is meant to protect.
        c.minimumTurnSeconds = min(c.minimumTurnSeconds, c.turnSeconds)
        return c
    }

    private func api(_ request: HTTPRequest, _ connection: HTTPConnection) -> HTTPResponse? {
        var parts = request.path.split(separator: "/").map(String.init)
        guard parts.first == "api" else { return .text("not found", status: 404) }
        parts.removeFirst()

        switch (request.method, parts.first) {
        case ("POST", "room") where parts.count == 1:
            return createRoom(request)
        case ("POST", "quick"):
            return quickPlay(request)
        case ("GET", "atlas"):
            return atlasInfo(request)
        case ("GET", "media"):
            return mediaInfo(request)
        case ("GET", "modes"):
            return .json(["modes": TableMode.catalogue])
        default:
            break
        }

        guard parts.count >= 2, parts[0] == "room" else {
            return .text("not found", status: 404)
        }
        let code = parts[1].uppercased()
        guard let room = lock.withLock({ rooms[code] }) else {
            return .json(["error": "No room \(code). It may have expired."], status: 404)
        }
        room.lastActivity = Date()
        let action = parts.count > 2 ? parts[2] : ""

        switch (request.method, action) {
        case ("GET", "events"):
            return eventStream(room, request, connection)
        case ("POST", "join"):
            return join(room, request)
        case ("POST", "start"):
            return startGame(room, request)
        case ("POST", "submit"):
            return submit(room, request)
        case ("POST", "challenge"):
            return challenge(room, request)
        case ("POST", "wager"):
            return wager(room, request)
        case ("POST", "bot"):
            return addBot(room, request)
        case ("POST", "kick"):
            return kick(room, request)
        case ("POST", "leave"):
            return leave(room, request)
        case ("POST", "config"):
            return setConfig(room, request)
        case ("POST", "again"):
            return rematch(room, request)
        case ("GET", "hint"):
            return .json(["hints": room.game.hints(limit: 6, now: now)])
        case ("GET", "state"):
            return .json(room.game.view(now: now))
        default:
            return .text("not found", status: 404)
        }
    }

    private func newRoomCode() -> String {
        // No I/O/0/1: they get misread when someone reads a code aloud.
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        for _ in 0..<200 {
            let code = String((0..<4).map { _ in alphabet.randomElement()! })
            if lock.withLock({ rooms[code] == nil }) { return code }
        }
        return String(UUID().uuidString.prefix(6))
    }

    private func makeRoom(config: GameConfig) -> Room {
        let code = newRoomCode()
        let seed = lock.withLock { () -> UInt64 in
            seedCounter &+= 0x9E3779B9
            return seedCounter
        }
        let room = Room(code: code, atlas: atlas, config: config, seed: seed)
        lock.withLock { rooms[code] = room }
        return room
    }

    private func createRoom(_ request: HTTPRequest) -> HTTPResponse {
        let body = request.json(CreateBody.self)
        let config = applyTable(body?.table, to: TableMode.cards.config)
        let room = makeRoom(config: config)
        let player = Player(id: newPlayerID(), name: cleanName(body?.name, fallback: "Host"))
        room.game.addPlayer(player, now: now)
        room.hostID = player.id
        return .json(JSONObject(["room": room.code, "playerID": player.id, "isHost": true]))
    }

    /// One tap: a room, some bots, already started.
    private func quickPlay(_ request: HTTPRequest) -> HTTPResponse {
        let body = request.json(QuickBody.self)
        let config = applyTable(body?.table, to: TableMode.cards.config)
        let room = makeRoom(config: config)
        let player = Player(id: newPlayerID(), name: cleanName(body?.name, fallback: "You"))
        room.game.addPlayer(player, now: now)
        room.hostID = player.id

        let difficulty = BotDifficulty(rawValue: body?.difficulty ?? "medium") ?? .medium
        let count = max(1, min(5, body?.bots ?? 1))
        for i in 0..<count {
            room.game.addPlayer(Player(id: newPlayerID(), name: botName(i),
                                       isBot: true, difficulty: difficulty), now: now)
        }
        room.game.start(now: now)
        return .json(JSONObject(["room": room.code, "playerID": player.id, "isHost": true]))
    }

    private func join(_ room: Room, _ request: HTTPRequest) -> HTTPResponse {
        let body = request.json(JoinBody.self)
        // A refresh comes back with the same id and simply reconnects.
        if let existing = body?.playerID,
           room.game.players.contains(where: { $0.id == existing }) {
            room.game.setConnected(id: existing, true)
            return .json(JSONObject(["room": room.code, "playerID": existing,
                          "isHost": room.hostID == existing]))
        }
        guard room.game.phase == .lobby else {
            return .json(["error": "That game has already started."], status: 409)
        }
        let player = Player(id: newPlayerID(), name: cleanName(body?.name, fallback: "Player"))
        guard room.game.addPlayer(player, now: now) else {
            return .json(["error": "That table is full."], status: 409)
        }
        if room.hostID == nil { room.hostID = player.id }
        room.broadcast(now: self.now, force: true)
        return .json(JSONObject(["room": room.code, "playerID": player.id,
                      "isHost": room.hostID == player.id]))
    }

    private func startGame(_ room: Room, _ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.json(PlayerBody.self) else { return badRequest }
        guard room.hostID == body.playerID else {
            return .json(["error": "Only the host can start."], status: 403)
        }
        guard room.game.players.count >= 1 else {
            return .json(["error": "Nobody is at the table."], status: 409)
        }
        guard room.game.start(now: now) else {
            return .json(["error": "The game is already running."], status: 409)
        }
        room.broadcast(now: self.now, force: true)
        return .json(["ok": true])
    }

    private func submit(_ room: Room, _ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.json(SubmitBody.self) else { return badRequest }
        switch room.game.submit(playerID: body.playerID, text: body.text, now: now) {
        case .accepted(let move):
            room.broadcast(now: self.now, force: true)
            return .json(JSONObject(["ok": true, "played": move.text]))
        case .rejected(let reason):
            room.broadcast(now: self.now, force: true)
            return .json(JSONObject(["ok": false, "code": reason.code, "error": reason.message,
                          "canChallenge": reason.isChallengeable && room.game.config.allowChallenge
                              && room.game.challengesRemaining(for: body.playerID) > 0]))
        }
    }

    /// Puts a life on a hard card.  Nothing is looked up and the clock keeps
    /// running: the bet is made and answered inside the same turn.
    private func wager(_ room: Room, _ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.json(PlayerBody.self) else { return badRequest }
        switch room.game.wager(playerID: body.playerID, now: now) {
        case .failure(let reason):
            return .json(JSONObject(["ok": false, "code": reason.code,
                                     "error": reason.message]))
        case .success(let card):
            room.broadcast(now: self.now, force: true)
            return .json(JSONObject(["ok": true, "demand": card.demand,
                                     "multiplier": card.multiplier]))
        }
    }

    /// Kicks off a web lookup.  The turn clock is already paused by the engine,
    /// so the network round-trip cannot cost the player their turn.
    private func challenge(_ room: Room, _ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.json(SubmitBody.self) else { return badRequest }
        switch room.game.beginChallenge(playerID: body.playerID, text: body.text, now: now) {
        case .failure(let reason):
            return .json(JSONObject(["ok": false, "error": reason.message]))
        case .success(let pending):
            room.broadcast(now: self.now, force: true)
            verifier.verify(body.text) { [weak self, weak room] result in
                guard let self, let room else { return }
                let outcome = room.game.resolveChallenge(id: pending.id, result: result,
                                                          now: self.now)
                if result.accepted, outcome != nil { self.persistLearned() }
                room.broadcast(now: self.now, force: true)
            }
            return .json(JSONObject(["ok": true, "pending": pending.id]))
        }
    }

    private func addBot(_ room: Room, _ request: HTTPRequest) -> HTTPResponse {
        let body = request.json(BotBody.self)
        guard room.game.phase == .lobby else {
            return .json(["error": "Add players before the game starts."], status: 409)
        }
        let difficulty = BotDifficulty(rawValue: body?.difficulty ?? "medium") ?? .medium
        let index = room.game.players.filter(\.isBot).count
        let bot = Player(id: newPlayerID(), name: cleanName(body?.name, fallback: botName(index)),
                         isBot: true, difficulty: difficulty)
        guard room.game.addPlayer(bot, now: now) else {
            return .json(["error": "That table is full."], status: 409)
        }
        room.broadcast(now: self.now, force: true)
        return .json(["ok": true])
    }

    private func kick(_ room: Room, _ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.json(SubmitBody.self) else { return badRequest }
        guard room.hostID == body.playerID else {
            return .json(["error": "Only the host can remove players."], status: 403)
        }
        room.game.removePlayer(id: body.text, now: now)
        room.broadcast(now: self.now, force: true)
        return .json(["ok": true])
    }

    private func leave(_ room: Room, _ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.json(PlayerBody.self) else { return badRequest }
        room.game.removePlayer(id: body.playerID, now: now)
        room.broadcast(now: self.now, force: true)
        return .json(["ok": true])
    }

    private func setConfig(_ room: Room, _ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.json(ConfigBody.self) else { return badRequest }
        // Once a host exists, only they may change the table under everyone.
        if let host = room.hostID, let who = body.playerID, who != host {
            return .json(["error": "Only the host can change the table."], status: 403)
        }
        room.game.updateConfig(applyTable(body.table, to: room.game.config))
        room.broadcast(now: self.now, force: true)
        return .json(["ok": true])
    }

    /// Same table, fresh game.
    private func rematch(_ room: Room, _ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.json(PlayerBody.self) else { return badRequest }
        guard room.hostID == body.playerID else {
            return .json(["error": "Only the host can start a rematch."], status: 403)
        }
        guard room.game.phase == .finished else {
            return .json(["error": "Finish this game first."], status: 409)
        }
        let old = room.game
        let seed = lock.withLock { () -> UInt64 in
            seedCounter &+= 0x9E3779B9
            return seedCounter
        }
        let fresh = Room(code: room.code, atlas: atlas, config: old.config, seed: seed)
        for player in old.players {
            var p = player
            p.eliminated = false
            p.lives = old.config.lives
            // A rematch is a new game, not a running total: leaving the score on
            // would also break the "score equals your moves" invariant.
            p.score = 0
            p.placesPlayed = 0
            p.cardsMet = 0
            fresh.game.addPlayer(p, now: now)
        }
        fresh.hostID = room.hostID
        fresh.lastActivity = Date()
        // Move the open event streams across so nobody has to refresh.
        lock.withLock { rooms[room.code] = fresh }
        for client in room.takeClients() {
            _ = fresh.addClient(playerID: client.playerID, connection: client.connection)
        }
        fresh.syncPresence()
        fresh.game.start(now: now)
        fresh.broadcast(now: self.now, force: true)
        return .json(["ok": true])
    }

    private func atlasInfo(_ request: HTTPRequest) -> HTTPResponse {
        if let q = request.query["q"], !q.isEmpty {
            guard let surface = atlas.surface(matching: q), let place = atlas.place(surface.placeID)
            else { return .json(JSONObject(["found": false])) }
            return .json(JSONObject(["found": true, "name": place.name, "kind": place.kind,
                          "fame": place.fame, "learned": place.learned]))
        }
        return .json(JSONObject(["places": atlas.placeCount, "surfaces": atlas.surfaceCount,
                      "learned": atlas.learnedPlaces.count,
                      "described": media?.count ?? 0,
                      "pictured": media?.withPictures ?? 0]))
    }

    /// The picture and the quirky fact for places that have been played.
    ///
    /// Several names at once, separated by `|`: a phone that reconnects
    /// re-renders the whole chain, and twenty round trips to draw one screen is
    /// twenty chances for one of them to be the slow one.  Names nobody has
    /// looked up yet are simply absent from the reply — the client draws the
    /// move without a picture and asks again later, by which time the trickle
    /// has usually got there.
    private func mediaInfo(_ request: HTTPRequest) -> HTTPResponse {
        guard let media else {
            return .json(JSONObject(["ready": false, "places": [String]()]))
        }
        let asked = (request.query["q"] ?? "")
            .split(separator: "|", omittingEmptySubsequences: true)
            .prefix(60)
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        var found: [JSONObject] = []
        for name in asked where !name.isEmpty {
            guard let record = media.media(for: name), !record.isEmpty else { continue }
            found.append(JSONObject([
                "q": name,
                "name": record.name,
                "fact": record.fact,
                "image": record.image,
                "width": record.width,
                "height": record.height,
                "source": record.source,
            ]))
        }
        return .json(MediaReply(ready: true, places: found))
    }

    private struct MediaReply: Encodable {
        var ready: Bool
        var places: [JSONObject]
    }

    private var badRequest: HTTPResponse {
        .json(["error": "Malformed request."], status: 400)
    }

    // MARK: - Event stream

    private func eventStream(_ room: Room, _ request: HTTPRequest,
                             _ connection: HTTPConnection) -> HTTPResponse? {
        guard let playerID = request.query["playerID"] else {
            return .json(["error": "playerID required"], status: 400)
        }
        connection.beginEventStream()
        let clientID = room.addClient(playerID: playerID, connection: connection)
        room.game.setConnected(id: playerID, true)

        // Immediate snapshot so the page renders without waiting for a tick.
        if let json = try? JSONEncoder().encode(room.game.view(now: now)),
           let payload = String(data: json, encoding: .utf8) {
            _ = connection.send(event: "state", data: payload)
        }
        _ = connection.send(event: "hello", data: "{\"room\":\"\(room.code)\"}")

        // Reap the registration when the socket dies.
        DispatchQueue.global().async { [weak self, weak room] in
            while connection.isAlive {
                Thread.sleep(forTimeInterval: 1.0)
                if let room, room.clientCount == 0 { break }
            }
            room?.removeClient(id: clientID)
            room?.syncPresence()
            if let self, let room { room.broadcast(now: self.now, force: true) }
            connection.close()
        }
        return nil   // the handler owns this socket now
    }

    // MARK: - Static files

    private func staticFile(_ path: String) -> HTTPResponse {
        var name = path == "/" ? "index.html" : String(path.dropFirst())
        if name.isEmpty { name = "index.html" }
        // No traversal, no absolute paths.
        guard !name.contains(".."), !name.hasPrefix("/") else {
            return .text("forbidden", status: 403)
        }
        guard let root = AtlasServer.publicRoot else {
            return .text("web assets missing", status: 500)
        }
        let url = root.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            // Unknown paths fall through to the app so deep links work.
            if let index = try? Data(contentsOf: root.appendingPathComponent("index.html")) {
                return .data(index, type: "text/html; charset=utf-8")
            }
            return .text("not found", status: 404)
        }
        return .data(data, type: AtlasServer.mimeType(for: url.pathExtension))
    }

    static let publicRoot: URL? = {
        if let override = ProcessInfo.processInfo.environment["ATLAS_PUBLIC_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle.module.url(forResource: "Public", withExtension: nil)
    }()

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "webmanifest": return "application/manifest+json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "ico": return "image/x-icon"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Helpers

    private func clampTurn(_ t: Double) -> Double { max(5, min(180, t)) }

    private func newPlayerID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
    }

    private func cleanName(_ raw: String?, fallback: String) -> String {
        let tidied = Normalize.tidy(raw ?? "")
        let trimmed = String(tidied.prefix(18))
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func botName(_ index: Int) -> String {
        let names = ["Ada", "Bruno", "Cleo", "Dmitri", "Esme", "Finn"]
        return names[index % names.count]
    }

    private func persistLearned() {
        guard let file = learnedFile else { return }
        let learned = atlas.learnedPlaces
        guard let data = try? JSONEncoder().encode(learned) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func printBanner(port: UInt16) {
        let addresses = AtlasServer.localAddresses()
        print("""

          Atlas is running.  \(atlas.placeCount) places in the book.

            on this Mac      http://localhost:\(port)
        """)
        for address in addresses {
            print("    from your phone  http://\(address):\(port)")
        }
        print("""

          Both devices must be on the same Wi-Fi.  On the phone, tap Share →
          Add to Home Screen to get a full-screen app icon.

          Ctrl-C to stop.

        """)
    }

    /// IPv4 addresses of the machine's real interfaces.
    public static func localAddresses() -> [String] {
        var found: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return found }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            // `sa_family` is a byte on Darwin and a short on Linux, so it is
            // widened before being compared rather than cast to either.
            guard let addr = entry.pointee.ifa_addr,
                  Int32(addr.pointee.sa_family) == AF_INET,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            // en0 and bridge0 on a Mac; ens5, enp0s3 and eth0 on a Linux host.
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("eth")
                    || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            // The length is taken from the type rather than from `sa_len`, which
            // is a BSD field that glibc does not have — and the family was just
            // checked, so the address really is a `sockaddr_in`.
            let length = socklen_t(MemoryLayout<sockaddr_in>.size)
            if getnameinfo(addr, length, &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.isEmpty, ip != "127.0.0.1", !found.contains(ip) { found.append(ip) }
            }
        }
        return found
    }
}

extension Room {
    /// Detaches the open streams so a rematch can adopt them.
    func takeClients() -> [(id: String, playerID: String, connection: HTTPConnection)] {
        lock.withLock {
            let all = clients
            clients = []
            return all
        }
    }
}

/// Lets the API return small ad-hoc payloads without a Codable struct per shape.
struct JSONObject: Encodable {
    private let fields: [String: Any]

    init(_ fields: [String: Any]) { self.fields = fields }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        init(_ name: String) { stringValue = name }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for (name, value) in fields {
            let key = Key(name)
            switch value {
            case let v as String: try c.encode(v, forKey: key)
            case let v as Bool: try c.encode(v, forKey: key)
            case let v as Int: try c.encode(v, forKey: key)
            case let v as Double: try c.encode(v, forKey: key)
            case let v as [String]: try c.encode(v, forKey: key)
            default: try c.encodeNil(forKey: key)
            }
        }
    }
}

extension NSLock {
    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
