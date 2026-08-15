import Foundation

/// A very small test harness.
///
/// This machine has the Swift command-line tools but not Xcode, and
/// XCTest.framework ships only with Xcode — so `swift test` cannot run here at
/// all.  Rather than leave the project untested, the suite is an ordinary
/// executable target with the twenty lines of scaffolding it actually needs.
///
///     swift run atlastests            # everything
///     swift run atlastests game       # only suites matching "game"
///
/// If Xcode ever lands on the machine, these files move to a real test target
/// almost unchanged: the assertions are deliberately named after XCTest's.
enum Harness {
    static var currentSuite = ""
    static var currentTest = ""
    static var failures: [String] = []
    static var testsRun = 0
    static var assertions = 0
    private static var failuresInTest = 0

    static var filter: String?

    static func suite(_ name: String, _ body: () -> Void) {
        if let filter, !name.lowercased().contains(filter) { return }
        currentSuite = name
        print("\n\u{1B}[1m\(name)\u{1B}[0m")
        body()
    }

    static func test(_ name: String, _ body: () throws -> Void) {
        currentTest = name
        failuresInTest = 0
        testsRun += 1
        let started = Date()
        do {
            try body()
        } catch {
            record("threw \(error)", file: #filePath, line: #line)
        }
        let elapsed = Date().timeIntervalSince(started)
        let timing = elapsed > 0.5 ? String(format: "  (%.1fs)", elapsed) : ""
        if failuresInTest == 0 {
            print("  \u{1B}[32m✓\u{1B}[0m \(name)\(timing)")
        } else {
            print("  \u{1B}[31m✗\u{1B}[0m \(name)\(timing)")
        }
    }

    static func record(_ message: String, file: StaticString, line: UInt) {
        failuresInTest += 1
        let where_ = "\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line)"
        failures.append("\(currentSuite) › \(currentTest)\n      \(message)\n      at \(where_)")
        print("      \u{1B}[31m\(message)\u{1B}[0m  (\(where_))")
    }

    static func report() -> Int32 {
        print("\n\(testsRun) tests, \(assertions) assertions")
        guard !failures.isEmpty else {
            print("\u{1B}[32mall good\u{1B}[0m")
            return 0
        }
        print("\u{1B}[31m\(failures.count) failures\u{1B}[0m")
        for failure in failures { print("  · \(failure)") }
        return 1
    }
}

// MARK: - Assertions

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "",
            file: StaticString = #filePath, line: UInt = #line) {
    Harness.assertions += 1
    if !condition() {
        Harness.record(message().isEmpty ? "expectation failed" : message(),
                       file: file, line: line)
    }
}

func expectEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: @autoclosure () -> T,
                               _ message: @autoclosure () -> String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
    Harness.assertions += 1
    let a = actual(), e = expected()
    if a != e {
        let note = message().isEmpty ? "" : " — \(message())"
        Harness.record("expected \(e), got \(a)\(note)", file: file, line: line)
    }
}

func expectNotEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ other: @autoclosure () -> T,
                                  _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
    Harness.assertions += 1
    if actual() == other() {
        let note = message().isEmpty ? "" : " — \(message())"
        Harness.record("expected something other than \(other())\(note)", file: file, line: line)
    }
}

func expectClose(_ actual: @autoclosure () -> Double, _ expected: @autoclosure () -> Double,
                 accuracy: Double = 0.001, _ message: @autoclosure () -> String = "",
                 file: StaticString = #filePath, line: UInt = #line) {
    Harness.assertions += 1
    let a = actual(), e = expected()
    if abs(a - e) > accuracy {
        let note = message().isEmpty ? "" : " — \(message())"
        Harness.record("expected \(e) ± \(accuracy), got \(a)\(note)", file: file, line: line)
    }
}

func expectGreater<T: Comparable>(_ actual: @autoclosure () -> T, _ floor: @autoclosure () -> T,
                                  _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
    Harness.assertions += 1
    let a = actual(), f = floor()
    if !(a > f) {
        let note = message().isEmpty ? "" : " — \(message())"
        Harness.record("expected \(a) > \(f)\(note)", file: file, line: line)
    }
}

func expectAtLeast<T: Comparable>(_ actual: @autoclosure () -> T, _ floor: @autoclosure () -> T,
                                  _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
    Harness.assertions += 1
    let a = actual(), f = floor()
    if !(a >= f) {
        let note = message().isEmpty ? "" : " — \(message())"
        Harness.record("expected \(a) >= \(f)\(note)", file: file, line: line)
    }
}

func expectLess<T: Comparable>(_ actual: @autoclosure () -> T, _ ceiling: @autoclosure () -> T,
                               _ message: @autoclosure () -> String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
    Harness.assertions += 1
    let a = actual(), c = ceiling()
    if !(a < c) {
        let note = message().isEmpty ? "" : " — \(message())"
        Harness.record("expected \(a) < \(c)\(note)", file: file, line: line)
    }
}

func expectNil<T>(_ value: @autoclosure () -> T?, _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath, line: UInt = #line) {
    Harness.assertions += 1
    if let found = value() {
        let note = message().isEmpty ? "" : " — \(message())"
        Harness.record("expected nil, got \(found)\(note)", file: file, line: line)
    }
}

func expectNotNil<T>(_ value: @autoclosure () -> T?, _ message: @autoclosure () -> String = "",
                     file: StaticString = #filePath, line: UInt = #line) {
    Harness.assertions += 1
    if value() == nil {
        Harness.record(message().isEmpty ? "expected a value, got nil" : message(),
                       file: file, line: line)
    }
}

func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    Harness.assertions += 1
    Harness.record(message, file: file, line: line)
}
