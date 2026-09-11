import Foundation
import Network

public enum SMTPError: Error, CustomStringConvertible {
    case configuration(String)
    case connection(String)
    case timedOut
    case rejected(String)
    case server(String)

    public var description: String {
        switch self {
        case .configuration(let m): return m
        case .connection(let m): return "could not reach the mail server: \(m)"
        case .timedOut: return "the mail server did not respond in time"
        case .rejected(let m): return "the mail server refused: \(m)"
        case .server(let m): return "unexpected reply from the mail server: \(m)"
        }
    }
}

/// Everything needed to talk to one SMTP server. The password is passed in from
/// the Keychain by the caller; it is never stored here.
public struct SMTPConfiguration: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var from: String
    /// Implicit TLS (SMTPS, normally port 465). STARTTLS is not supported.
    public var useTLS: Bool

    public init(host: String, port: Int, username: String, password: String, from: String, useTLS: Bool = true) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.from = from
        self.useTLS = useTLS
    }
}

public struct EmailMessage: Sendable {
    public var from: String
    public var to: [String]
    public var subject: String
    public var body: String
    public var attachment: (name: String, data: Data)?

    public init(from: String, to: [String], subject: String, body: String, attachment: (name: String, data: Data)? = nil) {
        self.from = from
        self.to = to
        self.subject = subject
        self.body = body
        self.attachment = attachment
    }

    /// RFC 5322 message with a optional PDF attachment, ready for DATA.
    func mimeString() -> String {
        var headers = [
            "From: \(from)",
            "To: \(to.joined(separator: ", "))",
            "Subject: \(Self.encodedSubject(subject))",
            "Date: \(Self.rfc2822Date(Date()))",
            "Message-ID: <\(UUID().uuidString)@tickoala.local>",
            "MIME-Version: 1.0",
        ]
        let boundary = "tickoala-\(UUID().uuidString)"
        headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        var message = headers.joined(separator: "\r\n") + "\r\n\r\n"

        message += "--\(boundary)\r\n"
        message += "Content-Type: text/plain; charset=utf-8\r\n"
        message += "Content-Transfer-Encoding: 8bit\r\n\r\n"
        message += body + "\r\n"

        if let attachment {
            let base64 = attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            message += "--\(boundary)\r\n"
            message += "Content-Type: application/pdf; name=\"\(attachment.name)\"\r\n"
            message += "Content-Transfer-Encoding: base64\r\n"
            message += "Content-Disposition: attachment; filename=\"\(attachment.name)\"\r\n\r\n"
            message += base64 + "\r\n"
        }

        message += "--\(boundary)--\r\n"
        return message
    }

    private static func encodedSubject(_ subject: String) -> String {
        guard !subject.canBeConverted(to: .ascii) else { return subject }
        return "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
    }

    private static func rfc2822Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}

/// A small synchronous SMTP client, enough for sending an invoice.
///
/// ponytail: AUTH LOGIN and implicit TLS only; add PLAIN/OAuth and STARTTLS when
/// a server that needs them shows up.
public enum SMTPClient {
    public static func send(_ message: EmailMessage, configuration: SMTPConfiguration) throws {
        guard !configuration.host.isEmpty, !configuration.from.isEmpty else {
            throw SMTPError.configuration("the mail server host and sender address are required")
        }
        guard !message.to.isEmpty else {
            throw SMTPError.configuration("no recipient address")
        }
        let connection = try SMTPConnection(configuration: configuration)
        try connection.run(message: message)
    }
}

private final class SMTPConnection {
    private let configuration: SMTPConfiguration
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "local.tickoala.smtp")
    private let lock = NSLock()
    private var buffer = Data()
    private var failure: Error?
    private let ready = DispatchSemaphore(value: 0)
    private let dataArrived = DispatchSemaphore(value: 0)

    init(configuration: SMTPConfiguration) throws {
        self.configuration = configuration
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: configuration.port)) else {
            throw SMTPError.configuration("the port is not a number")
        }
        let host = NWEndpoint.Host(configuration.host)
        if configuration.useTLS {
            connection = NWConnection(host: host, port: port, using: NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options()))
        } else {
            connection = NWConnection(host: host, port: port, using: .tcp)
        }
    }

    func run(message: EmailMessage) throws {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready.signal()
            case .failed(let error), .waiting(let error):
                self.fail(error)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop()

        if ready.wait(timeout: .now() + 20) == .timedOut {
            connection.cancel()
            throw SMTPError.timedOut
        }
        if let failure { connection.cancel(); throw failure }

        _ = try response(expect: 220)
        _ = try command("EHLO \(Self.localHostname())", expecting: 250)
        try authenticate()
        _ = try command("MAIL FROM:<\(configuration.from)>", expecting: 250)
        for recipient in message.to {
            _ = try command("RCPT TO:<\(recipient)>", expecting: 250)
        }
        _ = try command("DATA", expecting: 354)
        try write(dataPayload(message))
        _ = try response(expect: 250)
        _ = try? command("QUIT", expecting: 221)
        connection.cancel()
    }

    // MARK: - SMTP dialogue

    private func authenticate() throws {
        guard !configuration.username.isEmpty else { return }
        _ = try command("AUTH LOGIN", expecting: 334)
        _ = try command(Data(configuration.username.utf8).base64EncodedString(), expecting: 334)
        _ = try command(Data(configuration.password.utf8).base64EncodedString(), expecting: 235)
    }

    private func dataPayload(_ message: EmailMessage) -> String {
        // Dot-stuffing, as required between DATA and the terminating dot.
        let stuffed = message.mimeString()
            .split(separator: "\r\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(".") ? "." + $0 : String($0) }
            .joined(separator: "\r\n")
        return stuffed + "\r\n.\r\n"
    }

    @discardableResult
    private func command(_ text: String, expecting: Int) throws -> String {
        try write(text + "\r\n")
        return try response(expect: expecting)
    }

    /// Reads a reply, following `250-` continuation lines to the final `250 `.
    private func response(expect: Int) throws -> String {
        var lines: [String] = []
        while true {
            let line = try readLine()
            lines.append(line)
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw SMTPError.server("unreadable reply: \(line)")
            }
            let continued = line.count >= 4 && line[line.index(line.startIndex, offsetBy: 3)] == "-"
            if !continued {
                guard code == expect else { throw SMTPError.rejected("\(code): \(lines.joined(separator: " | "))") }
                return lines.joined(separator: "\n")
            }
        }
    }

    private func write(_ text: String) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var error: Error?
        connection.send(content: Data(text.utf8), completion: .contentProcessed { sendError in
            error = sendError
            semaphore.signal()
        })
        semaphore.wait()
        if let error { throw SMTPError.connection("\(error)") }
    }

    private func readLine() throws -> String {
        while true {
            lock.lock()
            if let range = buffer.range(of: Data([0x0D, 0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                lock.unlock()
                return String(decoding: line, as: UTF8.self)
            }
            let currentFailure = failure
            lock.unlock()
            if let currentFailure { throw currentFailure }
            if dataArrived.wait(timeout: .now() + 30) == .timedOut { throw SMTPError.timedOut }
        }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.buffer.append(data)
                self.lock.unlock()
                self.dataArrived.signal()
            }
            if let error {
                self.fail(error)
                return
            }
            if isComplete {
                self.fail(SMTPError.connection("the server closed the connection"))
                return
            }
            self.receiveLoop()
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
        ready.signal()
        dataArrived.signal()
    }

    private static func localHostname() -> String {
        let name = ProcessInfo.processInfo.hostName
        return name.isEmpty ? "localhost" : name
    }
}