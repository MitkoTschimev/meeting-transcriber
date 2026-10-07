import Foundation
import Network
import os

/// One-shot HTTP listener on `127.0.0.1` for Google's Desktop OAuth redirect.
///
/// Google installed-app clients only allow loopback redirects (not a custom
/// URL scheme). The listener binds an ephemeral port, reports the redirect
/// URI, then waits for a single GET with `code`/`state` (or `error`).
final class LoopbackRedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.meetingtranscriber.oauth.loopback")
    private var continuation: CheckedContinuation<Callback, any Error>?
    private(set) var port: UInt16

    struct Callback: Equatable, Sendable {
        var code: String?
        var state: String?
        var error: String?
    }

    var redirectURI: String {
        "http://127.0.0.1:\(port)"
    }

    static func start() throws -> LoopbackRedirectServer {
        try LoopbackRedirectServer()
    }

    private init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: .any,
        )
        listener = try NWListener(using: params)
        port = 0
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        let ready = DispatchSemaphore(value: 0)
        let startError = OSAllocatedUnfairLock<(any Error)?>(initialState: nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()

            case let .failed(error):
                startError.withLock { $0 = error }
                ready.signal()

            default:
                break
            }
        }
        listener.start(queue: queue)
        ready.wait()
        if let error = startError.withLock(\.self) {
            throw GoogleOAuthError.server(error.localizedDescription)
        }
        guard let bound = listener.port?.rawValue, bound > 0 else {
            throw GoogleOAuthError.server("Could not bind a loopback port for Google sign-in.")
        }
        port = bound
    }

    func waitForCallback(timeout: TimeInterval = 180) async throws -> Callback {
        try await withCheckedThrowingContinuation { continuation in
            queue.sync {
                self.continuation = continuation
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finishTimeout()
            }
        }
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        queue.sync {
            continuation?.resume(throwing: GoogleOAuthError.timeout)
            continuation = nil
        }
    }

    deinit {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
    }

    static func parseCallback(from target: String) -> Callback {
        let path = target.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? target
        guard let components = URLComponents(string: path) ?? URLComponents(string: "http://127.0.0.1\(path)") else {
            return Callback()
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        return Callback(code: value("code"), state: value("state"), error: value("error"))
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            let callback = Self.parseCallback(from: Self.requestTarget(data))
            let body = Self.responseHTML(for: callback)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
            let payload = Data(header.utf8) + Data(body.utf8)
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
            self.finish(callback, error: error)
        }
    }

    private func finishTimeout() {
        guard let pending = continuation else { return }
        continuation = nil
        pending.resume(throwing: GoogleOAuthError.timeout)
    }

    private func finish(_ callback: Callback, error: NWError?) {
        guard let pending = continuation else { return }
        continuation = nil
        if let error {
            pending.resume(throwing: GoogleOAuthError.server(error.localizedDescription))
        } else {
            pending.resume(returning: callback)
        }
    }

    private static func requestTarget(_ data: Data?) -> String {
        guard let data, let text = String(data: data, encoding: .utf8) else { return "" }
        let firstLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return firstLine }
        return String(parts[1])
    }

    private static func responseHTML(for callback: Callback) -> String {
        let message = if callback.error == "access_denied" {
            "Google Calendar access was cancelled. You can close this window."
        } else if callback.code != nil {
            "Meeting Transcriber is connected to Google Calendar. You can close this window."
        } else {
            "Meeting Transcriber could not finish Google Calendar sign-in. You can close this window and try again."
        }
        return "<!DOCTYPE html><html><body><p>\(message)</p></body></html>"
    }
}
