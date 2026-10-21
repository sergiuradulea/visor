import AppKit
import IOKit.ps
import Security
import SwiftUI

/// Laptop battery, CPU, memory and Bluetooth device batteries. Nothing here polls on its own:
/// the Home tab calls `refresh()` on a timer only while it is on screen.
final class SystemStats: ObservableObject {
    static let shared = SystemStats()

    struct Battery: Equatable { var percent: Int; var charging: Bool; var pluggedIn: Bool; var minutesLeft: Int? }
    struct Device: Identifiable, Equatable {
        var name: String
        var levels: [Level] // AirPods: Left/Right/Case; keyboards and mice: one unnamed level
        var id: String { name }
    }
    struct Level: Equatable { var part: String; var percent: Int }

    @Published var battery: Battery?
    @Published var cpu = 0.0 // 0...1
    @Published var memoryUsed = 0.0
    let memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published var devices: [Device] = []

    private let host = mach_host_self()
    private var lastTicks: [UInt32]?
    private var lastDeviceScan = Date.distantPast

    /// Forget the last CPU sample, so reopening Home doesn't show the average since it was closed.
    func pauseCPU() { lastTicks = nil }

    func refresh() {
        let firstSample = lastTicks == nil
        battery = Self.readBattery()
        cpu = readCPU()
        memoryUsed = readMemoryUsed()
        // system_profiler takes a second or two; batteries change slowly.
        if Date().timeIntervalSince(lastDeviceScan) > 60 { lastDeviceScan = Date(); scanDevices() }
        // One sample has nothing to compare against; take a second one shortly after.
        if firstSample { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.cpu = self?.readCPU() ?? 0 } }
    }

    static func readBattery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let minutes = d[kIOPSTimeToEmptyKey] as? Int ?? -1
            return Battery(percent: current * 100 / max, charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                           pluggedIn: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                           minutesLeft: minutes > 0 ? minutes : nil)
        }
        return nil // desktop Mac
    }

    /// Share of CPU time not idle since the previous call.
    private func readCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return cpu }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3] // user, system, idle, nice
        defer { lastTicks = ticks }
        guard let last = lastTicks else { return cpu }
        let delta = zip(ticks, last).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        return total > 0 ? (total - delta[2]) / total : cpu
    }

    /// "Memory Used" as Activity Monitor shows it: app memory + wired + compressed.
    private func readMemoryUsed() -> Double {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return memoryUsed }
        let pages = UInt64(s.internal_page_count) - UInt64(s.purgeable_count) + UInt64(s.wire_count) + UInt64(s.compressor_page_count)
        return Double(pages) * Double(vm_kernel_page_size)
    }

    private func scanDevices() {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile() // read before waiting, or a full pipe deadlocks
            p.waitUntilExit()
            let devices = Self.parseBluetooth(data)
            DispatchQueue.main.async { self.devices = devices }
        }
    }

    /// Connected devices that report a battery, e.g. `"device_batteryLevelLeft": "80%"`.
    static func parseBluetooth(_ data: Data) -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        let order = ["Left", "Right", "Case"]
        var result: [Device] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let levels = info.compactMap { key, raw -> Level? in
                        guard key.hasPrefix("device_batteryLevel"), let text = raw as? String,
                              let percent = Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) else { return nil }
                        let part = String(key.dropFirst("device_batteryLevel".count))
                        return Level(part: part == "Main" ? "" : part, percent: percent)
                    }
                    .sorted { (order.firstIndex(of: $0.part) ?? 9) < (order.firstIndex(of: $1.part) ?? 9) }
                    if !levels.isEmpty { result.append(Device(name: name, levels: levels)) }
                }
            }
        }
        return result.sorted { $0.name < $1.name }
    }
}

/// Claude Code sessions running on this Mac. Each one keeps `~/.claude/sessions/<pid>.json`
/// up to date (name, project folder, busy/idle). Only those .json files are read.
final class ClaudeAgents: ObservableObject {
    static let shared = ClaudeAgents()

