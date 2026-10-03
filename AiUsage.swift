import SwiftUI
import AppKit
import Combine
import CryptoKit
@preconcurrency import UserNotifications
import ServiceManagement

// MARK: - Model

struct ClaudeSession: Equatable {
    let pid: Int
    let name: String
    let status: String
    var isBusy: Bool { status == "busy" }
}

/// One Claude Code profile: ~/.claude, or a CLAUDE_CONFIG_DIR folder signed in to another account.
struct ClaudeAccount: Equatable, Sendable {
    static let defaultConfigDir = NSHomeDirectory() + "/.claude"
    let service: String          // stable id: the config dir path
    let configDir: String?
    let email: String?
    var isDefault: Bool { configDir == Self.defaultConfigDir }
    var label: String {
        email ?? configDir.map { ($0 as NSString).lastPathComponent } ?? service
    }
    var initial: String { String(label.prefix(1)).uppercased() }
}

struct AccountUsage: Identifiable, Equatable {
    let account: ClaudeAccount
    var limits: [Limit] = []
    var forecasts: [LimitKind: Forecast] = [:]
    var error: String?
    var id: String { account.service }
    func limit(_ k: LimitKind) -> Limit? { limits.first { $0.kind == k } }
}

enum LimitKind: String, Codable { case fiveHour, week, opus, sonnet }

struct Limit: Identifiable, Codable, Equatable {
    let kind: LimitKind
    let title: String
    let used: Double          // 0...100
    let resetsAt: Date?
    var id: String { kind.rawValue }
    var remaining: Double { max(0, 100 - used) }
}

// MARK: - Status line bridge

/// Where the numbers come from, without ever touching your login.
///
/// After each response Claude Code passes its own rate-limit numbers (`rate_limits.five_hour`,
/// `rate_limits.seven_day`) to the status line command. AiUsage registers itself as that command
/// (`AiUsage --statusline`): it saves the numbers to one small file per profile and prints a short
/// status. The app then just reads those files. No OAuth token is read, refreshed or sent anywhere.
enum Bridge {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AiUsage/limits", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        p = (p as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func fileURL(for configDir: String) -> URL {
        dir.appendingPathComponent(UsageStore.hash8(configDir) + ".json")
    }

    static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    // MARK: Claude Code side

    /// Entry point when Claude Code runs `AiUsage --statusline`. Must stay fast and quiet.
    static func runStatusLine() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map(normalize)
            ?? ClaudeAccount.defaultConfigDir
        var parts: [String] = []
        if let model = (obj["model"] as? [String: Any])?["display_name"] as? String { parts.append(model) }
        if let rl = obj["rate_limits"] as? [String: Any] {
            var out: [String: Any] = ["configDir": configDir, "updatedAt": Date().timeIntervalSince1970]
            for (key, label) in [("five_hour", "5h"), ("seven_day", "7d")] {
                guard let w = rl[key] as? [String: Any] else { continue }
                out[key] = w
                if let p = num(w["used_percentage"]) { parts.append("\(label) \(Int(p.rounded()))%") }
            }
            if let data = try? JSONSerialization.data(withJSONObject: out) {
                try? data.write(to: fileURL(for: configDir), options: .atomic)
            }
        }
        print(parts.joined(separator: " · "))
        exit(0)
    }

    // MARK: App side

    struct Snapshot {
        let configDir: String
        let updatedAt: Date
        let limits: [Limit]
    }

    static func read() -> [Snapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let now = Date()
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let configDir = obj["configDir"] as? String,
                  let updated = num(obj["updatedAt"]) else { return nil }
            var limits: [Limit] = []
            for (key, kind) in [("five_hour", LimitKind.fiveHour), ("seven_day", LimitKind.week)] {
                guard let w = obj[key] as? [String: Any], let used = num(w["used_percentage"]) else { continue }
                let reset = num(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
                if let reset, reset <= now {
                    // The window rolled over since Claude Code last reported: it's empty again.
                    limits.append(Limit(kind: kind, title: "", used: 0, resetsAt: nil))
                } else {
                    limits.append(Limit(kind: kind, title: "", used: min(100, max(0, used)), resetsAt: reset))
                }
            }
            return Snapshot(configDir: configDir, updatedAt: Date(timeIntervalSince1970: updated), limits: limits)
        }
    }

    /// ~/.claude plus every ~/.claude-* folder that looks like a Claude Code profile.
    static func profiles() -> [String] {
        let home = NSHomeDirectory()
        var out = [ClaudeAccount.defaultConfigDir]
        for n in ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []).sorted() where n.hasPrefix(".claude-") {
            let p = home + "/" + n
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            if FileManager.default.fileExists(atPath: p + "/.claude.json") || FileManager.default.fileExists(atPath: p + "/settings.json") {
                out.append(p)
            }
        }
        return out
    }

    enum InstallState: Equatable { case installed, missing, other(String) }

    static var command: String { "\"\(Bundle.main.executablePath ?? "/Applications/AiUsage.app/Contents/MacOS/AiUsage")\" --statusline" }

    private static func settingsURL(_ configDir: String) -> URL {
        URL(fileURLWithPath: configDir).appendingPathComponent("settings.json")
    }

    private static func readSettings(_ configDir: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL(configDir)) else { return [:] }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]   // nil = unreadable, leave it alone
    }

    static func state(_ configDir: String) -> InstallState {
        guard let cmd = (readSettings(configDir)?["statusLine"] as? [String: Any])?["command"] as? String else { return .missing }
        return cmd.contains("--statusline") && cmd.contains("AiUsage") ? .installed : .other(cmd)
    }

    /// Adds AiUsage as the status line of one profile. Never replaces someone else's status line.
    @discardableResult
    static func install(_ configDir: String) -> InstallState {
        let current = state(configDir)
        if case .other = current { return current }
        guard var settings = readSettings(configDir) else { return .other("settings.json unreadable") }
        let url = settingsURL(configDir)
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent("settings.json.aiusage-backup")
            if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: url, to: backup) }
        }
        settings["statusLine"] = ["type": "command", "command": command, "padding": 0]
        guard let data = try? JSONSerialization.data(withJSONObject: settings,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? data.write(to: url, options: .atomic)) != nil else { return .missing }
        return .installed
    }

    static func installAll() -> [(String, InstallState)] {
        profiles().map { ($0, install($0)) }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    @Published var limits: [Limit] = []
    @Published var error: String?
    @Published var lastUpdate: Date?
    @Published var sessions: [ClaudeSession] = []
    @Published var tokens = TokenTotals()
    @Published var forecasts: [LimitKind: Forecast] = [:]
    @Published var update: AppUpdate?
    /// Profile in ~/.claude (what the desktop app and plain `claude` use).
    @Published var defaultAccount: ClaudeAccount?
    /// Other CLAUDE_CONFIG_DIR profiles, each with its own limits.
    @Published var accounts: [AccountUsage] = []
    /// Config dirs to scan for sessions and transcripts (read from background threads).
    nonisolated(unsafe) static var configDirs: [String] = [ClaudeAccount.defaultConfigDir]

    let watcher = LimitWatcher()
    private var busySince: [Int: Date] = [:]
    private var sessionsPrimed = false
    private var updateTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastIngested: [String: [Limit]] = [:]

    private let tokenCounter = TokenCounter()
    private var tokenTimer: Timer?
    private var sessionTimer: Timer?
    private var claudeLimits: [Limit] = []
    private var timer: Timer?

    init() {
        refresh()
        // Reading a few tiny local files: cheap enough to do often.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 3
        refreshTokens()
        tokenTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTokens() }
        }
        refreshSessions()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSessions() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.refreshSessions()
                self?.refreshTokens()
            }
        }
    }

    // MARK: Updates

    nonisolated static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func startUpdateChecks() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            self.checkForUpdate()
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdate() }
        }
    }

    /// Looks at the latest GitHub release; notifies once per new version (or always when `manual`).
    func checkForUpdate(manual: Bool = false) {
        Task {
            let current = Self.appVersion
            do {
                var req = URLRequest(url: URL(string: "https://api.github.com/repos/RYG-Labs/AiUsage/releases/latest")!)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.setValue("aiusage/\(current)", forHTTPHeaderField: "User-Agent")
                req.timeoutInterval = 15
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200,
                      let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String,
                      let page = (obj["html_url"] as? String).flatMap(URL.init(string:))
                else { throw WidgetError.msg("GitHub") }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if Self.isVersion(latest, newerThan: current) {
                    update = AppUpdate(version: latest, url: page)
                    let d = UserDefaults.standard
                    if manual || d.string(forKey: "notifiedUpdateVersion") != latest {
                        d.set(latest, forKey: "notifiedUpdateVersion")
                        Notifier.post(L.t("⬆︎ Đã có AiUsage v\(latest)", "⬆︎ AiUsage v\(latest) is available"),
                                      L.t("Bạn đang dùng v\(current). Bấm để mở trang tải về.",
                                          "You have v\(current). Click to open the download page."),
                                      url: page)
                    }
                } else {
                    update = nil
                    if manual {
                        Notifier.post("AiUsage", L.t("Bạn đang dùng bản mới nhất (v\(current)).",
                                                     "You're on the latest version (v\(current))."))
                    }
                }
            } catch {
                if manual {
                    Notifier.post("AiUsage", L.t("Không kiểm tra được bản mới. Thử lại sau.",
                                                 "Couldn't check for updates. Try again later."))
                }
            }
        }
    }

    nonisolated static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func refreshTokens() {
        let counter = tokenCounter
        Task.detached(priority: .utility) {
            let t = counter.scan()
            await MainActor.run { if t != self.tokens { self.tokens = t } }
        }
    }

    var runningSessions: [ClaudeSession] { sessions.filter(\.isBusy) }

    /// Claude Code writes one ~/.claude/sessions/<pid>.json per live session with a
    /// "status" of busy/idle; only count those whose process is still alive.
    func refreshSessions() {
        var out: [ClaudeSession] = []
        for base in Self.configDirs {
        let dir = base + "/sessions"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for f in files where f.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) == 0
            else { continue }
            let cwd = obj["cwd"] as? String ?? ""
            let name = (obj["name"] as? String) ?? (cwd as NSString).lastPathComponent
            out.append(ClaudeSession(pid: pid, name: name, status: obj["status"] as? String ?? "unknown"))
        }
        }
        out.sort { $0.pid < $1.pid }
        notifyFinishedTasks(out)
        if out != sessions { sessions = out }
    }

    /// Posts "task finished" when a session goes busy → idle (or its process exits).
    /// Very short turns (< 20 s) are skipped so quick replies don't spam.
    private func notifyFinishedTasks(_ now: [ClaudeSession]) {
        let t = Date()
        let busyNow = Set(now.filter(\.isBusy).map(\.pid))
        for s in now where s.isBusy && busySince[s.pid] == nil { busySince[s.pid] = t }
        for (pid, start) in busySince where !busyNow.contains(pid) {
            busySince[pid] = nil
            let elapsed = t.timeIntervalSince(start)
            guard sessionsPrimed, elapsed >= 20, UserDefaults.standard.bool(forKey: Pref.notifyTasks) else { continue }
            let current = now.first { $0.pid == pid }
            let name = current?.name ?? sessions.first { $0.pid == pid }?.name ?? "Claude Code"
            let closed = current == nil
            Notifier.post(L.t("✅ Task xong: \(name)", "✅ Task finished: \(name)"),
                          L.t("Chạy trong \(formatDuration(elapsed))" + (closed ? " · phiên đã đóng" : ""),
                              "Ran for \(formatDuration(elapsed))" + (closed ? " · session closed" : "")))
        }
        sessionsPrimed = true
    }

    var fiveHour: Limit? { limits.first { $0.kind == .fiveHour } }

    func recompose() {
        limits = error == nil ? claudeLimits : []
    }

    /// Rings on the tab: limits + the red "not connected" ring + one per extra account.
    var ringCount: Int { max(1, limits.count + (error != nil ? 1 : 0) + accounts.count) }

    /// Picks up whatever Claude Code last reported through the status line.
    func refresh() {
        let snaps = Bridge.read()
        let home = ClaudeAccount.defaultConfigDir
        Self.configDirs = Array(Set([home] + Bridge.profiles() + snaps.map(\.configDir))).sorted()
        defaultAccount = ClaudeAccount(service: home, configDir: home, email: Self.accountEmail(configDir: home))

        if let main = snaps.first(where: { $0.configDir == home }), !main.limits.isEmpty {
            claudeLimits = main.limits
            error = nil
            lastUpdate = main.updatedAt
            if lastIngested[home] != main.limits {
                lastIngested[home] = main.limits
                for x in main.limits { forecasts[x.kind] = watcher.ingest(x) }
            }
        } else {
            claudeLimits = []
            error = Bridge.state(home) == .installed
                ? L.t("Chưa nhận số liệu — gửi một tin nhắn trong Claude Code là có",
                      "No numbers yet — send a message in Claude Code")
                : L.t("Chưa kết nối Claude Code — bấm vào tab → Kết nối Claude Code",
                      "Not connected — click the tab → Connect Claude Code")
        }

        var out: [AccountUsage] = []
        for snap in snaps where snap.configDir != home && !snap.limits.isEmpty {
            let acct = ClaudeAccount(service: snap.configDir, configDir: snap.configDir,
                                     email: Self.accountEmail(configDir: snap.configDir))
            var u = AccountUsage(account: acct, limits: snap.limits)
            u.forecasts = accounts.first { $0.id == acct.service }?.forecasts ?? [:]
            if lastIngested[snap.configDir] != snap.limits {
                lastIngested[snap.configDir] = snap.limits
                for x in snap.limits { u.forecasts[x.kind] = watcher.ingest(x, account: acct) }
            }
            out.append(u)
        }
        out.sort { $0.account.label < $1.account.label }
        if out != accounts { accounts = out }
        recompose()
    }

    /// Hooks AiUsage into every profile's Claude Code status line and reports what happened.
    func connectClaudeCode() {
        let results = Bridge.installAll()
        let ok = results.filter { $0.1 == .installed }.count
        let skipped = results.compactMap { r -> String? in
            if case .other = r.1 { return (r.0 as NSString).lastPathComponent }
            return nil
        }
        var body = L.t("Đã kết nối \(ok) profile. Gửi một tin nhắn trong Claude Code để có số liệu.",
                       "Connected \(ok) profile(s). Send a message in Claude Code to get numbers.")
        if !skipped.isEmpty {
            body += L.t(" Bỏ qua (đang dùng status line khác): ", " Skipped (another status line in use): ") + skipped.joined(separator: ", ")
        }
        Notifier.post("AiUsage", body)
        refresh()
    }

    var allConnected: Bool { Bridge.profiles().allSatisfy { Bridge.state($0) == .installed } }

    enum WidgetError: Error {
        case msg(String)
        var text: String { if case .msg(let s) = self { return s }; return "" }
    }

    nonisolated static func hash8(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    /// Email of the account signed in to a config dir (from its .claude.json).
    nonisolated static func accountEmail(configDir: String) -> String? {
        let home = NSHomeDirectory()
        let file = configDir == home + "/.claude" ? home + "/.claude.json" : configDir + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acct = obj["oauthAccount"] as? [String: Any] else { return nil }
        return acct["emailAddress"] as? String
    }
}

