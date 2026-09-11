import Foundation
import Network
import TickoalaCore

func smtpChecks() {
    suite("Sending invoices over SMTP") {
        test("the client logs in and uploads a message with an attachment") {
            let server = try MockSMTPServer()
            server.start()
            defer { server.stop() }

            let pdf = Data("PDFDATA".utf8)
            let message = EmailMessage(
                from: "me@example.com",
                to: ["client@example.com"],
                subject: "Invoice 0001",
                body: "Hello\r\n",
                attachment: ("invoice-0001.pdf", pdf)
            )
            let configuration = SMTPConfiguration(
                host: "127.0.0.1",
                port: Int(server.port),
                username: "me@example.com",
                password: "secret",
                from: "me@example.com",
                useTLS: false
            )
            try SMTPClient.send(message, configuration: configuration)

            expect(server.waitForData(timeout: 5), "the server received a message")
            expectEqual(server.username, "me@example.com")
            expectEqual(server.password, "secret")
            expect(server.commands.contains { $0.hasPrefix("EHLO") }, "the client greeted the server")
            expect(server.commands.contains("MAIL FROM:<me@example.com>"), "the envelope sender was sent")
            expect(server.commands.contains("RCPT TO:<client@example.com>"), "the envelope recipient was sent")
            expect(server.dataPayload.contains("Subject: Invoice 0001"), "the subject is in the message")
            expect(server.dataPayload.contains("Content-Type: application/pdf"), "the attachment is declared")
            expect(server.dataPayload.contains(pdf.base64EncodedString()), "the PDF is base64 in the message")
        }

        test("a rejected login surfaces as an error") {
            let server = try MockSMTPServer()
            server.rejectAuth = true
            server.start()
            defer { server.stop() }

            let message = EmailMessage(from: "me@example.com", to: ["client@example.com"], subject: "x", body: "y\r\n")
            let configuration = SMTPConfiguration(
                host: "127.0.0.1", port: Int(server.port),
                username: "me@example.com", password: "wrong",
                from: "me@example.com", useTLS: false
            )
            expectThrows({
                try SMTPClient.send(message, configuration: configuration)
            }, "a refused password must throw")
        }
    }
}

/// Minimal in-process SMTP server for the checks. Plain TCP, AUTH LOGIN only,
/// just enough to drive the client through a full conversation.
private final class MockSMTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mock-smtp")
    private var sessions: [Session] = []
    private let ready = DispatchSemaphore(value: 0)
    private let dataLock = NSLock()

    var rejectAuth = false
    private(set) var commands: [String] = []
    private(set) var username = ""
    private(set) var password = ""
    private(set) var dataPayload = ""

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let session = Session(connection: connection, server: self)
            self.sessions.append(session)
            session.start()
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() {
        listener.cancel()
        for session in sessions { session.cancel() }
    }

    /// Waits until the DATA payload has arrived.
    func waitForData(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dataLock.lock()
            let done = !dataPayload.isEmpty
            dataLock.unlock()
            if done { return true }
            usleep(10_000)
        }
        return false
    }

    fileprivate func record(_ command: String) {
        dataLock.lock(); commands.append(command); dataLock.unlock()
    }

    fileprivate func setCredentials(username: String, password: String) {
        dataLock.lock(); self.username = username; self.password = password; dataLock.unlock()
    }

    fileprivate func setData(_ payload: String) {
        dataLock.lock(); dataPayload = payload; dataLock.unlock()
    }

    private final class Session {
        private let connection: NWConnection
        private unowned let server: MockSMTPServer
        private var buffer = Data()
        private var dataMode = false
        private var dataLines: [String] = []
        private var authStage = 0

        init(connection: NWConnection, server: MockSMTPServer) {
            self.connection = connection
            self.server = server
        }

        func start() {
            connection.start(queue: server.queue)
            send("220 mock ESMTP ready\r\n")
            receive()
        }

        func cancel() { connection.cancel() }

        private func send(_ text: String) {
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.process()
                }
                if isComplete || error != nil { self.connection.cancel(); return }
                self.receive()
            }
        }

        private func process() {
            while let range = buffer.range(of: Data([0x0D, 0x0A])) {
                let line = String(decoding: buffer.subdata(in: buffer.startIndex..<range.lowerBound), as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                handle(line)
            }
        }

        private func handle(_ line: String) {
            if dataMode {
                if line == "." {
                    dataMode = false
                    server.setData(dataLines.joined(separator: "\n"))
                    send("250 OK message accepted\r\n")
                } else {
                    dataLines.append(line)
                }
                return
            }

            if authStage == 1 {
                server.setCredentials(username: decode(line), password: "")
                authStage = 2
                send("334 UGFzc3dvcmQ6\r\n")
                return
            }
            if authStage == 2 {
                server.setCredentials(username: server.username, password: decode(line))
                authStage = 0
                send(server.rejectAuth ? "535 authentication failed\r\n" : "235 2.7.0 authenticated\r\n")
                return
            }

            server.record(line)
            let upper = line.uppercased()
            if upper.hasPrefix("EHLO") {
                send("250-mock\r\n250 AUTH LOGIN\r\n")
            } else if upper.hasPrefix("AUTH LOGIN") {
                authStage = 1
                send("334 VXNlcm5hbWU6\r\n")
            } else if upper.hasPrefix("MAIL FROM") || upper.hasPrefix("RCPT TO") {
                send("250 OK\r\n")
            } else if upper == "DATA" {
                dataMode = true
                send("354 End data with <CR><LF>.<CR><LF>\r\n")
            } else if upper == "QUIT" {
                send("221 Bye\r\n")
                connection.cancel()
            } else {
                send("250 OK\r\n")
            }
        }

        private func decode(_ base64: String) -> String {
            guard let data = Data(base64Encoded: base64) else { return base64 }
            return String(decoding: data, as: UTF8.self)
        }
    }
}