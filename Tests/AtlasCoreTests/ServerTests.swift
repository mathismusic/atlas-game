import Foundation
import AtlasCore
import AtlasServer

// The raw socket further down needs the C library by name.  On Darwin `import
// Foundation` re-exports it and this line looks unnecessary; off Darwin it does
// not, and every one of `socket`, `sockaddr_in` and `connect` is undefined.
// That is why this file compiled here for the whole of its life while being
// unbuildable on the platform the server is deployed to.
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

// And URLSession lives in a module of its own there, exactly as it does in
// `Verifier` and `Media` — the tests talk to the server over HTTP too.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Boots a real server on a spare port and talks to it over a real socket, so
/// the HTTP parser, the router and the room bookkeeping are all under test.
/// `tools/e2e.py` covers the same ground against a long-running server; this
/// runs as part of the ordinary suite.
enum ServerTests {

    private static var server: AtlasServer!
    private static var stub: StubVerifier!
    private static var port: UInt16 = 0

    // MARK: - Plumbing

    private static func boot() -> Bool {
        stub = StubVerifier()
        let atlas = Atlas(places: AtlasTests.shared.allPlaces)
        server = AtlasServer(atlas: atlas, verifier: stub, learnedFile: nil)
        server.announces = false
        // A stale TIME_WAIT socket from an earlier run should not fail the
        // suite, so try a few ports before giving up.
        for _ in 0..<20 {
            let candidate = UInt16(41_000 + Int.random(in: 0..<8_000))
            if (try? server.start(host: "127.0.0.1", port: candidate)) != nil {
                port = candidate
                return true
            }
        }
        fail("could not find a free port to test on")
        return false
    }

    private static func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    private struct Reply {
        var status: Int
        var json: [String: Any]
        var text: String
    }