    struct Session: Identifiable, Equatable {
        let id: String
        let name: String
        let project: String
        let busy: Bool
        let started: Date
    }

    @Published var sessions: [Session] = []
    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let found = files.filter { $0.pathExtension == "json" }.compactMap { try? Data(contentsOf: $0) }.compactMap { Self.parse($0) }
        sessions = found.sorted { $0.busy != $1.busy ? $0.busy : $0.started > $1.started }
    }

    /// shortcut: a session file left by a crashed Claude Code shows as running if macOS reuses its pid;
    /// compare "procStart" with the process start time if that ever shows up.
    static func parse(_ data: Data, isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> Session? {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (d["pid"] as? NSNumber)?.int32Value, isAlive(pid) else { return nil }
        let project = URL(fileURLWithPath: d["cwd"] as? String ?? "").lastPathComponent
        let started = ((d["startedAt"] as? NSNumber)?.doubleValue).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        return Session(id: d["sessionId"] as? String ?? String(pid), name: d["name"] as? String ?? project,
                       project: project, busy: d["status"] as? String == "busy", started: started)
    }
}

/// Your Claude plan limits, the numbers `/usage` shows in Claude Code. Opt-in: this is the only
/// part of Visor that uses the network or a credential. It reads Claude Code's login from the
/// keychain (macOS asks first), sends it only to api.anthropic.com, never stores or logs it,
/// never follows redirects, and never refreshes it (that could sign you out of Claude Code).
final class ClaudeLimits: ObservableObject {
    static let shared = ClaudeLimits()

    struct Window: Equatable { var percent: Double; var resetsAt: Date? }

    @Published var fiveHour: Window?
    @Published var weekly: Window?
    @Published var message: String?
    private var lastFetch = Date.distantPast
    private var fetching = false

    /// Try again now (the user clicked the error message).
    func retry() { lastFetch = .distantPast }

    /// Called on every Home tick; fetches at most every 5 minutes.
    func refreshIfDue(enabled: Bool) {
        guard enabled else { fiveHour = nil; weekly = nil; message = nil; lastFetch = .distantPast; return }
        guard !fetching, Date().timeIntervalSince(lastFetch) > 300 else { return }
        fetching = true
        lastFetch = Date()
        Task.detached(priority: .utility) {
            let result = await Self.fetch()
            await MainActor.run {
                self.fetching = false
                switch result {
                case let .success(limits): (self.fiveHour, self.weekly, self.message) = (limits.0, limits.1, nil)
                case let .failure(error):
                    self.message = error.text
                    // A "Deny" must stick: only a click on the message asks macOS again.
                    if error.denied { self.lastFetch = .distantFuture }
                }
            }
        }
    }

    struct Failure: Error {
        let text: String
        var denied = false
        static let expired = Failure(text: "Claude Code login expired. Run `claude` in Terminal once to renew it.")
    }

    private static func fetch() async -> Result<(Window?, Window?), Failure> {
        let token: (value: String, expires: Date?)
        switch validToken() {
        case let .success(t): token = t
        case let .failure(f): return .failure(f)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("Visor", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request, delegate: NoRedirects()),
              let http = response as? HTTPURLResponse else { return .failure(Failure(text: "Couldn't reach Anthropic.")) }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { cachedToken = nil } // revoked or renewed elsewhere: read the keychain again next time
            return .failure(http.statusCode == 401 ? .expired : Failure(text: "Anthropic answered \(http.statusCode). Try again later."))
        }
        guard let usage = parse(data) else { return .failure(Failure(text: "Unexpected answer from Anthropic.")) }
        return .success(usage)
    }

    private static let session = URLSession(configuration: .ephemeral) // no cookies, no cache on disk

    /// The token lasts 8 hours and only Claude Code renews it, which the desktop app doesn't do.
    /// So when it has expired, let Claude Code itself renew it (`claude auth status`), then read it again.
    /// Visor never calls the renewal endpoint or writes the keychain.
    /// Kept in memory (never on disk) so the keychain, and its macOS prompt, is only touched
    /// when the token is missing, about to expire or rejected: about once per 8 hours, not every 5 minutes.
    /// Only the fetch task touches it, and fetches never overlap (`fetching`).
    private static var cachedToken: (value: String, expires: Date?)?

