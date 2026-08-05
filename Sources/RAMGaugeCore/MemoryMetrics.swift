import Foundation

public enum AppVersion {
    /// Compares dotted numeric versions like "1.2.0"; ignores a leading "v".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func components(_ version: String) -> [Int] {
            let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
            return trimmed.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = components(candidate)
        let b = components(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

public enum MemoryPressure: Equatable, Sendable {
    case normal
    case warning
    case critical
}

public enum DangerLevel: Equatable, Sendable {
    case green
    case yellow
    case red
}

public struct MemorySnapshot: Equatable, Sendable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let pressure: MemoryPressure
    public let swapUsedBytes: UInt64

    public init(totalBytes: UInt64, usedBytes: UInt64, pressure: MemoryPressure, swapUsedBytes: UInt64 = 0) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.pressure = pressure
        self.swapUsedBytes = swapUsedBytes
    }

    public var usageRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }

    public var usagePercent: Int {
        Int((usageRatio * 100).rounded())
    }

    public var dangerLevel: DangerLevel {
        switch pressure {
        case .critical:
            return .red
        case .warning:
            return .yellow
        case .normal:
            if usageRatio >= 0.86 { return .red }
            if usageRatio >= 0.70 { return .yellow }
            return .green
        }
    }
}
