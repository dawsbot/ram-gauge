import AppKit
import Combine
import Darwin
import RAMGaugeCore
import ServiceManagement
import SwiftUI
import UserNotifications

struct ProcessMemoryInfo: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let bytes: UInt64
    var id: pid_t { pid }
}

@MainActor
final class MemoryMonitor: ObservableObject {
    @Published private(set) var snapshot: MemorySnapshot
    @Published private(set) var topProcesses: [ProcessMemoryInfo] = []
    /// Usage ratios sampled every refresh; last 10 minutes at 5s cadence.
    @Published private(set) var history: [Double] = []
    private static let historyLimit = 120

    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var pressure: MemoryPressure = .normal

    init() {
        snapshot = MemoryMonitor.readSnapshot()
        start()
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            let previous = self.pressure
            if event.contains(.critical) {
                self.pressure = .critical
            } else if event.contains(.warning) {
                self.pressure = .warning
            } else if event.contains(.normal) {
                self.pressure = .normal
            }
            self.refresh()
            if self.pressure != previous, self.pressure != .normal {
                Notifier.postPressureAlert(level: self.pressure, top: self.topProcesses.first)
            }
        }
        source.resume()
        pressureSource = source
    }

    func refresh() {
        snapshot = Self.readSnapshot(pressure: pressure)
        topProcesses = Self.readTopProcesses()
        history.append(snapshot.usageRatio)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    func kill(_ process: ProcessMemoryInfo) {
        Darwin.kill(process.pid, SIGKILL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refresh()
        }
    }

    private static func readTopProcesses(limit: Int = 5) -> [ProcessMemoryInfo] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytesReturned = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard bytesReturned > 0 else { return [] }
        let count = Int(bytesReturned)

        var results: [ProcessMemoryInfo] = []
        for pid in pids.prefix(count) where pid > 0 {
            var usage = rusage_info_current()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            // Fails for other users' processes; skip those.
            guard status == 0, usage.ri_phys_footprint > 0 else { continue }

            var nameBuffer = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let rawName = String(decoding: nameBuffer.prefix(while: { $0 != 0 }), as: UTF8.self)
            guard !rawName.isEmpty else { continue }

            results.append(ProcessMemoryInfo(pid: pid, name: friendlyName(pid: pid, fallback: rawName), bytes: usage.ri_phys_footprint))
        }
        return Array(results.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    private static func friendlyName(pid: pid_t, fallback: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return name
        }

        var pathBuffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var executable = fallback
        var path = ""
        if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
            path = String(decoding: pathBuffer.prefix(while: { $0 != 0 }), as: UTF8.self)
            executable = URL(fileURLWithPath: path).lastPathComponent
        }

        // Script runtimes: name them by the tool they run and the project directory.
        let runtimes: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby"]
        if runtimes.contains(executable) || fallback.hasPrefix("next-server") {
            let args = processArguments(pid: pid)
            let project = processWorkingDirectory(pid: pid).map { URL(fileURLWithPath: $0).lastPathComponent }
            let tool: String
            if fallback.hasPrefix("next-server") || args.contains(where: { $0 == "next" || $0.hasSuffix("/next") || $0.contains("next/dist") }) {
                tool = "Next.js"
            } else if args.contains(where: { $0 == "vite" || $0.hasSuffix("/vite") }) {
                tool = "Vite"
            } else {
                tool = executable
            }
            if let project, !project.isEmpty {
                return "\(tool) · \(project)"
            }
            return tool
        }

        // Helpers living inside an .app bundle: use the bundle's name.
        if let range = path.range(of: ".app/") {
            return URL(fileURLWithPath: String(path[..<range.lowerBound])).lastPathComponent
        }

        // Reverse-DNS daemon names: keep the last component, space out camel case.
        if executable.contains(".") {
            let last = executable.split(separator: ".").last.map(String.init) ?? executable
            var spaced = ""
            for character in last {
                if character.isUppercase, let previous = spaced.last, previous.isLowercase {
                    spaced.append(" ")
                }
                spaced.append(character)
            }
            return spaced
        }

        return executable
    }

    private static func processArguments(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }

        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var offset = MemoryLayout<Int32>.size
        while offset < size, buffer[offset] != 0 { offset += 1 }  // skip exec path
        while offset < size, buffer[offset] == 0 { offset += 1 }  // skip padding

        var args: [String] = []
        var current: [UInt8] = []
        while offset < size, args.count < argc {
            if buffer[offset] == 0 {
                args.append(String(decoding: current, as: UTF8.self))
                current = []
            } else {
                current.append(buffer[offset])
            }
            offset += 1
        }
        return args
    }

    private static func processWorkingDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            let bytes = raw.prefix(while: { $0 != 0 })
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func readSnapshot(pressure: MemoryPressure = .normal) -> MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let total = ProcessInfo.processInfo.physicalMemory
        let swapUsed = readSwapUsed()
        guard result == KERN_SUCCESS else {
            return MemorySnapshot(totalBytes: total, usedBytes: 0, pressure: .normal, swapUsedBytes: swapUsed)
        }

        let pageSize = UInt64(getpagesize())
        // Match Activity Monitor's "Memory Used": app memory (internal minus
        // purgeable) + wired + compressed. Excludes reclaimable file cache,
        // which macOS intentionally keeps large.
        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let usedPages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return MemorySnapshot(totalBytes: total, usedBytes: usedPages * pageSize, pressure: pressure, swapUsedBytes: swapUsed)
    }

    private static func readSwapUsed() -> UInt64 {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return 0 }
        return swap.xsu_used
    }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func postPressureAlert(level: MemoryPressure, top: ProcessMemoryInfo?) {
        let content = UNMutableNotificationContent()
        content.title = level == .critical ? "Memory pressure critical" : "Memory pressure elevated"
        if let top {
            let size = ByteCountFormatter.string(fromByteCount: Int64(top.bytes), countStyle: .memory)
            content.body = "Biggest consumer: \(top.name) at \(size). Click the gauge to review or kill processes."
        } else {
            content.body = "Click the gauge in the menu bar to review memory use."
        }
        content.sound = level == .critical ? .default : nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

struct Sparkline: View {
    let values: [Double]  // 0...1, oldest first, fixed 0-100% scale
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let step = values.count > 1 ? width / CGFloat(values.count - 1) : width
            let points = values.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) * step, y: height * (1 - CGFloat(value)))
            }
            if let first = points.first, let last = points.last {
                Path { path in
                    path.move(to: CGPoint(x: first.x, y: height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: last.x, y: height))
                    path.closeSubpath()
                }
                .fill(color.opacity(0.12))
                Path { path in
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    /// Set only when a release newer than the running version exists.
    @Published private(set) var availableVersion: String?

    static let releasesPage = URL(string: "https://github.com/dawsbot/ram-gauge/releases/latest")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/dawsbot/ram-gauge/releases/latest")!

    private var timer: Timer?

    init() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func check() {
        var request = URLRequest(url: Self.latestAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let newer = AppVersion.isNewer(tag, than: current)
            await MainActor.run {
                self?.availableVersion = newer ? (tag.hasPrefix("v") ? String(tag.dropFirst()) : tag) : nil
            }
        }
    }
}

struct MemoryMenuView: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var updater: UpdateChecker
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

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
            if monitor.history.count >= 2 {
                VStack(alignment: .leading, spacing: 2) {
                    Sparkline(values: monitor.history, color: color)
                        .frame(height: 28)
                    Text("Last 10 minutes")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text("\(ByteCountFormatter.string(fromByteCount: Int64(monitor.snapshot.usedBytes), countStyle: .memory)) of \(ByteCountFormatter.string(fromByteCount: Int64(monitor.snapshot.totalBytes), countStyle: .memory))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if monitor.snapshot.swapUsedBytes > 0 {
                Text("Swap used: \(ByteCountFormatter.string(fromByteCount: Int64(monitor.snapshot.swapUsedBytes), countStyle: .memory))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(color)
            if !monitor.topProcesses.isEmpty {
                Divider()
                Text("Top memory consumers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(monitor.topProcesses) { process in
                    HStack(spacing: 8) {
                        Text(process.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(process.bytes), countStyle: .memory))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button {
                            monitor.kill(process)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Force quit \(process.name) (PID \(process.pid))")
                    }
                }
            }
            if let version = updater.availableVersion {
                Divider()
                Button {
                    NSWorkspace.shared.open(UpdateChecker.releasesPage)
                } label: {
                    Label("Update available: v\(version)", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
            Divider()
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Button("Refresh now") { monitor.refresh() }
            Button("Quit RAM Gauge") { NSApplication.shared.terminate(nil) }
        }
        .padding(16)
        .frame(width: 300)
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
    @StateObject private var updater = UpdateChecker()

    init() {
        Notifier.requestPermission()
    }

    var body: some Scene {
        MenuBarExtra {
            MemoryMenuView(monitor: monitor, updater: updater)
        } label: {
            Text("💻 \(monitor.snapshot.usagePercent)%")
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
