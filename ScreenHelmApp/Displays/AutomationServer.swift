import AppKit
import ScreenHelmCore
import Network
import Security
import os

/// The ways a display command gets into the running app from outside it:
/// a socket for the command line, and an HTTP server on this Mac only.
/// Both are off until turned on in the Automation page.
@MainActor
final class AutomationServer {
    static let shared = AutomationServer()

    private var socketSource: DispatchSourceRead?
    private var socketDescriptor: Int32 = -1
    private var listener: NWListener?
    private var listeningPort = 0
    private var started = false
    private let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    private var settings: AppSettings { SettingsViewModel.shared.settings }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        track()
    }

    private func track() {
        withObservationTracking {
            _ = settings.displaysAutomation
            _ = settings.displaysHTTPEnabled
            _ = settings.displaysHTTPPort
        } onChange: {
            Task { @MainActor in AutomationServer.shared.track() }
        }
        settings.displaysAutomation ? startSocket() : stopSocket()
        if settings.displaysHTTPEnabled {
            if listener == nil || listeningPort != settings.displaysHTTPPort { startHTTP() }
        } else {
            stopHTTP()
        }
    }

    var socketIsListening: Bool { socketSource != nil }
    var httpIsListening: Bool { listener != nil }

    // MARK: - Command line

    /// In the user's own temporary folder, which no other user can enter;
    /// short enough for a socket's path, which a long home folder wouldn't be.
    nonisolated static var socketPath: String {
        FileManager.default.temporaryDirectory.appendingPathComponent("com.dangkhoabach.screenhelm.display.sock").path
    }

    private func startSocket() {
        guard socketSource == nil else { return }
        let path = Self.socketPath
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            close(descriptor)
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Only the user who runs ScreenHelm may write to it.
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            unlink(path)
            log.error("command socket not opened")
            return
        }
        socketDescriptor = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { AutomationServer.shared.acceptSocketClient() } }
        source.resume()
        socketSource = source
    }

    private func stopSocket() {
        guard let source = socketSource else { return }
        source.cancel()
        socketSource = nil
        close(socketDescriptor)
        socketDescriptor = -1
        unlink(Self.socketPath)
    }

    /// One request per connection: a JSON array of words, a newline; then
    /// the reply. Reading waits on the client, so it is done off the main
    /// thread; only the command runs on it.
    private func acceptSocketClient() {
        let client = accept(socketDescriptor, nil, nil)
        guard client >= 0 else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let request = Self.readRequest(from: client)
            Task { @MainActor in
                let reply: AutomationReply
                if let arguments = try? JSONDecoder().decode([String].self, from: request) {
                    reply = AutomationRouter.run(arguments: arguments)
                } else {
                    reply = .failed("the request could not be read")
                }
                let line = (reply.ok ? "OK\n" : "ERROR\n") + reply.text + "\n"
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = line.withCString { write(client, $0, strlen($0)) }
                    close(client)
                }
            }
        }
    }

    /// Up to a newline, 64 KB or five seconds, whichever comes first.
    nonisolated private static func readRequest(from client: Int32) -> Data {
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let deadline = Date().addingTimeInterval(5)
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count < 65536, !request.contains(0x0A), Date() < deadline {
            let count = read(client, &buffer, buffer.count)
            if count > 0 {
                request.append(contentsOf: buffer[0..<count])
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                break
            }
        }
        return request
    }

    // MARK: - HTTP

    private func startHTTP() {
        stopHTTP()
        let parameters = NWParameters.tcp
        // This Mac only: the loopback address, never the network.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(clamping: settings.displaysHTTPPort)) ?? 55777)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            log.error("HTTP listener not made")
            return
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            // One that never finishes its request is closed after a few seconds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { connection.cancel() }
            AutomationServer.receiveRequest(on: connection, buffer: Data())
        }
        // A port another program holds: the listener fails, and is let go so
        // that it isn't taken for listening; a change of port tries again.
        listener.stateUpdateHandler = { state in
            guard case .failed(let error) = state else { return }
            MainActor.assumeIsolated { AutomationServer.shared.httpFailed(error) }
        }
        listener.start(queue: .main)
        self.listener = listener
        listeningPort = settings.displaysHTTPPort
    }

    private func httpFailed(_ error: NWError) {
        log.error("HTTP listener on port \(self.listeningPort) failed: \(String(describing: error), privacy: .public)")
        listener?.cancel()
        listener = nil
        listeningPort = 0
    }

    /// The request as it arrives, in as many parts as it comes in, up to
    /// the end of its headers.
    nonisolated private static func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            let ended = buffer.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete || error != nil || buffer.count >= 16384
            guard ended else { return receiveRequest(on: connection, buffer: buffer) }
            MainActor.assumeIsolated {
                let response = AutomationServer.respond(to: String(decoding: buffer, as: UTF8.self), token: AutomationToken.current())
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func stopHTTP() {
        listener?.cancel()
        listener = nil
        listeningPort = 0
    }

    /// The whole of the HTTP this server speaks: one GET or POST of
    /// `/display/<verb>?…`, with the token in an Authorization header or
    /// as `token=`. Anything else is turned away.
    static func respond(to request: String, token: String) -> String {
        func response(_ status: String, _ body: String, type: String = "text/plain") -> String {
            "HTTP/1.1 \(status)\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        }
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "POST", let url = URL(string: "http://localhost" + parts[1]),
              url.path.hasPrefix("/display/") else { return response("404 Not Found", "not found\n") }
        var given = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" }?.value ?? ""
        for line in lines.dropFirst() where line.lowercased().hasPrefix("authorization: bearer ") {
            given = String(line.dropFirst("authorization: bearer ".count))
        }
        guard !token.isEmpty, ConstantTime.equal(given, token) else { return response("401 Unauthorized", "a valid token is required\n") }
        let reply = AutomationRouter.run(url: url)
        let isJSON = reply.text.hasPrefix("{")
        return response(reply.ok ? "200 OK" : "400 Bad Request", reply.text + "\n", type: isJSON ? "application/json" : "text/plain")
    }
}

/// The secret an HTTP request must carry, made on first use and kept in the login Keychain.
enum AutomationToken {
    private static let service = "com.dangkhoabach.screenhelm.automation"
    private static let account = "http-token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func current() -> String {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return String(decoding: data, as: UTF8.self)
        }
        return renew()
    }

    /// A new token; the old one stops working at once.
    @discardableResult
    static func renew() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return "" }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? token : ""
    }
}

/// `ScreenHelm display set name=Studio brightness=0.6` from a terminal: the
/// executable started this way hands the words to the running app and
/// prints its answer.
enum AutomationClient {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2, arguments[1] == "display" else { return }
        let words = Array(arguments.dropFirst(2))
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = AutomationServer.socketPath
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard descriptor >= 0, connected == 0 else {
            FileHandle.standardError.write(Data("ScreenHelm isn't running, or commands are turned off in Automation.\n".utf8))
            exit(1)
        }
        var request = (try? JSONEncoder().encode(words)) ?? Data("[]".utf8)
        request.append(0x0A)
        _ = request.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while case let count = read(descriptor, &buffer, buffer.count), count > 0 { answer.append(contentsOf: buffer[0..<count]) }
        close(descriptor)
        let text = String(decoding: answer, as: UTF8.self)
        let ok = text.hasPrefix("OK\n")
        let body = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined()
        (ok ? FileHandle.standardOutput : FileHandle.standardError).write(Data(body.utf8))
        exit(ok ? 0 : 1)
    }
}