    private static func validToken(renew: Bool = true) -> Result<(value: String, expires: Date?), Failure> {
        if let cached = cachedToken, (cached.expires ?? .distantFuture) > Date().addingTimeInterval(60) { return .success(cached) }
        let result = readToken()
        if case let .success(token) = result { cachedToken = token }
        guard case let .success(token) = result, let expires = token.expires, expires < Date().addingTimeInterval(60) else { return result }
        guard renew, runClaudeAuthStatus() else { return .failure(.expired) }
        return validToken(renew: false)
    }

    /// Where the Claude Code installers put the `claude` command.
    private static let claudePaths = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.claude/local/claude"]
        .map { ($0 as NSString).expandingTildeInPath }

    /// Fixed path and arguments, no shell, output discarded, killed after 20 s.
    private static func runClaudeAuthStatus() -> Bool {
        guard let path = claudePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["auth", "status"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let deadline = Date().addingTimeInterval(20)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { p.terminate() }
        return true
    }

    static let signInHelp = "Sign in once in Terminal: run `claude`, type /login, then /exit. (Claude Code inside the Claude desktop app keeps its login to itself.)"

    private static func readToken() -> Result<(value: String, expires: Date?), Failure> {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "Claude Code-credentials",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess: break
        case errSecItemNotFound: return .failure(Failure(text: "No Claude Code login on this Mac. " + signInHelp))
        default: return .failure(Failure(text: "Keychain access was denied. Click here to ask again, then choose Always Allow.", denied: true))
        }
        guard let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return .failure(Failure(text: "Claude Code isn't signed in with a Claude account. " + signInHelp))
        }
        let expires = ((oauth["expiresAt"] as? NSNumber)?.doubleValue).map { Date(timeIntervalSince1970: $0 / 1000) }
        return .success((token, expires))
    }

    /// `{"five_hour": {"utilization": 42, "resets_at": "2026-10-21T18:00:00.123+00:00"}, "seven_day": {...}}`
    static func parse(_ data: Data) -> (Window?, Window?)? {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ key: String) -> Window? {
            guard let w = d[key] as? [String: Any], let used = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            var reset: Date?
            if let seconds = (w["resets_at"] as? NSNumber)?.doubleValue {
                reset = Date(timeIntervalSince1970: seconds)
            } else if let text = w["resets_at"] as? String {
                // ISO8601DateFormatter rejects microseconds, so drop the fraction.
                let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
                reset = ISO8601DateFormatter().date(from: trimmed)
            }
            return Window(percent: min(max(used, 0), 100), resetsAt: reset)
        }
        return (window("five_hour"), window("seven_day"))
    }
}

/// The token must only ever go to api.anthropic.com, so redirects are refused.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

// MARK: - View

