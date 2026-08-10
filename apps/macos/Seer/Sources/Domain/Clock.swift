import Foundation

/// Abstraction over "now", expressed as Unix milliseconds (`Int64`), matching
/// every timestamp field in `Models.swift`. Production code depends on
/// `Clock` rather than calling `Date()` directly so services can be tested
/// deterministically.
public protocol Clock: Sendable {
    /// The current time as Unix milliseconds since epoch.
    func nowMilliseconds() -> Int64
}

/// The production `Clock`, backed by the system wall clock.
public struct SystemClock: Clock {
    public init() {}

    public func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
