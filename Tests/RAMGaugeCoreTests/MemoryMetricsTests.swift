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

final class AppVersionTests: XCTestCase {
    func testNewerVersionsDetected() {
        XCTAssertTrue(AppVersion.isNewer("v1.2.0", than: "1.1.0"))
        XCTAssertTrue(AppVersion.isNewer("2.0.0", than: "1.9.9"))
        XCTAssertTrue(AppVersion.isNewer("1.1.1", than: "1.1"))
    }

    func testSameOrOlderVersionsIgnored() {
        XCTAssertFalse(AppVersion.isNewer("v1.1.0", than: "1.1.0"))
        XCTAssertFalse(AppVersion.isNewer("1.0.9", than: "1.1.0"))
        XCTAssertFalse(AppVersion.isNewer("1.1", than: "1.1.0"))
    }
}