// MARK: - Settings

enum Pref {
    static let showRemaining = "showRemaining"
    static let alwaysOnTop = "alwaysOnTop"
    static let showMenuBar = "showMenuBar"
    static let panelTop = "panelTop"
    static let showTasks = "showTasks"
    static let showTokens = "showTokens"
    static let panelScreenID = "panelScreenID"
    static let language = "language"
    static let notifyLimits = "notifyLimits"
    static let notifyReset = "notifyReset"
    static let notifyForecast = "notifyForecast"
    static let notifyTasks = "notifyTasks"
}

// MARK: - Localization

enum Lang: String { case vi, en }

/// App language, chosen from the settings menu — independent of the macOS system language.
enum L {
    static var current: Lang {
        Lang(rawValue: UserDefaults.standard.string(forKey: Pref.language) ?? "vi") ?? .vi
    }
    static func t(_ vi: String, _ en: String) -> String { current == .vi ? vi : en }
}

extension LimitKind {
    var localizedTitle: String {
        switch self {
        case .fiveHour: return L.t("Phiên 5 giờ", "5-hour session")
        case .week: return L.t("Tuần (7 ngày)", "Weekly (7 days)")
        case .opus: return L.t("Tuần — Opus", "Weekly — Opus")
        case .sonnet: return L.t("Tuần — Sonnet", "Weekly — Sonnet")
        }
    }
}

func displayTitle(_ l: Limit) -> String { l.kind.localizedTitle }

/// Absolute reset time in GMT+7, e.g. "21:10 T2 28/09 (GMT+7)".
func resetClock(_ date: Date?) -> String {
    guard let date else { return "—" }
    let f = DateFormatter()
    f.locale = Locale(identifier: L.current == .vi ? "vi_VN" : "en_US")
    f.timeZone = TimeZone(secondsFromGMT: 7 * 3600)
    f.dateFormat = "HH:mm EEE dd/MM"
    return f.string(from: date) + " (GMT+7)"
}

