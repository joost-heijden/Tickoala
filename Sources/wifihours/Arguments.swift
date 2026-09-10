import Foundation
import WifiHoursCore

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case failure(String)

    var description: String {
        switch self {
        case .usage(let message): return message
        case .failure(let message): return message
        }
    }
}

/// Minimale argumentparser: positionele woorden plus `--sleutel waarde`, `--sleutel=waarde` en `--vlag`.
struct Arguments {
    private(set) var positional: [String] = []
    private var options: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            index += 1
            guard token.hasPrefix("--"), token.count > 2 else {
                positional.append(token)
                continue
            }
            let body = String(token.dropFirst(2))
            if let separator = body.firstIndex(of: "=") {
                options[String(body[body.startIndex..<separator])] = String(body[body.index(after: separator)...])
            } else if index < raw.count, !raw[index].hasPrefix("--") {
                options[body] = raw[index]
                index += 1
            } else {
                flags.insert(body)
            }
        }
    }

    func string(_ name: String) -> String? { options[name] }

    func flag(_ name: String) -> Bool { flags.contains(name) || options[name] == "true" }

    func int(_ name: String) -> Int? { options[name].flatMap { Int($0) } }

    func require(_ name: String) throws -> String {
        guard let value = options[name], !value.isEmpty else {
            throw CLIError.usage("ontbrekende optie --\(name)")
        }
        return value
    }

    func requireDate(_ name: String) throws -> Date {
        try parse(name, try require(name))
    }

    func date(_ name: String, default fallback: Date?) throws -> Date? {
        guard let raw = options[name] else { return fallback }
        return try parse(name, raw)
    }

    func word(_ index: Int) -> String? {
        index < positional.count ? positional[index] : nil
    }

    private func parse(_ name: String, _ raw: String) throws -> Date {
        guard let date = Formatting.parseDate(raw) else {
            throw CLIError.usage("kan tijd niet lezen bij --\(name): '\(raw)' (gebruik bijvoorbeeld '2026-09-10 09:15')")
        }
        return date
    }
}