    @discardableResult
    private static func request(_ method: String, _ path: String,
                                body: [String: Any]? = nil,
                                rawBody: Data? = nil) -> Reply {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = 25
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let rawBody {
            req.httpBody = rawBody
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var reply = Reply(status: 0, json: [:], text: "")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            reply = Reply(status: status,
                          json: object as? [String: Any] ?? [:],
                          text: String(decoding: data ?? Data(), as: UTF8.self))
            semaphore.signal()
        }.resume()
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            fail("\(method) \(path) never came back")
        }
        return reply
    }

    /// Creates a one-human, one-bot room and returns (code, playerID).
    private static func quickRoom(turnSeconds: Double = 60,
                                  table extra: [String: Any] = [:]) -> (code: String, me: String) {
        var settings: [String: Any] = ["turnSeconds": turnSeconds]
        settings.merge(extra) { _, new in new }
        let reply = request("POST", "/api/quick", body: ["name": "Tester", "bots": 1,
                                                         "difficulty": "easy",
                                                         "table": settings])
        expectEqual(reply.status, 200, "quick play failed: \(reply.text)")
        return (reply.json["room"] as? String ?? "", reply.json["playerID"] as? String ?? "")
    }

    private static func state(_ code: String) -> [String: Any] {
        request("GET", "/api/room/\(code)/state").json
    }

    /// Polls until `condition` holds, so tests never depend on a fixed sleep.
    @discardableResult
    private static func waitUntil(_ seconds: Double = 5,
                                  _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    // MARK: - Tests

    static func run() {
        guard boot() else { return }
        defer { server.stop() }

        Harness.suite("the server") {

            Harness.test("reports its health and atlas size") {
                let reply = request("GET", "/api/health")
                expectEqual(reply.status, 200)
                expectEqual(reply.json["ok"] as? Bool, true)
                expectGreater(reply.json["places"] as? Int ?? 0, 1_000)
            }

            Harness.test("serves the web client") {
                for (path, needle) in [("/", "<title>Atlas</title>"),
                                       ("/app.js", "EventSource"),
                                       ("/style.css", "--accent"),
                                       ("/manifest.webmanifest", "standalone")] {
                    let reply = request("GET", path)
                    expectEqual(reply.status, 200, "GET \(path)")
                    expect(reply.text.contains(needle),
                           "GET \(path) did not look like the real file")
                }
            }

            Harness.test("does not serve anything outside the public directory") {
                for path in ["/../Package.swift", "/%2e%2e/Package.swift", "//etc/passwd"] {
                    let text = request("GET", path).text
                    expect(!text.contains("swift-tools-version"), "\(path) served the manifest")
                    expect(!text.contains("root:"), "\(path) served /etc/passwd")
                }
            }

            Harness.test("answers unknown rooms and routes with 404") {
                expectEqual(request("GET", "/api/room/ZZZZ/state").status, 404)
                expectEqual(request("POST", "/api/room/ZZZZ/start",
                                    body: ["playerID": "x"]).status, 404)
                expectEqual(request("GET", "/api/nonsense").status, 404)
            }

            Harness.test("answers atlas lookups") {
                expectEqual(request("GET", "/api/atlas?q=Sydney").json["found"] as? Bool, true)
                expectEqual(request("GET", "/api/atlas?q=Sqzlandia").json["found"] as? Bool,
                            false)
            }
        }

        Harness.suite("rooms over HTTP") {

            Harness.test("quick play hands back a game ready to move in") {
                let (code, me) = quickRoom()
                expectEqual(code.count, 4)
                let view = state(code)
                expectEqual(view["phase"] as? String, "playing")
                expectEqual(view["currentPlayerID"] as? String, me)
                expectEqual((view["players"] as? [[String: Any]])?.count, 2)
                expectNotNil(view["requiredLetter"])
            }

            Harness.test("its own hints are playable") {
                let (code, me) = quickRoom()
                let hints = request("GET", "/api/room/\(code)/hint").json["hints"] as? [String]
                expect(!(hints ?? []).isEmpty, "no hints offered")
                guard let first = hints?.first else { return }
                let result = request("POST", "/api/room/\(code)/submit",
                                     body: ["playerID": me, "text": first])
                expectEqual(result.json["ok"] as? Bool, true,
                            "the server refused its own hint: \(result.text)")
            }

            Harness.test("only the host can start the game") {
                let host = request("POST", "/api/room",
                                   body: ["name": "Host",
                                          "table": ["turnSeconds": 20]]).json
                let code = host["room"] as? String ?? ""
                let hostID = host["playerID"] as? String ?? ""
                let guest = request("POST", "/api/room/\(code)/join", body: ["name": "Guest"]).json
                let guestID = guest["playerID"] as? String ?? ""
                expectNotEqual(guestID, "")
                expectEqual(guest["isHost"] as? Bool ?? false, false)

                expectEqual(request("POST", "/api/room/\(code)/start",
                                    body: ["playerID": guestID]).status, 403)
                expectEqual(request("POST", "/api/room/\(code)/start",
                                    body: ["playerID": hostID]).status, 200)
                expectEqual(state(code)["phase"] as? String, "playing")
            }

            Harness.test("rejoining with the same id keeps your seat") {
                let host = request("POST", "/api/room", body: ["name": "Host"]).json
                let code = host["room"] as? String ?? ""
                let guest = request("POST", "/api/room/\(code)/join", body: ["name": "Guest"]).json
                let guestID = guest["playerID"] as? String ?? ""

                let again = request("POST", "/api/room/\(code)/join",
                                    body: ["name": "Guest", "playerID": guestID]).json
                expectEqual(again["playerID"] as? String, guestID)
                expectEqual((state(code)["players"] as? [[String: Any]])?.count, 2,
                            "a reconnect created a duplicate seat")
            }

            Harness.test("refuses illegal moves with a reason the phone can show") {
                let (code, me) = quickRoom()
                let letter = state(code)["requiredLetter"] as? String ?? "s"
                let wrongLetter = letter == "p" ? "Sydney" : "Paris"

                let refused = request("POST", "/api/room/\(code)/submit",
                                      body: ["playerID": me, "text": wrongLetter]).json
                expectEqual(refused["ok"] as? Bool, false)
                expectEqual(refused["code"] as? String, "wrong_letter")
                expectNotNil(refused["error"], "a refusal with nothing to show the player")

                let notYours = request("POST", "/api/room/\(code)/submit",
                                       body: ["playerID": "nobody", "text": "Sydney"]).json
                expectEqual(notYours["code"] as? String, "not_your_turn")
            }

            Harness.test("flags unknown places as challengeable") {
                let (code, me) = quickRoom()
                let letter = (state(code)["requiredLetter"] as? String ?? "s").uppercased()
                let refused = request("POST", "/api/room/\(code)/submit",
                                      body: ["playerID": me,
                                             "text": letter + "qzlandia"]).json
                expectEqual(refused["code"] as? String, "not_in_atlas")
                expectEqual(refused["canChallenge"] as? Bool, true)
            }
        }

        Harness.suite("table modes over HTTP") {

            Harness.test("the home screen can list the modes") {
                let reply = request("GET", "/api/modes")
                expectEqual(reply.status, 200)
                let modes = reply.json["modes"] as? [[String: String]] ?? []
                expectEqual(modes.count, TableMode.allCases.count)
                for mode in modes {
                    expectNotNil(mode["id"])
                    expect(!(mode["title"] ?? "").isEmpty)
                    expect(!(mode["blurb"] ?? "").isEmpty)
                }
                expect(modes.contains { $0["id"] == "blitz" })
            }

            Harness.test("a named mode sets the whole table") {
                let (code, _) = quickRoom(table: ["mode": "brutal", "turnSeconds": 12])
                let config = state(code)["config"] as? [String: Any] ?? [:]
                expectEqual(config["forcedCards"] as? Bool, true)
                expectEqual(config["lives"] as? Int, 1)
                expectGreater(config["turnDecay"] as? Double ?? 0, 0)
            }

            Harness.test("an explicit setting beats the mode it came with") {
                let (code, _) = quickRoom(table: ["mode": "classic", "cardChance": 1,
                                                  "lives": 4, "turnSeconds": 45])
                let config = state(code)["config"] as? [String: Any] ?? [:]
                expectEqual(config["cardChance"] as? Double, 1)
                expectEqual(config["lives"] as? Int, 4)
                expectClose(config["turnSeconds"] as? Double ?? 0, 45)
            }

            Harness.test("nonsense settings are clamped, not obeyed") {
                let (code, _) = quickRoom(table: ["turnSeconds": 0.001, "lives": 9999,
                                                   "cardChance": 7, "turnDecay": -3,
                                                   "minimumTurnSeconds": 900,
                                                   "cardTiers": ["nonsense"]])
                let config = state(code)["config"] as? [String: Any] ?? [:]
                expectAtLeast(config["turnSeconds"] as? Double ?? 0, 5)
                expect((config["lives"] as? Int ?? 0) <= 9)
                expect((config["cardChance"] as? Double ?? 9) <= 1)
                expectAtLeast(config["turnDecay"] as? Double ?? -1, 0)
                expect((config["minimumTurnSeconds"] as? Double ?? 999)
                       <= (config["turnSeconds"] as? Double ?? 0),
                       "the floor must not sit above the clock")
                expectEqual(config["cardChance"] as? Double, 0,
                            "a deck with no tiers is a deck that is switched off")
            }

            Harness.test("an unknown mode name leaves the table alone") {
                let (code, _) = quickRoom(table: ["mode": "hyperspeed"])
                expectEqual(state(code)["phase"] as? String, "playing")
            }

            Harness.test("only the host may change the table") {
                let host = request("POST", "/api/room", body: ["name": "Host"]).json
                let code = host["room"] as? String ?? ""
                let hostID = host["playerID"] as? String ?? ""
                let guestID = request("POST", "/api/room/\(code)/join",
                                      body: ["name": "Guest"]).json["playerID"] as? String ?? ""

                expectEqual(request("POST", "/api/room/\(code)/config",
                                    body: ["playerID": guestID,
                                           "table": ["mode": "brutal"]]).status, 403)
                expectEqual(request("POST", "/api/room/\(code)/config",
                                    body: ["playerID": hostID,
                                           "table": ["mode": "marathon"]]).status, 200)
                let config = state(code)["config"] as? [String: Any] ?? [:]
                expectEqual(config["lives"] as? Int, 3)
            }
        }

        Harness.suite("challenges over HTTP") {

            Harness.test("an upheld challenge plays the move and grows the atlas") {
                let (code, me) = quickRoom()
                let letter = (state(code)["requiredLetter"] as? String ?? "s").uppercased()
                let invented = letter + "qzlandia"
                stub.stub(invented, VerificationResult(accepted: true, resolvedName: invented,
                                                       kind: "city", reason: "confirmed"))

                let started = request("POST", "/api/room/\(code)/challenge",
                                      body: ["playerID": me, "text": invented])
                expectEqual(started.status, 200)
                expectEqual(started.json["ok"] as? Bool, true)

                var moves: [[String: Any]] = []
                waitUntil {
                    moves = state(code)["moves"] as? [[String: Any]] ?? []
                    return !moves.isEmpty
                }
                expectEqual(moves.first?["text"] as? String, invented)
                expectEqual(moves.first?["viaChallenge"] as? Bool, true)

                let lookup = request("GET", "/api/atlas?q=\(invented)").json
                expectEqual(lookup["found"] as? Bool, true, "the place was not kept")
                expectEqual(lookup["learned"] as? Bool, true)
            }

            Harness.test("a refused challenge leaves the chain alone") {
                let (code, me) = quickRoom()
                let letter = (state(code)["requiredLetter"] as? String ?? "s").uppercased()
                let invented = letter + "qzlandia2"     // the stub says no to this one

                request("POST", "/api/room/\(code)/challenge",
                        body: ["playerID": me, "text": invented])
                waitUntil { state(code)["pending"] == nil }

                let view = state(code)
                expectNil(view["pending"], "the challenge never resolved")
                expectEqual((view["moves"] as? [[String: Any]])?.isEmpty, true)
                expectEqual(view["currentPlayerID"] as? String, me, "the player lost their turn")
            }
        }

        Harness.suite("bad input and load") {

            Harness.test("malformed requests do not take the server down") {
                let (code, me) = quickRoom()
                let bad: [Data] = [Data("not json{{".utf8), Data("[]".utf8),
                                   Data("{\"playerID\": 5, \"text\": []}".utf8), Data()]
                for body in bad {
                    let status = request("POST", "/api/room/\(code)/submit",
                                         rawBody: body).status
                    expect((200...499).contains(status),
                           "status \(status) for a \(body.count)-byte body")
                }

                let huge = String(repeating: "x", count: 200_000)
                request("POST", "/api/room/\(code)/submit",
                        body: ["playerID": me, "text": huge])

                expectEqual(request("GET", "/api/health").status, 200,
                            "the server did not survive")
            }

            Harness.test("the event stream pushes state") {
                let (code, me) = quickRoom()
                let collector = StreamCollector()
                let session = URLSession(configuration: .default, delegate: collector,
                                         delegateQueue: nil)
                let task = session.dataTask(with: url("/api/room/\(code)/events?playerID=\(me)"))
                task.resume()
                let arrived = waitUntil(15) {
                    let text = collector.snapshot()
                    return text.contains("event: state") && text.contains("\"phase\"")
                }
                task.cancel()
                session.invalidateAndCancel()
                expect(arrived, "no state event arrived on the stream")
            }

            Harness.test("many rooms run at once") {
                let group = DispatchGroup()
                let lock = NSLock()
                var codes: [String] = []
                for i in 0..<16 {
                    group.enter()
                    DispatchQueue.global().async {
                        let json = request("POST", "/api/quick",
                                           body: ["name": "P\(i)", "bots": 2]).json
                        if let code = json["room"] as? String {
                            lock.lock(); codes.append(code); lock.unlock()
                        }
                        group.leave()
                    }
                }
                expectEqual(group.wait(timeout: .now() + 60), .success)
                expectEqual(codes.count, 16)
                expectEqual(Set(codes).count, 16, "two rooms got the same code")

                // Let the bots play, then check every room is still coherent.
                Thread.sleep(forTimeInterval: 3)
                for code in codes {
                    expectNotNil(state(code)["phase"], "room \(code) stopped answering")
                }
                expectEqual(request("GET", "/api/health").json["ok"] as? Bool, true)
            }

            Harness.test("a phone that stops reading does not freeze the server") {
                // A locked screen leaves the event stream open but unread.  The
                // socket fills up, and any push to it blocks — so if pushes go
                // out on the thread that drives the clocks, one sleeping phone
                // stops every game on the server.  It did; hence this test.
                let (wedged, wedgedID) = quickRoom(turnSeconds: 60)
                let (live, _) = quickRoom(turnSeconds: 60)

                guard let deaf = DeafClient(port: port,
                                            path: "/api/room/\(wedged)/events?playerID=\(wedgedID)")
                else { return fail("could not open a socket") }
                defer { deaf.close() }
                Thread.sleep(forTimeInterval: 0.3)

                // Every rejected move forces a push, so this fills that socket.
                let started = Date()
                for i in 0..<400 {
                    request("POST", "/api/room/\(wedged)/submit",
                            body: ["playerID": wedgedID, "text": "Zzzz\(i)"])
                }
                expectLess(Date().timeIntervalSince(started), 30,
                           "pushing to an unread socket held up the caller")

                let before = state(live)["timeLeft"] as? Double ?? -1
                let ticking = waitUntil(8) {
                    (state(live)["timeLeft"] as? Double ?? -1) < before - 1
                }
                expect(ticking, "the other table's clock stopped")
                expectEqual(request("GET", "/api/health").json["ok"] as? Bool, true)
            }
        }
    }
}

/// The C `close`, captured at file scope where nothing shadows it.  `DeafClient`
/// has a `close()` of its own, so the call inside it has to name something else
/// — and naming `Darwin.close` names a module that only exists on a Mac.
private let closeFD = close

/// A client that asks for the event stream and then never reads a byte of it,
/// with a receive buffer small enough that the server notices quickly.
private final class DeafClient {
    private let fd: Int32

    init?(port: UInt16, path: String) {
        fd = socket(AF_INET, streamSocket, 0)
        guard fd >= 0 else { return nil }
        var small: Int32 = 2048
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected >= 0 else { _ = closeFD(fd); return nil }

        let request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let sent = Array(request.utf8).withUnsafeBufferPointer {
            write(fd, $0.baseAddress, $0.count)
        }
        guard sent > 0 else { _ = closeFD(fd); return nil }
    }

    func close() { _ = closeFD(fd) }
}

/// Collects an SSE body as it streams in.
private final class StreamCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var buffer = ""
    private let lock = NSLock()

    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer += String(decoding: data, as: UTF8.self)
    }
}