func countdown(to date: Date?, now: Date = .now) -> String {
    guard let date else { return "—" }
    let s = Int(date.timeIntervalSince(now))
    if s <= 0 { return L.t("đang reset", "resetting") }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if L.current == .vi {
        if d > 0 { return "\(d)n \(h)g" }
        if h > 0 { return "\(h)g \(m)p" }
        return "\(m)p"
    } else {
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

/// Claude brand orange.
let claudeOrange = Color(red: 0.851, green: 0.467, blue: 0.341)

/// Running-task badge green.
let runningGreen = Color(red: 0.20, green: 0.78, blue: 0.35)


func ringColor(_ kind: LimitKind) -> Color { claudeOrange }

/// Color by how much has been used: green → yellow → red.
func severityColor(used: Double) -> Color {
    if used >= 75 { return Color(red: 1.0, green: 0.30, blue: 0.13) }
    if used >= 40 { return Color(red: 0.98, green: 0.92, blue: 0.10) }
    return Color(red: 0.20, green: 0.85, blue: 0.45)
}

// MARK: - Side tab shape

/// Black tab glued to the right screen edge, with concave "shoulders" that
/// melt into the edge above and below, and rounded corners on the left side.
struct SideTabShape: Shape {
    var shoulder: CGFloat = 26
    var corner: CGFloat = 30

    func path(in rect: CGRect) -> Path {
        let W = rect.maxX, H = rect.maxY, s = shoulder, c = corner
        var p = Path()
        p.move(to: CGPoint(x: W, y: 0))
        // top shoulder (concave)
        p.addCurve(to: CGPoint(x: W - s * 1.4, y: s),
                   control1: CGPoint(x: W, y: s * 0.75),
                   control2: CGPoint(x: W - s * 0.55, y: s))
        p.addLine(to: CGPoint(x: c, y: s))
        // top-left corner (convex)
        p.addQuadCurve(to: CGPoint(x: 0, y: s + c), control: CGPoint(x: 0, y: s))
        p.addLine(to: CGPoint(x: 0, y: H - s - c))
        // bottom-left corner (convex)
        p.addQuadCurve(to: CGPoint(x: c, y: H - s), control: CGPoint(x: 0, y: H - s))
        p.addLine(to: CGPoint(x: W - s * 1.4, y: H - s))
        // bottom shoulder (concave)
        p.addCurve(to: CGPoint(x: W, y: H),
                   control1: CGPoint(x: W - s * 0.55, y: H - s),
                   control2: CGPoint(x: W, y: H - s * 0.75))
        p.closeSubpath()
        return p
    }
}

// MARK: - Icons

/// Claude-style starburst.
struct ClaudeBurst: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2
            var p = Path()
            for i in 0..<12 {
                let a = Double(i) * .pi / 6 + .pi / 12
                let outer = r * (i.isMultiple(of: 2) ? 1.0 : 0.78)
                p.move(to: CGPoint(x: c.x + cos(a) * r * 0.18, y: c.y + sin(a) * r * 0.18))
                p.addLine(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
            }
            ctx.stroke(p, with: .color(claudeOrange), style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
        }
    }
}

struct LimitIcon: View {
    let kind: LimitKind
    var body: some View {
        switch kind {
        case .fiveHour: ClaudeBurst().frame(width: 12, height: 12)
        case .week: Image(systemName: "calendar").font(.system(size: 9.5, weight: .medium))
        case .opus: Image(systemName: "crown").font(.system(size: 8.5, weight: .medium))
        case .sonnet: Image(systemName: "music.note").font(.system(size: 9.5, weight: .medium))
        }
    }
}

// MARK: - Ring gauge

enum Layout {
    static let tabWidth: CGFloat = 40
    static let shoulder: CGFloat = 14
    static let corner: CGFloat = 17
    static let ring: CGFloat = 26
    static let ringLine: CGFloat = 2.8
    static let ringBlock: CGFloat = ring + 2 + 11   // ring + spacing + label
    static let ringSpacing: CGFloat = 14
    static let padding: CGFloat = 9

    static let badge: CGFloat = 18
    static let tokenBlock: CGFloat = 24

    static func tabHeight(count: Int) -> CGFloat {
        let n = CGFloat(max(1, count))
        let d = UserDefaults.standard
        let tasks = d.bool(forKey: Pref.showTasks) ? badge + ringSpacing : 0
        let toks = d.bool(forKey: Pref.showTokens) ? tokenBlock + ringSpacing : 0
        return shoulder * 2 + padding * 2 + tasks + toks + n * ringBlock + (n - 1) * ringSpacing
    }
    static func windowSize(count: Int) -> CGSize {
        CGSize(width: tabWidth, height: tabHeight(count: count))
    }
}

struct RingGauge: View {
    let limit: Limit
    let showRemaining: Bool
    var forecast: Forecast? = nil

    var value: Double { showRemaining ? limit.remaining : limit.used }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: Layout.ringLine)
                Circle()
                    .trim(from: 0, to: max(0.02, value / 100))
                    .stroke(ringColor(limit.kind),
                            style: StrokeStyle(lineWidth: Layout.ringLine, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: value)
                LimitIcon(kind: limit.kind).foregroundStyle(.white)
            }
            .frame(width: Layout.ring, height: Layout.ring)
            Text("\(Int(value.rounded()))%")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(height: 11)
        }
        .help(L.t(
            "\(displayTitle(limit))\nĐã dùng \(Int(limit.used.rounded()))% · còn \(Int(limit.remaining.rounded()))%\nReset sau \(countdown(to: limit.resetsAt)) — lúc \(resetClock(limit.resetsAt))\(forecastText(forecast).map { "\n" + $0 } ?? "")\n(Bấm để mở cài đặt, kéo để di chuyển)",
            "\(displayTitle(limit))\nUsed \(Int(limit.used.rounded()))% · \(Int(limit.remaining.rounded()))% left\nResets in \(countdown(to: limit.resetsAt)) — at \(resetClock(limit.resetsAt))\(forecastText(forecast).map { "\n" + $0 } ?? "")\n(Click to open settings, drag to move)"
        ))
    }
}

let errorRed = Color(red: 1.0, green: 0.27, blue: 0.23)

/// Shown instead of the Claude rings when the main account can't be read.
struct ErrorRing: View {
    let message: String
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(errorRed, lineWidth: Layout.ringLine)
                Text("!").font(.system(size: 13, weight: .heavy)).foregroundStyle(errorRed)
            }
            .frame(width: Layout.ring, height: Layout.ring)
            Text(L.t("Lỗi", "Error"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(errorRed)
                .frame(height: 11)
        }
        .help(L.t("Claude: \(message)\n\nNếu lỗi kéo dài, đăng nhập lại: mở Terminal, chạy `claude` rồi gõ /login.",
                  "Claude: \(message)\n\nIf it persists, sign in again: open Terminal, run `claude`, then type /login."))
    }
}

/// Compact ring for another Claude account: outer = 5-hour, inner = weekly, initial in the middle.
struct AccountRing: View {
    let usage: AccountUsage
    let showRemaining: Bool

    private func value(_ l: Limit?) -> Double {
        guard let l else { return 0 }
        return showRemaining ? l.remaining : l.used
    }

    var body: some View {
        let five = usage.limit(.fiveHour), week = usage.limit(.week)
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 2.6)
                Circle().trim(from: 0, to: max(0.02, value(five) / 100))
                    .stroke(claudeOrange, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Group {
                    Circle().stroke(Color.white.opacity(0.14), lineWidth: 2.2)
                    Circle().trim(from: 0, to: max(0.02, value(week) / 100))
                        .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .padding(5)
                Text(usage.account.initial)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: Layout.ring, height: Layout.ring)
            .overlay {
                if usage.error != nil {
                    // Same red ring as the main account's error state.
                    ZStack {
                        Circle().fill(Color.black)
                        Circle().stroke(errorRed, lineWidth: 2.6)
                        Text("!").font(.system(size: 12, weight: .heavy)).foregroundStyle(errorRed)
                    }
                }
            }
            Text(usage.error != nil ? usage.account.initial : five.map { "\(Int(value($0).rounded()))%" } ?? "–")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(height: 11)
        }
        .help(accountTooltip(usage))
    }
}

func accountTooltip(_ u: AccountUsage) -> String {
    var lines = ["👤 " + u.account.label]
    for l in u.limits {
        lines.append(L.t("\(displayTitle(l)): dùng \(Int(l.used.rounded()))% · reset sau \(countdown(to: l.resetsAt)) — lúc \(resetClock(l.resetsAt))",
                         "\(displayTitle(l)): \(Int(l.used.rounded()))% used · resets in \(countdown(to: l.resetsAt)) — at \(resetClock(l.resetsAt))"))
        if let f = forecastText(u.forecasts[l.kind]) { lines.append("   " + f) }
    }
    if let e = u.error { lines.append("⚠︎ " + e) }
    lines.append(L.t("(Vòng ngoài: 5 giờ · vòng trong: tuần)", "(Outer ring: 5-hour · inner ring: weekly)"))
    return lines.joined(separator: "\n")
}

// MARK: - Token burn (today)

struct TokenTotals: Equatable {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0, messages = 0
    var total: Int { input + output + cacheWrite + cacheRead }
}

