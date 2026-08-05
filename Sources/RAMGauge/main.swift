import AppKit
import Combine
import Darwin
import RAMGaugeCore
import SwiftUI

@MainActor
final class MemoryMonitor: ObservableObject {
    @Published private(set) var snapshot: MemorySnapshot

    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?

    init() {
        snapshot = MemoryMonitor.readSnapshot()
        start()
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.refresh(pressureEvent: source.data)
        }
        source.resume()
        pressureSource = source
    }

    func refresh(pressureEvent: DispatchSource.MemoryPressureEvent = []) {
        snapshot = Self.readSnapshot(pressureEvent: pressureEvent)
    }

    private static func readSnapshot(pressureEvent: DispatchSource.MemoryPressureEvent = []) -> MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else {
            return MemorySnapshot(totalBytes: total, usedBytes: 0, pressure: .normal)
        }

        let pageSize = UInt64(getpagesize())
        let usedPages = UInt64(stats.active_count) + UInt64(stats.inactive_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let pressure: MemoryPressure
        if pressureEvent.contains(.critical) {
            pressure = .critical
        } else if pressureEvent.contains(.warning) {
            pressure = .warning
        } else {
            pressure = .normal
        }
        return MemorySnapshot(totalBytes: total, usedBytes: usedPages * pageSize, pressure: pressure)
    }
}

struct MemoryMenuView: View {
    @ObservedObject var monitor: MemoryMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RAM Gauge")
                .font(.headline)
            HStack(alignment: .firstTextBaseline) {
                Text("\(monitor.snapshot.usagePercent)%")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text("used")
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: monitor.snapshot.usageRatio)
                .tint(color)
            Text("\(ByteCountFormatter.string(fromByteCount: Int64(monitor.snapshot.usedBytes), countStyle: .memory)) of \(ByteCountFormatter.string(fromByteCount: Int64(monitor.snapshot.totalBytes), countStyle: .memory))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(color)
            Divider()
            Button("Refresh now") { monitor.refresh() }
            Button("Quit RAM Gauge") { NSApplication.shared.terminate(nil) }
        }
        .padding(16)
        .frame(width: 260)
    }

    private var color: Color {
        switch monitor.snapshot.dangerLevel {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }

    private var statusText: String {
        switch monitor.snapshot.dangerLevel {
        case .green: "Memory pressure normal"
        case .yellow: "Memory use is elevated"
        case .red: "Memory use is high"
        }
    }
}

@main
struct RAMGaugeApp: App {
    @StateObject private var monitor = MemoryMonitor()

    var body: some Scene {
        MenuBarExtra {
            MemoryMenuView(monitor: monitor)
        } label: {
            Text("\(monitor.snapshot.usagePercent)%")
                .foregroundStyle(menuBarColor)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarColor: Color {
        switch monitor.snapshot.dangerLevel {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }
}
