import Foundation

// Three C libraries, one set of sockets.  Musl is what a statically linked
// Linux binary gets and it is *not* Glibc, so a two-way test falls through to
// Darwin and fails to build for exactly the platform this is deployed on.
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// The C `close`, under a name of its own.  The connection type below has a
/// `close()` method of its own, and an unqualified call inside it finds that
/// one and fails — but out here at file scope nothing shadows it, so the C
/// function can be captured once without naming the module it came from, which
/// is the part that differs between Darwin, Glibc and Musl.
let closeSocket = close

// The three socket constants whose *Swift type* differs by platform, pinned to
// Int32 once here so that no call site has to know.
//
// The C libraries agree on the values and disagree on how Swift imports them:
// Glibc hands `SOCK_STREAM` over as a `__socket_type` struct, and `SHUT_RDWR`
// and `IPPROTO_TCP` as `Int`, where Darwin and Musl give all three as `Int32`.
// The rest — `AF_INET`, `SOL_SOCKET`, `TCP_NODELAY`, the timeout options —
// import as `Int32` everywhere and are left alone.
//
// This is precisely the gap `tools/linux_build.sh` cannot see: the static Linux
// SDK is musl, so a clean cross-compile proves the Musl path and says nothing
// about the Glibc one the deployed container is actually built on.  These lines
// are the difference between a green build here and a failed deploy there.
#if canImport(Glibc)
public let streamSocket = Int32(SOCK_STREAM.rawValue)
#else
public let streamSocket = Int32(SOCK_STREAM)
#endif
public let shutdownBoth = Int32(SHUT_RDWR)
public let tcpProtocol = Int32(IPPROTO_TCP)

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public func json<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: body)
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int = 200
    public var headers: [String: String] = [:]
    public var body: Data = Data()

    public static func text(_ s: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: ["Content-Type": "text/plain; charset=utf-8"],
                     body: Data(s.utf8))
    }

    public static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status,
                            headers: ["Content-Type": "application/json; charset=utf-8",
                                      "Cache-Control": "no-store"],
                            body: data)
    }

    public static func data(_ data: Data, type: String, cache: String = "no-cache") -> HTTPResponse {
        HTTPResponse(status: 200,
                     headers: ["Content-Type": type, "Cache-Control": cache],
                     body: data)
    }

    static let statusText: [Int: String] = [
        200: "OK", 201: "Created", 204: "No Content", 304: "Not Modified",
        400: "Bad Request", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large",
        429: "Too Many Requests", 500: "Internal Server Error",
    ]
}

/// A live connection.  A handler either returns a response or takes the socket
/// over for server-sent events.
public final class HTTPConnection: @unchecked Sendable {
    private let fd: Int32
    private let writeLock = NSLock()
    private var closed = false
    /// Set once the handler has turned this into an event stream.
    public private(set) var isStream = false

    init(fd: Int32) { self.fd = fd }

    /// Switches the connection into `text/event-stream` mode.  The caller keeps
    /// the object and pushes with ``send(event:data:)`` until ``close()``.
    public func beginEventStream() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isStream, !closed else { return }
        isStream = true
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream; charset=utf-8\r
        Cache-Control: no-store\r
        Connection: keep-alive\r
        X-Accel-Buffering: no\r
        \r