struct HomeView: View {
    @ObservedObject var stats = SystemStats.shared
    @ObservedObject var agents = ClaudeAgents.shared
    @ObservedObject var limits = ClaudeLimits.shared
    @AppStorage("claudeLimitsEnabled") private var limitsEnabled = false
    static var live = true // false while rendering README screenshots
    // static: a stored timer would restart every time SwiftUI rebuilds this view (4x/s during downloads).
    // It still only ticks while the tab is visible: autoconnect stops when nobody is listening.
    private static let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                if let b = stats.battery {
                    StatRow(icon: b.charging ? "battery.100percent.bolt" : batteryIcon(b.percent), title: "Battery",
                            value: "\(b.percent)%", detail: batteryDetail(b), level: Double(b.percent) / 100,
                            tint: b.percent <= 20 && !b.pluggedIn ? .red : .green)
                }
                StatRow(icon: "cpu", title: "CPU", value: "\(Int(stats.cpu * 100))%", level: stats.cpu, tint: .blue)
                StatRow(icon: "memorychip", title: "Memory", value: gb(stats.memoryUsed) + " / " + gb(stats.memoryTotal),
                        level: stats.memoryUsed / stats.memoryTotal, tint: .purple)
                ForEach(stats.devices) { device in
                    HStack(spacing: 6) {
                        Image(systemName: deviceIcon(device.name)).frame(width: 16)
                        Text(device.name).lineLimit(1)
                        Spacer(minLength: 4)
                        ForEach(device.levels, id: \.part) { level in
                            Text((level.part.isEmpty ? "" : String(level.part.prefix(1)) + " ") + "\(level.percent)%")
                                .foregroundStyle(level.percent <= 20 ? .red : .white.opacity(0.7))
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Label("Claude", systemImage: "sparkle").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                if limitsEnabled {
                    if let message = limits.message {
                        Button { limits.retry(); refresh() } label: {
                            Text(message).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3).multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .help("Click to try again")
                    }
                    if let w = limits.fiveHour { LimitRow(title: "5-hour", window: w) }
                    if let w = limits.weekly { LimitRow(title: "Weekly", window: w) }
                } else {
                    Button { limitsEnabled = true } label: {
                        Text("Show plan limits…").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Reads your Claude Code login from the keychain (macOS asks first) and checks api.anthropic.com every 5 minutes while this tab is open.")
                }
                AgentList(sessions: agents.sessions)
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: refresh)
        .onReceive(Self.tick) { _ in refresh() }
        .onDisappear { stats.pauseCPU() }
        .onChange(of: limitsEnabled) { refresh() }
        .contextMenu { if limitsEnabled { Button("Hide Plan Limits") { limitsEnabled = false } } }
    }

    private func refresh() {
        guard Self.live else { return }
        stats.refresh()
        agents.refresh()
        limits.refreshIfDue(enabled: limitsEnabled)
    }

    private func gb(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / 1_073_741_824) }
    private func batteryIcon(_ p: Int) -> String {
        p > 87 ? "battery.100percent" : p > 62 ? "battery.75percent" : p > 37 ? "battery.50percent" : p > 12 ? "battery.25percent" : "battery.0percent"
    }
    private func batteryDetail(_ b: SystemStats.Battery) -> String? {
        if b.charging { return "Charging" }
        if b.pluggedIn { return "Plugged in" }
        return b.minutesLeft.map { "\($0 / 60)h \($0 % 60)m left" }
    }
    private func deviceIcon(_ name: String) -> String {
        let n = name.lowercased()
        return n.contains("airpods") ? "airpods" : n.contains("keyboard") ? "keyboard" : n.contains("mouse") ? "computermouse"
            : n.contains("trackpad") ? "rectangle.and.hand.point.up.left" : "headphones"
    }
}

private struct StatRow: View {
    let icon: String, title: String, value: String
    var detail: String?
    let level: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).frame(width: 16)
                Text(title).foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 4)
                if let detail { Text(detail).foregroundStyle(.white.opacity(0.45)) }
                Text(value).monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            LevelBar(level: Float(min(max(level, 0), 1)), tint: tint).frame(height: 4)
        }
    }
}

private struct LimitRow: View {
    let title: String
    let window: ClaudeLimits.Window

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.white.opacity(0.6))
                Spacer()
                if let reset = window.resetsAt, reset > Date() {
                    Text("resets " + reset.formatted(.relative(presentation: .named))).foregroundStyle(.white.opacity(0.45))
                }
                Text("\(Int(window.percent.rounded()))%").monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            LevelBar(level: Float(window.percent / 100), tint: window.percent >= 90 ? .red : window.percent >= 70 ? .orange : .white)
                .frame(height: 4)
        }
    }
}

private struct AgentList: View {
    let sessions: [ClaudeAgents.Session]

    var body: some View {
        if sessions.isEmpty {
            Text("No Claude Code sessions running").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 5) {
                    ForEach(sessions) { s in
                        HStack(spacing: 7) {
                            Circle().fill(s.busy ? Color.green : .white.opacity(0.3)).frame(width: 6, height: 6)
                            Text(s.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(s.busy ? "working" : s.started.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .help(s.project)
                    }
                }
            }
        }
    }
}
