import XCTest
@testable import WhereWasICore

final class RingBufferTests: XCTestCase {
    func testWriteAndReadBack() {
        let buf = RingBuffer(capacitySamples: 16)
        buf.write([1, 2, 3, 4, 5])
        XCTAssertEqual(buf.totalWritten, 5)
        XCTAssertEqual(buf.read(start: 0, end: 5), [1, 2, 3, 4, 5])
    }

    func testEmptyOrInvertedRangeReturnsEmpty() {
        let buf = RingBuffer(capacitySamples: 8)
        buf.write([1, 2, 3])
        XCTAssertEqual(buf.read(start: 2, end: 2), [])
        XCTAssertEqual(buf.read(start: 3, end: 1), [])
        XCTAssertEqual(buf.read(start: 10, end: 12), [])
    }

    func testReadIsClampedToAvailableSamples() {
        let buf = RingBuffer(capacitySamples: 8)
        buf.write([10, 11, 12])
        XCTAssertEqual(buf.read(start: -5, end: 100), [10, 11, 12])
    }

    func testWrapAroundDropsOldestSamples() {
        let buf = RingBuffer(capacitySamples: 8)
        buf.write([0, 1, 2, 3, 4, 5, 6, 7])
        buf.write([8, 9, 10])
        XCTAssertEqual(buf.totalWritten, 11)
        // Oldest retained index is 11 - 8 = 3
        XCTAssertEqual(buf.read(start: 0, end: 3), [])
        XCTAssertEqual(buf.read(start: 3, end: 11), [3, 4, 5, 6, 7, 8, 9, 10])
    }

    func testPartialReadAcrossTheWrapPoint() {
        let buf = RingBuffer(capacitySamples: 4)
        buf.write([1, 2, 3, 4, 5, 6]) // retained: 3,4,5,6 at abs 2...6
        XCTAssertEqual(buf.read(start: 3, end: 6), [4, 5, 6])
    }

    func testClearResetsPosition() {
        let buf = RingBuffer(capacitySamples: 8)
        buf.write([1, 2, 3, 4])
        buf.clear()
        XCTAssertEqual(buf.totalWritten, 0)
        XCTAssertEqual(buf.read(start: 0, end: 4), [])
        buf.write([9, 8])
        XCTAssertEqual(buf.read(start: 0, end: 2), [9, 8])
    }

    func testThirtySecondCapacityHoldsASlice() {
        let sr = 16_000
        let buf = RingBuffer(capacitySamples: sr * 30)
        let chunk = [Int16](repeating: 42, count: 1600)
        for _ in 0..<50 { buf.write(chunk) } // 80_000 samples = 5 s
        let slice = buf.read(start: 16_000, end: 16_000 + 1600)
        XCTAssertEqual(slice.count, 1600)
        XCTAssertTrue(slice.allSatisfy { $0 == 42 })
    }

    func testHoldsReportsWhetherRangeIsStillBuffered() {
        let rb = RingBuffer(capacitySamples: 10)
        rb.write([Int16](repeating: 1, count: 8))
        XCTAssertTrue(rb.holds(start: 0, end: 8))
        XCTAssertFalse(rb.holds(start: 0, end: 9), "end beyond what was written")
        rb.write([Int16](repeating: 2, count: 5)) // 13 written, oldest = 3
        XCTAssertEqual(rb.oldestAvailable, 3)
        XCTAssertFalse(rb.holds(start: 0, end: 8), "start has been overwritten")
        XCTAssertTrue(rb.holds(start: 3, end: 13))
        XCTAssertFalse(rb.holds(start: 5, end: 5), "empty range")
    }
}
