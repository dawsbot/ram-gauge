import Foundation

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

    public init(totalBytes: UInt64, usedBytes: UInt64, pressure: MemoryPressure) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.pressure = pressure
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