/// Sums today's token usage from Claude Code transcripts (~/.claude/projects/**/*.jsonl).
/// Reads files incrementally (remembers byte offsets) and resets at local midnight.
final class TokenCounter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "token-counter")
    private var day: Date = .distantPast
    private var offsets: [String: UInt64] = [:]
    private var seen = Set<String>()
    private var totals = TokenTotals()
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func scan() -> TokenTotals { queue.sync { scanLocked() } }

    private func scanLocked() -> TokenTotals {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        if startOfDay != day {
            day = startOfDay; offsets = [:]; seen = []; totals = TokenTotals()
        }
        for base in UsageStore.configDirs {
        let root = URL(fileURLWithPath: base + "/projects")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mod = v.contentModificationDate, mod >= startOfDay,
                  let size = v.fileSize else { continue }
            let path = url.path
            var offset = offsets[path] ?? 0
            if UInt64(size) < offset { offset = 0 }            // file was rewritten
            guard UInt64(size) > offset, let fh = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? fh.close() }
            try? fh.seek(toOffset: offset)
            guard let data = try? fh.readToEnd(), !data.isEmpty,
                  let lastNL = data.lastIndex(of: 0x0A) else { continue }
            // Only consume complete lines; a partial trailing line is re-read next time.
            offsets[path] = offset + UInt64(lastNL + 1)
            for line in data[..<lastNL].split(separator: 0x0A) { ingest(line, since: startOfDay) }
        }
        }
        return totals
    }

    private static let usageMarker = Data("\"usage\"".utf8)

    private func ingest(_ line: Data.SubSequence, since start: Date) {
        guard line.range(of: Self.usageMarker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any],
              let ts = (obj["timestamp"] as? String).flatMap(iso.date(from:)), ts >= start
        else { return }
        // Streaming writes the same response several times; count each request once.
        let key = "\(msg["id"] as? String ?? "")|\(obj["requestId"] as? String ?? "")"
        guard seen.insert(key).inserted else { return }
        func n(_ k: String) -> Int { (u[k] as? Int) ?? 0 }
        totals.input += n("input_tokens")
        totals.output += n("output_tokens")
        totals.cacheWrite += n("cache_creation_input_tokens")
        totals.cacheRead += n("cache_read_input_tokens")
        totals.messages += 1
    }
}

func formatTokens(_ n: Int) -> String {
    let d = Double(n)
    switch n {
    case ..<1_000: return "\(n)"
    case ..<10_000: return String(format: "%.1fK", d / 1e3)
    case ..<1_000_000: return String(format: "%.0fK", d / 1e3)
    case ..<10_000_000: return String(format: "%.1fM", d / 1e6)
    case ..<1_000_000_000: return String(format: "%.0fM", d / 1e6)
    default: return String(format: "%.1fB", d / 1e9)
    }
}

// MARK: - Core Animation helpers
// SwiftUI repeatForever animations re-render the whole hosting view every frame
// (~8% CPU each). These run on CALayers instead, so the render server animates them.

final class LayerBox: NSView {
    let content = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(content)
    }
    required init?(coder: NSCoder) { fatalError() }
    var onLayout: ((CALayer, CGRect) -> Void)?
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        onLayout?(content, bounds)
        CATransaction.commit()
    }
}

func loop(_ keyPath: String, from: Any, to: Any, duration: Double) -> CABasicAnimation {
    let a = CABasicAnimation(keyPath: keyPath)
    a.fromValue = from; a.toValue = to
    a.duration = duration
    a.autoreverses = true
    a.repeatCount = .infinity
    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    a.isRemovedOnCompletion = false
    return a
}

/// Red flame that flickers like a candle; livelier while a task is running.
struct FlickerFlame: NSViewRepresentable {
    var intense: Bool

    @MainActor static let image: CGImage? = {
        let fire = LinearGradient(
            colors: [Color(red: 1.0, green: 0.78, blue: 0.20),
                     Color(red: 1.0, green: 0.32, blue: 0.10),
                     Color(red: 0.88, green: 0.08, blue: 0.10)],
            startPoint: .bottom, endPoint: .top)
        let r = ImageRenderer(content: Image(systemName: "flame.fill")
            .font(.system(size: 10.5)).foregroundStyle(fire))
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        return r.cgImage
    }()

    func makeNSView(context: Context) -> LayerBox {
        let v = LayerBox()
        let l = v.content
        l.contents = Self.image
        l.contentsGravity = .resizeAspect
        l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        l.anchorPoint = CGPoint(x: 0.5, y: 0)          // sway from the base
        l.shadowColor = NSColor.systemRed.cgColor
        l.shadowOpacity = 0.7
        l.shadowRadius = 2.5
        l.shadowOffset = .zero
        v.onLayout = { layer, b in
            guard let img = Self.image else { return }
            let s = NSScreen.main?.backingScaleFactor ?? 2
            let w = CGFloat(img.width) / s, h = CGFloat(img.height) / s
            layer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            layer.position = CGPoint(x: b.midX, y: b.midY - h / 2)
        }
        l.add(loop("transform.scale.y", from: 0.93, to: 1.10, duration: 0.23), forKey: "sy")
        l.add(loop("transform.scale.x", from: 1.03, to: 0.95, duration: 0.37), forKey: "sx")
        l.add(loop("transform.rotation.z", from: -0.05, to: 0.07, duration: 0.41), forKey: "rot")
        l.add(loop("opacity", from: 0.82, to: 1.0, duration: 0.29), forKey: "op")
        l.add(loop("shadowRadius", from: 1.5, to: 3.5, duration: 0.31), forKey: "glow")
        return v
    }

    func updateNSView(_ v: LayerBox, context: Context) {
        // Only burn while Claude is working; a frozen flame costs the WindowServer nothing.
        let speed: Float = intense ? 1.7 : 0
        if v.content.speed != speed {
            // Keep the current phase when changing speed to avoid a jump.
            let l = v.content
            let t = l.convertTime(CACurrentMediaTime(), from: nil)
            l.timeOffset = t; l.beginTime = CACurrentMediaTime(); l.speed = speed
        }
    }
}

/// Small dot that pulses via Core Animation.
struct PulseDot: NSViewRepresentable {
    var active: Bool

    func makeNSView(context: Context) -> LayerBox {
        let v = LayerBox()
        v.onLayout = { l, b in
            l.frame = b
            l.cornerRadius = min(b.width, b.height) / 2
        }
        return v
    }

    func updateNSView(_ v: LayerBox, context: Context) {
        let l = v.content
        l.backgroundColor = NSColor.white.withAlphaComponent(active ? 1 : 0.35).cgColor
        if active, l.animation(forKey: "pulse") == nil {
            l.add(loop("opacity", from: 1.0, to: 0.25, duration: 0.8), forKey: "pulse")
        } else if !active {
            l.removeAnimation(forKey: "pulse")
        }
    }
}

struct TokenBadge: View {
    let tokens: TokenTotals
    var active = false
    var body: some View {
        VStack(spacing: 1) {
            FlickerFlame(intense: active)
                .frame(width: 14, height: 12)
            Text(formatTokens(tokens.total))
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 34, height: Layout.tokenBlock)
        .help(L.t(
            """
            Token Claude Code hôm nay (máy này)
            Tổng: \(tokens.total.formatted())
            • Input: \(tokens.input.formatted())
            • Output: \(tokens.output.formatted())
            • Cache ghi: \(tokens.cacheWrite.formatted())
            • Cache đọc: \(tokens.cacheRead.formatted())
            \(tokens.messages) lượt trả lời
            """,
            """
            Claude Code tokens today (this machine)
            Total: \(tokens.total.formatted())
            • Input: \(tokens.input.formatted())
            • Output: \(tokens.output.formatted())
            • Cache write: \(tokens.cacheWrite.formatted())
            • Cache read: \(tokens.cacheRead.formatted())
            \(tokens.messages) replies
            """
        ))
    }
}

// MARK: - Running task badge

struct TaskBadge: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let running = store.runningSessions
        let active = !running.isEmpty
        HStack(spacing: 3) {
            PulseDot(active: active)
                .frame(width: 5, height: 5)
            Text("\(running.count)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: Layout.badge)
        .background(Capsule().fill(active ? runningGreen : Color.white.opacity(0.14)))
        .help(active
              ? L.t("Claude Code đang chạy \(running.count) task:\n", "Claude Code is running \(running.count) task(s):\n")
                  + running.map { "• \($0.name)" }.joined(separator: "\n")
              : L.t("Không có task Claude Code nào đang chạy (\(store.sessions.count) phiên đang mở)",
                    "No Claude Code task is running (\(store.sessions.count) session(s) open)"))
    }
}

// MARK: - Side widget view

struct SideWidgetView: View {
    @ObservedObject var store: UsageStore
    @AppStorage(Pref.showRemaining) private var showRemaining = false
    @AppStorage(Pref.showTasks) private var showTasks = true
    @AppStorage(Pref.showTokens) private var showTokens = true
    @AppStorage(Pref.language) private var langRaw = Lang.vi.rawValue
    @State private var dragStart: (mouseY: CGFloat, top: CGFloat)?

    var body: some View {
        let count = store.ringCount
        let shape = SideTabShape(shoulder: Layout.shoulder, corner: Layout.corner)
        ZStack {
            shape.fill(Color.black)
            VStack(spacing: Layout.ringSpacing) {
                if showTasks { TaskBadge(store: store) }
                if showTokens {
                    TokenBadge(tokens: store.tokens, active: !store.runningSessions.isEmpty)
                        .contentShape(Rectangle())
                        .onTapGesture { ChartWindow.show() }
                }
                if let e = store.error {
                    ErrorRing(message: e)
                } else if store.limits.isEmpty && store.accounts.isEmpty {
                    placeholder
                }
                ForEach(store.limits) { RingGauge(limit: $0, showRemaining: showRemaining, forecast: store.forecasts[$0.kind]) }
                ForEach(store.accounts) { AccountRing(usage: $0, showRemaining: showRemaining) }
            }
            .padding(.leading, 2)
        }
        .frame(width: Layout.tabWidth, height: Layout.tabHeight(count: count))
        .contentShape(shape)
        .gesture(dragGesture)
        .onTapGesture { SettingsMenu.show(store: store) }
    }

