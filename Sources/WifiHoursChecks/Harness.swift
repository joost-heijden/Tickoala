import Foundation

/// Piepklein testraamwerk. Bewust zonder XCTest, zodat de suite ook draait met
/// alleen de Command Line Tools geïnstalleerd.
enum Harness {
    static var currentSuite = ""
    static var currentTest = ""
    static var failures: [String] = []
    static var assertions = 0
    static var testCount = 0
    static var testFailed = false

    static func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        print("\n\(name)")
        do {
            try body()
        } catch {
            record("suite brak af met een fout: \(error)")
        }
    }

    static func test(_ name: String, _ body: () throws -> Void) {
        currentTest = name
        testFailed = false
        testCount += 1
        do {
            try body()
        } catch {
            record("wierp een fout: \(error)")
        }
        print("  \(testFailed ? "x" : "+") \(name)")
    }

    static func record(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        testFailed = true
        let name = "\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line)"
        failures.append("\(currentSuite) › \(currentTest)\n      \(message)\n      (\(name))")
    }

    static func summary() -> Int32 {
        print("\n\(testCount) tests, \(assertions) controles, \(failures.count) fout(en)")
        for failure in failures {
            print("\n  FOUT: \(failure)")
        }
        return failures.isEmpty ? 0 : 1
    }
}

func suite(_ name: String, _ body: () throws -> Void) { Harness.suite(name, body) }
func test(_ name: String, _ body: () throws -> Void) { Harness.test(name, body) }

func expect(
    _ condition: @autoclosure () throws -> Bool,
    _ description: @autoclosure () -> String = "verwachting niet waar",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    Harness.assertions += 1
    do {
        if try !condition() {
            Harness.record(description(), file: file, line: line)
        }
    } catch {
        Harness.record("\(description()) — wierp \(error)", file: file, line: line)
    }
}

func expectEqual<T: Equatable>(
    _ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T,
    _ description: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    Harness.assertions += 1
    do {
        let left = try actual()
        let right = try expected()
        if left != right {
            let prefix = description().isEmpty ? "" : "\(description()): "
            Harness.record("\(prefix)verwacht \(right), kreeg \(left)", file: file, line: line)
        }
    } catch {
        Harness.record("wierp \(error)", file: file, line: line)
    }
}

struct MissingValue: Error, CustomStringConvertible {
    let description: String
}

func expectNotNil<T>(
    _ value: @autoclosure () throws -> T?,
    _ description: @autoclosure () -> String = "waarde ontbreekt",
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    Harness.assertions += 1
    guard let unwrapped = try value() else {
        Harness.record(description(), file: file, line: line)
        throw MissingValue(description: description())
    }
    return unwrapped
}

func expectThrows(
    _ body: () throws -> Void,
    _ description: @autoclosure () -> String = "verwachtte een fout",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    Harness.assertions += 1
    do {
        try body()
        Harness.record(description(), file: file, line: line)
    } catch {
        // Zo hoort het.
    }
}
