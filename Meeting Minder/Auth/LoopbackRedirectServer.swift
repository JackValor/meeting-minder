import Foundation
import Network
import os

/// Minimal single-shot HTTP listener on 127.0.0.1, used as the OAuth redirect target
/// for Google's "Desktop app" installed-application flow.
///
/// It accepts exactly one authorization redirect, answers with a small confirmation
/// page, and then tears itself down.
final class LoopbackRedirectServer {
    enum ServerError: LocalizedError {
        case cannotBind(String?)
        case timedOut
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cannotBind(let reason):
                let base = "Could not open a local port to receive the Google sign-in response."
                return reason.map { "\(base) (\($0))" } ?? base
            case .timedOut: return "Timed out waiting for the Google sign-in to complete."
            case .cancelled: return "Sign-in was cancelled."
            }
        }
    }

    private let queue = DispatchQueue(label: "com.valorstudio.meetingminder.loopback")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var finished = false

    private(set) var port: UInt16 = 0

    var redirectURI: String { "http://127.0.0.1:\(port)" }

    // MARK: - Lifecycle

    /// Binds to an ephemeral loopback port. Retries a handful of times because the
    /// chosen port can race with another process.
    func start() async throws -> UInt16 {
        var lastError: Error?
        for _ in 0..<12 {
            let candidate = UInt16.random(in: 49152...65500)
            do {
                let bound = try await bind(to: candidate)
                port = bound
                return bound
            } catch {
                lastError = error
            }
        }
        let reason = lastError.map { String(describing: $0) }
        Log.auth.error("Could not bind a loopback port: \(reason ?? "unknown", privacy: .public)")
        throw ServerError.cannotBind(reason)
    }

    private func bind(to rawPort: UInt16) async throws -> UInt16 {
        guard let nwPort = NWEndpoint.Port(rawValue: rawPort) else { throw ServerError.cannotBind(nil) }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind loopback-only so nothing on the LAN can reach the redirect handler.
        // This also fixes the port, so it must NOT be repeated via `NWListener(using:on:)`
        // — passing both makes the initialiser throw EINVAL.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? rawPort)
                case .failed(let error), .waiting(let error):
                    guard !resumed else { return }
                    resumed = true
                    listener.cancel()
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: ServerError.cancelled)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Waits for the browser to hit the redirect URI and returns its query parameters.
    func waitForRedirect(timeout: TimeInterval = 300) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.finished else {
                    continuation.resume(throwing: ServerError.cancelled)
                    return
                }
                self.continuation = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(ServerError.timedOut))
                }
            }
        }
    }

    func stop() {
        queue.async { self.finish(.failure(ServerError.cancelled)) }
    }

    /// Resumes the waiter at most once and tears down all networking.
    private func finish(_ result: Result<[String: String], Error>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished else { return }
        finished = true

        let continuation = self.continuation
        self.continuation = nil

        connections.forEach { $0.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil

        continuation?.resume(with: result)
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
                self.handleRequest(head: head, on: connection)
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func handleRequest(head: String, on connection: NWConnection) {
        guard let requestLine = head.split(separator: "\r\n").first else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }
        let target = String(parts[1])

        // Browsers eagerly request /favicon.ico; that is not the redirect.
        guard !target.hasPrefix("/favicon.ico") else {
            respond(on: connection, status: "404 Not Found", html: "")
            return
        }

        var params: [String: String] = [:]
        if let components = URLComponents(string: "http://127.0.0.1\(target)") {
            for item in components.queryItems ?? [] {
                params[item.name] = item.value ?? ""
            }
        }

        guard !params.isEmpty else {
            respond(on: connection, status: "400 Bad Request", html: Self.page(
                title: "Nothing to see here",
                message: "This page only handles the Google sign-in redirect."
            ))
            return
        }

        let succeeded = params["error"] == nil
        respond(on: connection, status: "200 OK", html: Self.page(
            title: succeeded ? "Meeting Minder is connected" : "Sign-in failed",
            message: succeeded
                ? "You can close this tab and go back to the app."
                : "Google reported: \(params["error"] ?? "unknown error"). You can close this tab and try again."
        ))

        queue.asyncAfter(deadline: .now() + 0.2) {
            self.finish(.success(params))
        }
    }

    private func respond(on connection: NWConnection, status: String, html: String) {
        let body = Data(html.utf8)
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(title)</title>
        <style>
          :root { color-scheme: light dark; }
          body { margin:0; min-height:100vh; display:grid; place-items:center;
                 font: 16px/1.5 -apple-system, system-ui, sans-serif;
                 background:#0d1117; color:#e6edf3; }
          .card { text-align:center; padding:48px 56px; border-radius:18px;
                  background:#161b22; border:1px solid #30363d; max-width:420px; }
          h1 { font-size:22px; margin:0 0 10px; }
          p { margin:0; color:#9198a1; }
        </style></head>
        <body><div class="card"><h1>\(title)</h1><p>\(message)</p></div></body></html>
        """
    }
}