    private var placeholder: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: Layout.ringLine)
                if store.error != nil {
                    Image(systemName: "exclamationmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.mini).tint(.white)
                }
            }
            .frame(width: Layout.ring, height: Layout.ring)
            Text(store.error == nil ? "…" : L.t("lỗi", "error"))
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                .frame(height: 11)
        }
        .help(store.error ?? L.t("Đang tải…", "Loading…"))
    }

    /// Drag vertically to slide the tab along the screen edge.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in
                let mouseY = NSEvent.mouseLocation.y
                if dragStart == nil { dragStart = (mouseY, SidePanel.shared.currentTop) }
                if let s = dragStart { SidePanel.shared.moveTop(to: s.top + (mouseY - s.mouseY)) }
            }
            .onEnded { _ in
                dragStart = nil
                SidePanel.shared.saveTop()
            }
    }
}

// MARK: - Settings menu

@MainActor
enum SettingsMenu {
    final class Handler: NSObject {
        let action: () -> Void
        init(_ a: @escaping () -> Void) { action = a }
        @objc func run() { action() }
    }
    private static var handlers: [Handler] = []

    // MARK: Builders

    @discardableResult
    private static func action(_ menu: NSMenu, _ title: String, checked: Bool? = nil,
                               _ run: @escaping () -> Void) -> NSMenuItem {
        let h = Handler(run)
        handlers.append(h)
        let it = NSMenuItem(title: title, action: #selector(Handler.run), keyEquivalent: "")
        it.target = h
        if let checked { it.state = checked ? .on : .off }
        menu.addItem(it)
        return it
    }

    /// Greyed-out informational line.
    private static func info(_ menu: NSMenu, _ title: String) {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        menu.addItem(it)
    }

    private static func submenu(_ menu: NSMenu, _ title: String, _ build: @MainActor (NSMenu) -> Void) {
        let sub = NSMenu()
        build(sub)
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = sub
        menu.addItem(it)
    }

    /// "Label ........ value" row with the value right-aligned in a secondary color;
    /// details go in a submenu so the main menu stays one line per item.
    private static func row(_ menu: NSMenu, _ label: String, _ value: String, details: [String]) {
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: 250)]
        let title = NSMutableAttributedString(string: label + "\t",
                                              attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: para])
        title.append(NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]))
        let it = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        it.attributedTitle = title
        if !details.isEmpty {
            let sub = NSMenu()
            details.forEach { info(sub, $0) }
            it.submenu = sub
        }
        menu.addItem(it)
    }

    private static func pct(_ l: Limit) -> String {
        let v = UserDefaults.standard.bool(forKey: Pref.showRemaining) ? l.remaining : l.used
        return "\(Int(v.rounded()))%"
    }

    private static func limitDetails(_ l: Limit, _ f: Forecast?) -> [String] {
        var lines = [
            L.t("Đã dùng \(Int(l.used.rounded()))% · còn \(Int(l.remaining.rounded()))%",
                "Used \(Int(l.used.rounded()))% · \(Int(l.remaining.rounded()))% left"),
            L.t("Reset sau \(countdown(to: l.resetsAt))", "Resets in \(countdown(to: l.resetsAt))"),
            L.t("Lúc \(resetClock(l.resetsAt))", "At \(resetClock(l.resetsAt))"),
        ]
        if let t = forecastText(f) { lines.append(t) }
        return lines
    }

    // MARK: Menu

    static func show(store: UsageStore) {
        handlers.removeAll()
        let d = UserDefaults.standard
        let menu = NSMenu()

        if let u = store.update {
            action(menu, L.t("⬆︎ Có bản mới v\(u.version) — Tải về", "⬆︎ v\(u.version) available — Download")) {
                NSWorkspace.shared.open(u.url)
            }
            menu.addItem(.separator())
        }

        // Usage — one line each, details in submenus.
        if !store.accounts.isEmpty, let def = store.defaultAccount {
            menu.addItem(.sectionHeader(title: def.label))
        }
        for l in store.limits {
            let f = store.forecasts[l.kind]
            let warn = f?.hitsBeforeReset == true ? "⚠︎ " : ""
            row(menu, displayTitle(l), "\(warn)\(pct(l)) · \(countdown(to: l.resetsAt))", details: limitDetails(l, f))
        }
        if !store.accounts.isEmpty {
            menu.addItem(.sectionHeader(title: L.t("Tài khoản khác", "Other accounts")))
        }
        for u in store.accounts {
            let five = u.limit(.fiveHour).map(pct) ?? "–"
            let week = u.limit(.week).map(pct) ?? "–"
            let value = u.limits.isEmpty && u.error != nil ? "⚠︎" : "5h \(five) · 7d \(week)"
            let name = u.account.label.count > 26 ? String(u.account.label.prefix(25)) + "…" : u.account.label
            row(menu, "👤 " + name, value, details: accountTooltip(u).split(separator: "\n").dropFirst().dropLast().map(String.init))
        }

        // Activity
        let tk = store.tokens
        let running = store.runningSessions
        var activity = [
            L.t("Tổng: \(tk.total.formatted())", "Total: \(tk.total.formatted())"),
            "Output: \(tk.output.formatted())",
            L.t("Cache đọc: \(tk.cacheRead.formatted())", "Cache read: \(tk.cacheRead.formatted())"),
            L.t("\(store.sessions.count) phiên đang mở · \(running.count) đang chạy",
                "\(store.sessions.count) open sessions · \(running.count) running"),
        ]
        activity += running.map { "▶ \($0.name)" }
        row(menu, L.t("🔥 Hôm nay", "🔥 Today"), "\(formatTokens(tk.total)) · ▶ \(running.count)", details: activity)

        let errors = [store.error].compactMap { $0 }
        if !errors.isEmpty {
            submenu(menu, L.t("⚠︎ Có \(errors.count) lỗi", "⚠︎ \(errors.count) issue(s)")) { m in errors.forEach { info(m, $0) } }
        }

        menu.addItem(.separator())
        action(menu, L.t("📊 Biểu đồ token…", "📊 Token chart…")) { ChartWindow.show() }
        let refresh = action(menu, L.t("Làm mới", "Refresh")) { store.refresh() }
        if let t = store.lastUpdate {
            refresh.toolTip = L.t("Cập nhật lúc ", "Updated at ") + t.formatted(date: .omitted, time: .shortened)
        }

        menu.addItem(.separator())
        submenu(menu, L.t("Cài đặt", "Settings")) { m in
            @MainActor func toggle(_ title: String, _ key: String, _ after: @escaping () -> Void = {}) {
                action(m, title, checked: d.bool(forKey: key)) { d.set(!d.bool(forKey: key), forKey: key); after() }
            }
            m.addItem(.sectionHeader(title: L.t("Hiển thị", "Display")))
            toggle(L.t("% còn lại thay vì đã dùng", "% remaining instead of used"), Pref.showRemaining)
            toggle(L.t("Token hôm nay", "Today's tokens"), Pref.showTokens) { SidePanel.shared.layout() }
            toggle(L.t("Số task đang chạy", "Running task count"), Pref.showTasks) { SidePanel.shared.layout() }
            toggle(L.t("Icon trên menu bar", "Menu bar icon"), Pref.showMenuBar)
            toggle(L.t("Luôn nằm trên cửa sổ khác", "Always on top"), Pref.alwaysOnTop) { SidePanel.shared.applyLevel() }
            if NSScreen.screens.count > 1 {
                submenu(m, L.t("Màn hình", "Display")) { sm in
                    let current = SidePanel.shared.selectedScreen ?? NSScreen.main
                    for (i, scr) in NSScreen.screens.enumerated() {
                        guard let id = SidePanel.displayID(for: scr) else { continue }
                        action(sm, L.t("Màn hình \(i + 1)", "Display \(i + 1)"), checked: scr == current) {
                            d.set(Int(id), forKey: Pref.panelScreenID)
                            SidePanel.shared.layout()
                        }
                    }
                }
            }
            m.addItem(.separator())
            action(m, L.t("Kết nối Claude Code", "Connect Claude Code"), checked: store.allConnected) {
                store.connectClaudeCode()
            }
            submenu(m, L.t("Thông báo", "Notifications")) { nm in
                toggle2(nm, L.t("Limit chạm 80% / 95%", "Limit reaches 80% / 95%"), Pref.notifyLimits)
                toggle2(nm, L.t("Limit vừa reset", "Limit has reset"), Pref.notifyReset)
                toggle2(nm, L.t("Cảnh báo sớm (dự báo)", "Early warning (forecast)"), Pref.notifyForecast)
                toggle2(nm, L.t("Task Claude Code chạy xong", "Claude Code task finished"), Pref.notifyTasks)
                nm.addItem(.separator())
                action(nm, L.t("Gửi thông báo thử", "Send test notification")) {
                    Notifier.post(L.t("🔔 Thông báo thử", "🔔 Test notification"),
                                  L.t("Thông báo của AiUsage đang hoạt động.", "AiUsage notifications are working."))
                }
            }
            submenu(m, "Ngôn ngữ / Language") { lm in
                for lang in [Lang.vi, .en] {
                    action(lm, lang == .vi ? "Tiếng Việt" : "English", checked: L.current == lang) {
                        d.set(lang.rawValue, forKey: Pref.language)
                    }
                }
            }
            action(m, L.t("Tự chạy khi mở máy", "Launch at login"), checked: LoginItem.isEnabled) { LoginItem.toggle() }
        }
        submenu(menu, "AiUsage v\(UsageStore.appVersion)") { m in
            action(m, L.t("Kiểm tra bản mới…", "Check for updates…")) { store.checkForUpdate(manual: true) }
            action(m, L.t("Mở trang GitHub", "Open on GitHub")) {
                NSWorkspace.shared.open(URL(string: "https://github.com/RYG-Labs/AiUsage")!)
            }
        }
        action(menu, L.t("Thoát", "Quit")) { NSApp.terminate(nil) }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private static func toggle2(_ m: NSMenu, _ title: String, _ key: String) {
        let d = UserDefaults.standard
        action(m, title, checked: d.bool(forKey: key)) { d.set(!d.bool(forKey: key), forKey: key) }
    }
}

