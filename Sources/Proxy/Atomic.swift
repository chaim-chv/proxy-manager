import Foundation
import Darwin

final class AtomicCounter {
    private let lock = NSLock()
    private var value: Int64 = 0
    func add(_ v: Int64) { lock.lock(); value += v; lock.unlock() }
    func get() -> Int64 { lock.lock(); defer { lock.unlock() }; return value }
}

final class AtomicInt {
    private let lock = NSLock()
    private var value: Int = 0
    func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    func inc() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func dec() -> Int { lock.lock(); defer { lock.unlock() }; value -= 1; return value }
}