        """
        _ = writeRaw(Data(head.utf8))
    }

    /// Returns false once the peer has gone away.
    @discardableResult
    public func send(event: String?, data: String) -> Bool {
        var payload = ""
        if let event { payload += "event: \(event)\n" }
        // A data field cannot contain newlines; each line needs its own prefix.
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            payload += "data: \(line)\n"
        }
        payload += "\n"
        writeLock.lock()
        defer { writeLock.unlock() }
        return writeRaw(Data(payload.utf8))
    }

    @discardableResult
    public func comment(_ text: String) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        return writeRaw(Data(": \(text)\n\n".utf8))
    }

    func respond(_ response: HTTPResponse, keepAlive: Bool) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = keepAlive ? "keep-alive" : "close"
        let reason = HTTPResponse.statusText[response.status] ?? "OK"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        writeLock.lock()
        defer { writeLock.unlock() }
        var out = Data(head.utf8)
        out.append(response.body)
        _ = writeRaw(out)
    }

    /// How long a single push may spend waiting on a client that has stopped
    /// reading before that client is declared gone.  A phone that locks its
    /// screen mid-game does exactly this, and a `write` blocked on its full
    /// socket buffer would otherwise hold up whoever is pushing — which, for
    /// state broadcasts, is everybody else's game too.
    private static let writeDeadline: TimeInterval = 3

    /// Must be called with `writeLock` held.
    private func writeRaw(_ data: Data) -> Bool {
        guard !closed else { return false }
        var ok = true
        let giveUpAt = Date().addingTimeInterval(HTTPConnection.writeDeadline)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                // The socket send timeout turns a wedged client into EAGAIN
                // rather than an indefinite block; retry, but not forever.
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK),
                   Date() < giveUpAt { continue }
                ok = false
                break
            }
        }
        if !ok { closed = true }
        return ok
    }

    public func close() {
        writeLock.lock()
        let wasClosed = closed
        closed = true
        writeLock.unlock()
        if !wasClosed { shutdown(fd, shutdownBoth) }
        _ = closeSocket(fd)
    }

    public var isAlive: Bool {
        writeLock.lock(); defer { writeLock.unlock() }; return !closed
    }
}

public enum HTTPServerError: Error, CustomStringConvertible {
    case socketFailed(String)
    case bindFailed(port: UInt16, String)
    case listenFailed(String)

    public var description: String {
        switch self {
        case .socketFailed(let e): return "could not create socket: \(e)"
        case .bindFailed(let p, let e): return "could not bind port \(p): \(e) (is another atlas already running?)"
        case .listenFailed(let e): return "could not listen: \(e)"
        }
    }
}

/// A small blocking HTTP/1.1 server.
///
/// One thread accepts, one dispatch job per connection.  That is more than
/// enough for a handful of phones on a home network, and it keeps the whole
/// thing dependency-free and easy to reason about.
public final class HTTPServer: @unchecked Sendable {

    public typealias Handler = @Sendable (HTTPRequest, HTTPConnection) -> HTTPResponse?

    private var listenFD: Int32 = -1
    private let handler: Handler
    private let queue = DispatchQueue(label: "atlas.http", attributes: .concurrent)
    private var running = false

    /// Requests larger than this are refused outright.
    private static let maxBodyBytes = 1 << 20

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func start(host: String, port: UInt16) throws {
        signal(SIGPIPE, SIG_IGN)

        let fd = socket(AF_INET, streamSocket, 0)
        guard fd >= 0 else { throw HTTPServerError.socketFailed(String(cString: strerror(errno))) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = host == "0.0.0.0" ? INADDR_ANY : inet_addr(host)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound >= 0 else {
            let err = String(cString: strerror(errno))
            close(fd)
            throw HTTPServerError.bindFailed(port: port, err)
        }
        guard listen(fd, 64) >= 0 else {
            let err = String(cString: strerror(errno))
            close(fd)
            throw HTTPServerError.listenFailed(err)
        }

        listenFD = fd
        running = true
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        running = false
        if listenFD >= 0 { shutdown(listenFD, shutdownBoth); close(listenFD); listenFD = -1 }
    }

    private func acceptLoop(_ fd: Int32) {
        while running {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fd, &addr, &len)
            if client < 0 {
                if errno == EINTR { continue }
                if running { Thread.sleep(forTimeInterval: 0.05) }
                continue
            }
            var one: Int32 = 1
            setsockopt(client, tcpProtocol, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            queue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        // Idle sockets must not pin a thread forever.
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Nor may a client that has stopped reading block whoever writes to it.
        var sendTimeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout,
                   socklen_t(MemoryLayout<timeval>.size))

        let connection = HTTPConnection(fd: fd)
        guard let request = readRequest(fd) else {
            connection.respond(.text("bad request", status: 400), keepAlive: false)
            connection.close()
            return
        }
        if let response = handler(request, connection) {
            connection.respond(response, keepAlive: false)
            connection.close()
        }
        // Otherwise the handler owns the socket (event stream) and will close it.
    }

    private func readRequest(_ fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)

        // Headers first.
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > HTTPServer.maxBodyBytes { return nil }
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
        }
        guard let separator = headerEnd,
              let head = String(data: buffer[..<separator.lowerBound], encoding: .utf8)
        else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let value = parts.count > 1
                    ? (String(parts[1]).replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? "")
                    : ""
                query[key] = value
            }
        }
        path = path.removingPercentEncoding ?? path

        var body = Data(buffer[separator.upperBound...])
        let expected = Int(headers["content-length"] ?? "0") ?? 0
        guard expected <= HTTPServer.maxBodyBytes else { return nil }
        while body.count < expected {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            body.append(contentsOf: chunk[0..<n])
        }

        return HTTPRequest(method: method, path: path, query: query,
                           headers: headers, body: body)
    }
}