// MARK: - Side panel window

final class SidePanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SidePanel {
    static let shared = SidePanel()
    private var panel: SidePanelWindow?
    private var bag = Set<AnyCancellable>()
    private weak var store: UsageStore?

    var currentTop: CGFloat { panel?.frame.maxY ?? 0 }

    /// Persistent id of the physical display, stable across launches (unlike NSScreen
    /// instances, which are recreated whenever the display setup changes).
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var selectedScreen: NSScreen? {
        guard let id = UserDefaults.standard.object(forKey: Pref.panelScreenID) as? Int else { return nil }
        return NSScreen.screens.first { Self.displayID(for: $0) == CGDirectDisplayID(id) }
    }

    private var screenFrame: NSRect {
        (selectedScreen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    }

    func install(store: UsageStore) {
        guard panel == nil else { return }
        self.store = store
        let p = SidePanelWindow(contentRect: .zero,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: SideWidgetView(store: store))
        panel = p
        applyLevel()
        layout()
        p.orderFrontRegardless()

        store.$limits.combineLatest(store.$accounts, store.$error).map { _ in UsageStore.shared.ringCount }.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.layout() } }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &bag)
    }

    func applyLevel() {
        let onTop = UserDefaults.standard.bool(forKey: Pref.alwaysOnTop)
        panel?.level = onTop
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    /// Size the window for the current number of rings and glue it to the right edge.
    func layout() {
        guard let panel else { return }
        let size = Layout.windowSize(count: store?.ringCount ?? 1)
        let s = screenFrame
        let saved = UserDefaults.standard.object(forKey: Pref.panelTop) as? Double
        let top = saved.map { CGFloat($0) } ?? (s.midY + size.height / 2 - 60)
        panel.setFrame(frame(size: size, top: top), display: true)
    }

    func moveTop(to top: CGFloat) {
        guard let panel else { return }
        panel.setFrame(frame(size: panel.frame.size, top: top), display: true)
    }

    func saveTop() {
        guard let panel else { return }
        UserDefaults.standard.set(Double(panel.frame.maxY), forKey: Pref.panelTop)
    }

    private func frame(size: CGSize, top: CGFloat) -> NSRect {
        let s = screenFrame
        let clampedTop = min(s.maxY, max(s.minY + size.height, top))
        return NSRect(x: s.maxX - size.width, y: clampedTop - size.height,
                      width: size.width, height: size.height)
    }
}

// MARK: - Menu bar popover

