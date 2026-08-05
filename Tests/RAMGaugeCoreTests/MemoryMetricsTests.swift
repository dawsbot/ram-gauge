import XCTest
@testable import RAMGaugeCore

final class MemoryMetricsTests: XCTestCase {
    func testUsageRatioUsesUsedBytesOverTotalBytes() {
        let snapshot = MemorySnapshot(totalBytes: 16_000, usedBytes: 12_000, pressure: .normal)
        XCTAssertEqual(snapshot.usageRatio, 0.75, accuracy: 0.0001)
        XCTAssertEqual(snapshot.usagePercent, 75)
    }

    func testDangerLevelUsesMemoryPressureBeforeRawUsage() {
        let highUsageButNormalPressure = MemorySnapshot(totalBytes: 16_000, usedBytes: 12_000, pressure: .normal)
        let warningPressure = MemorySnapshot(totalBytes: 16_000, usedBytes: 8_000, pressure: .warning)
        let criticalPressure = MemorySnapshot(totalBytes: 16_000, usedBytes: 5_000, pressure: .critical)

        XCTAssertEqual(highUsageButNormalPressure.dangerLevel, .yellow)
        XCTAssertEqual(warningPressure.dangerLevel, .yellow)
        XCTAssertEqual(criticalPressure.dangerLevel, .red)
    }

    func testUsageNeverExceedsOneHundredPercent() {
        let snapshot = MemorySnapshot(totalBytes: 16_000, usedBytes: 20_000, pressure: .normal)
        XCTAssertEqual(snapshot.usageRatio, 1)
        XCTAssertEqual(snapshot.usagePercent, 100)
    }
}
