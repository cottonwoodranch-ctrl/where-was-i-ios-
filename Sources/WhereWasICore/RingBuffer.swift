import Foundation

/// Fixed-size rolling PCM buffer addressed by absolute sample index. In memory only.
/// Direct port of the Android `RingBuffer`.
public final class RingBuffer: @unchecked Sendable {
    private var buf: [Int16]
    private var written: Int64 = 0
    private let lock = NSLock()

    public init(capacitySamples: Int) {
        precondition(capacitySamples > 0, "RingBuffer capacity must be positive")
        buf = [Int16](repeating: 0, count: capacitySamples)
    }

    public var capacity: Int { buf.count }

    public func write(_ data: [Int16], length: Int? = nil) {
        let len = min(length ?? data.count, data.count)
        guard len > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let cap = Int64(buf.count)
        for i in 0..<len {
            buf[Int(written % cap)] = data[i]
            written += 1
        }
    }

    public var totalWritten: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    /// Absolute index of the oldest sample still held.
    public var oldestAvailable: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return max(Int64(0), written - Int64(buf.count))
    }

    /// True when every sample in `[start, end)` is still in the buffer.
    public func holds(start: Int64, end: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let oldest = max(Int64(0), written - Int64(buf.count))
        return start >= oldest && end <= written && end > start
    }

    /// Copy samples `[start, end)` clamped to what is still held in the buffer.
    public func read(start: Int64, end: Int64) -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        let cap = Int64(buf.count)
        let oldest = max(Int64(0), written - cap)
        let s = max(start, oldest)
        let e = min(end, written)
        if e <= s { return [] }
        var out = [Int16](repeating: 0, count: Int(e - s))
        var i = s
        while i < e {
            out[Int(i - s)] = buf[Int(i % cap)]
            i += 1
        }
        return out
    }

    public func clear() {
        lock.lock()
        written = 0
        lock.unlock()
    }
}