struct MenuPanel: View {
    @ObservedObject var store: UsageStore
    @AppStorage(Pref.language) private var langRaw = Lang.vi.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI usage").font(.system(size: 13, weight: .bold))
            ForEach([store.error].compactMap { $0 }, id: \.self) { e in
                Text(e).font(.system(size: 11)).foregroundStyle(.red)
            }
            ForEach(store.limits) { l in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(displayTitle(l)).font(.system(size: 12))
                        Spacer()
                        Text(L.t("dùng \(Int(l.used.rounded()))% · \(countdown(to: l.resetsAt))",
                                 "\(Int(l.used.rounded()))% used · \(countdown(to: l.resetsAt))"))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(severityColor(used: l.used))
                    }
                    Text(L.t("Reset lúc \(resetClock(l.resetsAt))", "Resets at \(resetClock(l.resetsAt))"))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let f = store.forecasts[l.kind], let text = forecastText(f) {
                        Text(text)
                            .font(.system(size: 10))
                            .foregroundStyle(f.hitsBeforeReset ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(store.accounts) { u in
                Divider()
                Text(accountTooltip(u).split(separator: "\n").dropLast().joined(separator: "\n"))
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let u = store.update {
                Button(L.t("⬆︎ Có bản mới v\(u.version) — Tải về", "⬆︎ v\(u.version) available — Download")) {
                    NSWorkspace.shared.open(u.url)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            Divider()
            HStack {
                Button(L.t("Biểu đồ", "Chart")) { ChartWindow.show() }
                Button(L.t("Làm mới", "Refresh")) { store.refresh() }
                Spacer()
                Button(L.t("Thoát", "Quit")) { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - Notifications

@MainActor
enum Notifier {
    /// Ad-hoc signed builds can be refused by UserNotifications; fall back to AppleScript then.
    private static var useFallback = false

    static func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = NotificationDelegate.shared
        c.requestAuthorization(options: [.alert, .sound]) { _, error in
            if error != nil { Task { @MainActor in useFallback = true } }
        }
    }

    static func post(_ title: String, _ body: String, url: URL? = nil) {
        if useFallback { fallback(title, body); return }
        let c = UNUserNotificationCenter.current()
        c.getNotificationSettings { settings in
            // Respect an explicit "off" in System Settings.
            guard settings.authorizationStatus != .denied else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let url { content.userInfo = ["url": url.absoluteString] }
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req) { error in
                if error != nil {
                    Task { @MainActor in
                        useFallback = true
                        fallback(title, body)
                    }
                }
            }
        }
    }

    private static func fallback(_ title: String, _ body: String) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"AiUsage\" subtitle \"\(esc(title))\""]
        try? p.run()
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if L.current == .vi {
        if h > 0 { return "\(h)g \(m)p" }
        return m > 0 ? "\(m)p \(sec)s" : "\(sec)s"
    }
    if h > 0 { return "\(h)h \(m)m" }
    return m > 0 ? "\(m)m \(sec)s" : "\(sec)s"
}

// MARK: - Limit watcher & forecast

struct AppUpdate: Equatable {
    let version: String
    let url: URL
}

struct Forecast: Equatable {
    let ratePerHour: Double     // percentage points per hour
    let hitAt: Date?            // when usage would reach 100% at this pace
    let resetsAt: Date?
    var hitsBeforeReset: Bool {
        guard let hitAt else { return false }
        return resetsAt.map { hitAt < $0 } ?? true
    }
}

/// "HH:mm" in GMT+7, adding the weekday/date when it isn't today.
func clockShort(_ date: Date) -> String {
    let tz = TimeZone(secondsFromGMT: 7 * 3600)!
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let f = DateFormatter()
    f.locale = Locale(identifier: L.current == .vi ? "vi_VN" : "en_US")
    f.timeZone = tz
    f.dateFormat = cal.isDate(date, inSameDayAs: Date()) ? "HH:mm" : "HH:mm EEE dd/MM"
    return f.string(from: date)
}

func forecastText(_ f: Forecast?) -> String? {
    guard let f else { return nil }
    guard f.ratePerHour > 0 else { return L.t("Tốc độ: chưa tăng gần đây", "Pace: flat recently") }
    let rate = String(format: "%.1f", f.ratePerHour)
    if f.hitsBeforeReset, let hit = f.hitAt {
        let early = f.resetsAt.map { countdown(to: $0, now: hit) }
        return L.t("⚠︎ Tốc độ ~\(rate)%/giờ → chạm 100% lúc \(clockShort(hit))" + (early.map { ", trước reset \($0)" } ?? ""),
                   "⚠︎ Pace ~\(rate)%/h → hits 100% at \(clockShort(hit))" + (early.map { ", \($0) before reset" } ?? ""))
    }
    return L.t("Tốc độ ~\(rate)%/giờ — đủ dùng đến lúc reset", "Pace ~\(rate)%/h — lasts until reset")
}

/// Tracks each limit across polls: threshold/reset notifications and pace forecast.
/// State survives restarts so the same alert isn't sent twice in one window.
@MainActor
final class LimitWatcher {
    private struct Sample: Codable { let t: Date; let used: Double }
    private struct Track: Codable {
        var window: String          // identifies the current reset window
        var samples: [Sample] = []
        var flags = 0               // 1 = 80% sent, 2 = 95% sent, 4 = early warning sent
        var lastUsed: Double
    }

    private let storeKey = "limitWatcher"
    private var tracks: [String: Track]

    init() {
        tracks = (UserDefaults.standard.data(forKey: storeKey))
            .flatMap { try? JSONDecoder().decode([String: Track].self, from: $0) } ?? [:]
    }

    private func save() {
        if let d = try? JSONEncoder().encode(tracks) { UserDefaults.standard.set(d, forKey: storeKey) }
    }

    /// resets_at carries sub-second noise between polls; bucket it to 10 minutes.
    private func windowID(_ l: Limit) -> String {
        l.resetsAt.map { String(Int(($0.timeIntervalSince1970 / 600).rounded())) } ?? "none"
    }

    func ingest(_ l: Limit, account: ClaudeAccount? = nil) -> Forecast? {
        let d = UserDefaults.standard
        let key = (account.map { $0.service + "|" } ?? "") + l.kind.rawValue
        let win = windowID(l)
        let now = Date()
        let title = (account.map { $0.label + " · " } ?? "") + displayTitle(l)
        var t = tracks[key] ?? Track(window: win, lastUsed: l.used)

        if t.window != win {
            // New window. If it was fairly used and dropped, tell the user they can go again.
            if t.lastUsed >= 50, l.used < t.lastUsed - 10, d.bool(forKey: Pref.notifyReset) {
                Notifier.post(L.t("🔄 \(title) đã reset", "🔄 \(title) has reset"),
                              L.t("Giờ còn \(Int(l.remaining.rounded()))% — dùng tiếp được rồi.",
                                  "\(Int(l.remaining.rounded()))% available again — you're good to go."))
            }
            t = Track(window: win, lastUsed: l.used)
        }

        if d.bool(forKey: Pref.notifyLimits) {
            let resetInfo = l.resetsAt.map {
                L.t("Reset sau \(countdown(to: $0)) — lúc \(resetClock($0))", "Resets in \(countdown(to: $0)) — at \(resetClock($0))")
            } ?? ""
            if l.used >= 95, t.flags & 2 == 0 {
                t.flags |= 3
                Notifier.post(L.t("🔴 \(title): đã dùng \(Int(l.used.rounded()))%", "🔴 \(title): \(Int(l.used.rounded()))% used"),
                              resetInfo)
            } else if l.used >= 80, t.flags & 1 == 0 {
                t.flags |= 1
                Notifier.post(L.t("🟠 \(title): đã dùng \(Int(l.used.rounded()))%", "🟠 \(title): \(Int(l.used.rounded()))% used"),
                              resetInfo)
            }
        }

        t.samples.append(Sample(t: now, used: l.used))
        let keep: TimeInterval = l.kind == .fiveHour ? 6 * 3600 : 3 * 86400
        t.samples.removeAll { now.timeIntervalSince($0.t) > keep }
        if t.samples.count > 400 { t.samples.removeFirst(t.samples.count - 400) }
        t.lastUsed = l.used

        let f = forecast(t, l, now: now)
        if let f, f.hitsBeforeReset, let hit = f.hitAt, l.used >= 50, l.used < 95,
           t.flags & 4 == 0, d.bool(forKey: Pref.notifyForecast) {
            t.flags |= 4
            let early = l.resetsAt.map { countdown(to: $0, now: hit) } ?? "—"
            Notifier.post(L.t("⏳ \(title) sắp hết", "⏳ \(title) running out"),
                          L.t("Với tốc độ hiện tại sẽ chạm 100% lúc \(clockShort(hit)), trước reset \(early). Nên chậm lại hoặc dùng model nhẹ hơn.",
                              "At this pace you'll hit 100% at \(clockShort(hit)), \(early) before reset. Consider slowing down or a lighter model."))
        }

        tracks[key] = t
        save()
        return f
    }

    /// Pace = change over a recent lookback (1 h for the 5-hour limit, 24 h for weekly/monthly).
    /// Needs a minimum span so a single jump doesn't produce a wild estimate.
    private func forecast(_ t: Track, _ l: Limit, now: Date) -> Forecast? {
        let short = l.kind == .fiveHour
        let lookback: TimeInterval = short ? 3600 : 86400
        let minSpan: TimeInterval = short ? 15 * 60 : 2 * 3600
        guard let last = t.samples.last,
              let first = t.samples.first(where: { now.timeIntervalSince($0.t) <= lookback })
        else { return nil }
        let span = last.t.timeIntervalSince(first.t)
        guard span >= minSpan else { return nil }
        let rate = (last.used - first.used) / span * 3600
        guard rate > 0.05 else { return Forecast(ratePerHour: 0, hitAt: nil, resetsAt: l.resetsAt) }
        let hit = now.addingTimeInterval(max(0, 100 - l.used) / rate * 3600)
        return Forecast(ratePerHour: rate, hitAt: hit, resetsAt: l.resetsAt)
    }
}

// MARK: - Launch at login

@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L.t("Không bật được tự chạy khi mở máy", "Couldn't change Launch at login")
            alert.informativeText = L.t("Hãy chắc app nằm trong thư mục Applications. Lỗi: \(error.localizedDescription)",
                                        "Make sure the app is in the Applications folder. Error: \(error.localizedDescription)")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

// MARK: - Token history (chart)

/// Hourly token totals across every Claude Code profile, built from the transcripts.
/// Scans incrementally (byte offsets per file), so reopening the chart is instant.
final class TokenHistory: @unchecked Sendable {
    static let shared = TokenHistory()

    struct Bucket: Equatable {
        var total = 0          // input + output + cache write + cache read
        var noCacheRead = 0    // input + output + cache write
    }

    private let queue = DispatchQueue(label: "token-history")
    private var offsets: [String: UInt64] = [:]
    private var seen = Set<String>()
    private var buckets: [Int: Bucket] = [:]      // key: Unix hour (seconds / 3600)
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let usageMarker = Data("\"usage\"".utf8)

    func scan(days: Int = 190) -> [Int: Bucket] {
        queue.sync {
            let since = Date().addingTimeInterval(-Double(days) * 86400)
            for base in UsageStore.configDirs {
                let root = URL(fileURLWithPath: base + "/projects")
                guard let en = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
                for case let url as URL in en where url.pathExtension == "jsonl" {
                    guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                          let mod = v.contentModificationDate, mod >= since,
                          let size = v.fileSize else { continue }
                    var offset = offsets[url.path] ?? 0
                    if UInt64(size) < offset { offset = 0 }
                    guard UInt64(size) > offset, let fh = try? FileHandle(forReadingFrom: url) else { continue }
                    defer { try? fh.close() }
                    try? fh.seek(toOffset: offset)
                    guard let data = try? fh.readToEnd(), let lastNL = data.lastIndex(of: 0x0A) else { continue }
                    offsets[url.path] = offset + UInt64(lastNL + 1)
                    for line in data[..<lastNL].split(separator: 0x0A) { ingest(line, since: since) }
                }
            }
            return buckets
        }
    }

    private func ingest(_ line: Data.SubSequence, since: Date) {
        guard line.range(of: Self.usageMarker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any],
              let ts = (obj["timestamp"] as? String).flatMap(iso.date(from:)), ts >= since
        else { return }
        let key = "\(msg["id"] as? String ?? "")|\(obj["requestId"] as? String ?? "")"
        guard seen.insert(key).inserted else { return }
        func n(_ k: String) -> Int { (u[k] as? Int) ?? 0 }
        let noCache = n("input_tokens") + n("output_tokens") + n("cache_creation_input_tokens")
        let hour = Int(ts.timeIntervalSince1970 / 3600)
        buckets[hour, default: Bucket()].noCacheRead += noCache
        buckets[hour, default: Bucket()].total += noCache + n("cache_read_input_tokens")
    }
}

@MainActor
final class ChartModel: ObservableObject {
    static let shared = ChartModel()
    @Published var buckets: [Int: TokenHistory.Bucket] = [:]
    @Published var loading = false
    @Published var loaded = false

    func load() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let b = TokenHistory.shared.scan()
            await MainActor.run {
                self.buckets = b
                self.loading = false
                self.loaded = true
            }
        }
    }
}

/// GMT+7 calendar, matching the reset times shown elsewhere.
let gmt7: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
    c.firstWeekday = 2   // Monday
    return c
}()

func weekdayShort(_ date: Date) -> String {
    let w = gmt7.component(.weekday, from: date)   // 1 = Sunday
    if L.current == .vi { return w == 1 ? "CN" : "T\(w)" }
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][w - 1]
}

func dayMonth(_ date: Date) -> String {
    let c = gmt7.dateComponents([.day, .month], from: date)
    return String(format: "%02d/%02d", c.day ?? 0, c.month ?? 0)
}

/// GitHub-style palette: level 0 = empty, 1…4 = more usage.
struct HeatPalette {
    let dark: Bool
    func color(_ level: Int) -> Color {
        let light = ["ebedf0", "9be9a8", "40c463", "30a14e", "216e39"]
        let night = ["1f242c", "0e4429", "006d32", "26a641", "39d353"]
        return Color(hex: (dark ? night : light)[max(0, min(4, level))])
    }
}

extension Color {
    init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Quartile thresholds over non-zero values, like GitHub's contribution graph.
func heatThresholds(_ values: [Int]) -> [Int] {
    let nz = values.filter { $0 > 0 }.sorted()
    guard !nz.isEmpty else { return [1, 1, 1] }
    func q(_ p: Double) -> Int { nz[min(nz.count - 1, Int(Double(nz.count - 1) * p))] }
    return [q(0.25), q(0.5), q(0.75)]
}

func heatLevel(_ v: Int, _ t: [Int]) -> Int {
    if v <= 0 { return 0 }
    if v <= t[0] { return 1 }
    if v <= t[1] { return 2 }
    if v <= t[2] { return 3 }
    return 4
}

struct TokenChartView: View {
    @ObservedObject var model = ChartModel.shared
    @Environment(\.colorScheme) private var scheme
    @AppStorage("chartMode") private var mode = 0          // 0 = by hour, 1 = by day
    @AppStorage("chartNoCache") private var noCache = false
    @AppStorage(Pref.language) private var langRaw = Lang.vi.rawValue

    // GitHub contribution graph proportions: 10 px squares, 3 px gaps.
    private let cell: CGFloat = 10
    private let gap: CGFloat = 3
    private let hourDays = 14
    private let calendarWeeks = 26
    private let labelWidth: CGFloat = 50

    private func value(_ b: TokenHistory.Bucket?) -> Int {
        guard let b else { return 0 }
        return noCache ? b.noCacheRead : b.total
    }

    private var todayStart: Date { gmt7.startOfDay(for: Date()) }

    private func dayTotal(_ day: Date) -> Int {
        let h0 = Int(day.timeIntervalSince1970 / 3600)
        return (0..<24).reduce(0) { $0 + value(model.buckets[h0 + $1]) }
    }

    private var caption: Font { .system(size: 9) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: $mode) {
                    Text(L.t("Theo giờ", "By hour")).tag(0)
                    Text(L.t("Theo ngày", "By day")).tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Toggle(L.t("Bỏ cache đọc", "No cache reads"), isOn: $noCache)
                    .toggleStyle(.checkbox)
                    .help(L.t("Cache đọc chiếm phần lớn token nhưng rẻ hơn nhiều. Bỏ đi để thấy mức dùng \"thật\".",
                              "Cache reads are most tokens but much cheaper. Exclude them to see \"real\" usage."))
                Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(model.loading)
            }
            .controlSize(.small)
            .font(.system(size: 11))

            if !model.loaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L.t("Đang đọc lịch sử…", "Reading history…")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 190)
            } else if mode == 0 {
                hourGrid
            } else {
                dayGrid
            }
        }
        .padding(14)
        .fixedSize()
        .onAppear { model.load() }
    }

    private func square(_ level: Int, _ pal: HeatPalette) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(pal.color(level))
            .frame(width: cell, height: cell)
    }

    // MARK: By hour — rows = days, columns = hours

    private var hourGrid: some View {
        let days = (0..<hourDays).reversed().map { gmt7.date(byAdding: .day, value: -$0, to: todayStart)! }
        let values = days.flatMap { d -> [Int] in
            let h0 = Int(d.timeIntervalSince1970 / 3600)
            return (0..<24).map { value(model.buckets[h0 + $0]) }
        }
        let t = heatThresholds(values)
        let pal = HeatPalette(dark: scheme == .dark)
        var hourSums = [Int](repeating: 0, count: 24)
        for (i, v) in values.enumerated() { hourSums[i % 24] += v }
        let peakHour = hourSums.indices.max { hourSums[$0] < hourSums[$1] } ?? 0
        let total = values.reduce(0, +)

        return VStack(alignment: .leading, spacing: 6) {
            Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                GridRow {
                    Color.clear.frame(width: labelWidth, height: 10)
                    ForEach(0..<24, id: \.self) { h in
                        Text(h % 6 == 0 ? "\(h)h" : "")
                            .font(caption).foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: cell, alignment: .leading)
                    }
                    Color.clear.frame(width: 1, height: 1)
                }
                ForEach(days, id: \.self) { d in
                    let h0 = Int(d.timeIntervalSince1970 / 3600)
                    GridRow {
                        Text("\(weekdayShort(d)) \(dayMonth(d))")
                            .font(caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: labelWidth, alignment: .leading)
                        ForEach(0..<24, id: \.self) { h in
                            let v = value(model.buckets[h0 + h])
                            square(heatLevel(v, t), pal)
                                .help("\(weekdayShort(d)) \(dayMonth(d)) · \(String(format: "%02d:00–%02d:00", h, (h + 1) % 24))\n\(formatTokens(v)) token")
                        }
                        Text(formatTokens(dayTotal(d)))
                            .font(caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
            footer(pal, L.t("14 ngày: \(formatTokens(total)) · cao điểm \(peakHour)h",
                            "14 days: \(formatTokens(total)) · peak \(peakHour)h"))
        }
    }

    // MARK: By day — GitHub contribution calendar

    private var dayGrid: some View {
        let thisMonday = gmt7.dateInterval(of: .weekOfYear, for: Date())?.start ?? todayStart
        let start = gmt7.date(byAdding: .weekOfYear, value: -(calendarWeeks - 1), to: thisMonday)!
        let weeks: [[Date]] = (0..<calendarWeeks).map { w in
            (0..<7).map { gmt7.date(byAdding: .day, value: w * 7 + $0, to: start)! }
        }
        let allDays = weeks.flatMap { $0 }.filter { $0 <= todayStart }
        let totals = Dictionary(uniqueKeysWithValues: allDays.map { ($0, dayTotal($0)) })
        let t = heatThresholds(Array(totals.values))
        let pal = HeatPalette(dark: scheme == .dark)
        let sum = totals.values.reduce(0, +)
        let active = totals.values.filter { $0 > 0 }.count
        let rowLabels = L.current == .vi ? ["T2", "", "T4", "", "T6", "", "CN"] : ["Mon", "", "Wed", "", "Fri", "", "Sun"]

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: gap) {
                VStack(alignment: .leading, spacing: gap) {
                    Color.clear.frame(width: 1, height: 10)
                    ForEach(0..<7, id: \.self) { i in
                        Text(rowLabels[i]).font(caption).foregroundStyle(.secondary).frame(height: cell)
                    }
                }
                .frame(width: 22, alignment: .leading)
                ForEach(weeks.indices, id: \.self) { w in
                    VStack(spacing: gap) {
                        let first = weeks[w][0]
                        let showMonth = w == 0 || gmt7.component(.month, from: first) != gmt7.component(.month, from: weeks[w - 1][0])
                        Text(showMonth ? monthLabel(first) : "")
                            .font(caption).foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: cell, height: 10, alignment: .leading)
                        ForEach(weeks[w], id: \.self) { d in
                            if d > todayStart {
                                Color.clear.frame(width: cell, height: cell)
                            } else {
                                let v = totals[d] ?? 0
                                square(heatLevel(v, t), pal)
                                    .help("\(weekdayShort(d)) \(dayMonth(d))\n\(formatTokens(v)) token")
                            }
                        }
                    }
                }
            }
            footer(pal, L.t("6 tháng: \(formatTokens(sum)) · \(active) ngày có dùng",
                            "6 months: \(formatTokens(sum)) · \(active) active days"))
        }
    }

    private func monthLabel(_ d: Date) -> String {
        let m = gmt7.component(.month, from: d)
        return L.current == .vi ? "Th\(m)" : ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][m - 1]
    }

    private func footer(_ pal: HeatPalette, _ summary: String) -> some View {
        HStack(spacing: 3) {
            Text(summary).font(caption).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(L.t("Ít", "Less")).font(caption).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { square($0, pal) }
            Text(L.t("Nhiều", "More")).font(caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
enum ChartWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = L.t("Token Claude Code", "Claude Code tokens")
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: TokenChartView())
            host.sizingOptions = [.preferredContentSize]    // window follows the content size
            w.contentView = host
            w.center()
            window = w
        }
        ChartModel.shared.load()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated {
            SidePanel.shared.install(store: .shared)
            Notifier.setup()
            UsageStore.shared.startUpdateChecks()
        }
    }
}

@main
enum Main {
    static func main() {
        // Claude Code runs us as its status line; handle that before any UI starts.
        if CommandLine.arguments.contains("--statusline") { Bridge.runStatusLine() }
        if CommandLine.arguments.contains("--install-statusline") {
            for (dir, st) in Bridge.installAll() { print(dir, st) }
            exit(0)
        }
        AiUsageApp.main()
    }
}

struct AiUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = UsageStore.shared
    @AppStorage(Pref.showMenuBar) private var showMenuBar = true

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Self.migrateOldDefaults()
        UserDefaults.standard.register(defaults: [
            Pref.alwaysOnTop: true,
            Pref.showMenuBar: true,
            Pref.showRemaining: false,
            Pref.showTasks: true,
            Pref.showTokens: true,
            Pref.language: Lang.vi.rawValue,
            Pref.notifyLimits: true,
            Pref.notifyReset: true,
            Pref.notifyForecast: true,
            Pref.notifyTasks: true,
        ])
    }

    /// The app used to be "ClaudeUsage" (bundle id local.claude-usage-widget);
    /// carry its settings, widget position and cached limits over once.
    static func migrateOldDefaults() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromClaudeUsage"),
              let old = UserDefaults(suiteName: "local.claude-usage-widget")?
                .persistentDomain(forName: "local.claude-usage-widget") else { return }
        for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k) }
        d.set(true, forKey: "migratedFromClaudeUsage")
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBar) {
            MenuPanel(store: store)
        } label: {
            let label = store.error != nil ? "!" : store.fiveHour.map { "\(Int($0.used.rounded()))%" } ?? "…"
            HStack(spacing: 3) {
                Image(systemName: "sparkle")
                Text(label).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
