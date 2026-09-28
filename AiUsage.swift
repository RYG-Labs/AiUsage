import SwiftUI
import AppKit
import Combine
import Security

// MARK: - Model

struct UsageWindow: Decodable {
    let utilization: Double?
    let resets_at: String?
}

struct UsageResponse: Decodable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let seven_day_opus: UsageWindow?
    let seven_day_sonnet: UsageWindow?
}

struct ClaudeSession: Equatable {
    let pid: Int
    let name: String
    let status: String
    var isBusy: Bool { status == "busy" }
}

enum LimitKind: String, Codable { case fiveHour, week, opus, sonnet, cursor }

struct Limit: Identifiable, Codable {
    let kind: LimitKind
    let title: String
    let used: Double          // 0...100
    let resetsAt: Date?
    var id: String { kind.rawValue }
    var remaining: Double { max(0, 100 - used) }
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    @Published var limits: [Limit] = []
    @Published var error: String?
    @Published var cursorError: String?
    @Published var lastUpdate: Date?
    @Published var loading = false
    @Published var sessions: [ClaudeSession] = []
    @Published var tokens = TokenTotals()

    private let tokenCounter = TokenCounter()
    private var tokenTimer: Timer?

    private var sessionTimer: Timer?
    private var claudeLimits: [Limit] = UsageStore.loadCachedClaude()
    private var claudeNextAttempt = Date.distantPast
    private var claudeBackoff: TimeInterval = 0
    private var cursorLimits: [Limit] = []
    private var timer: Timer?
    let interval: TimeInterval = 90

    init() {
        recompose()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshTokens()
        tokenTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTokens() }
        }
        refreshSessions()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSessions() }
        }
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
        let dir = NSHomeDirectory() + "/.claude/sessions"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var out: [ClaudeSession] = []
        for f in files where f.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) == 0
            else { continue }
            let cwd = obj["cwd"] as? String ?? ""
            let name = (obj["name"] as? String) ?? (cwd as NSString).lastPathComponent
            out.append(ClaudeSession(pid: pid, name: name, status: obj["status"] as? String ?? "unknown"))
        }
        out.sort { $0.pid < $1.pid }
        if out != sessions { sessions = out }
    }

    var fiveHour: Limit? { limits.first { $0.kind == .fiveHour } }

    /// Rebuild the visible list (Claude first, then Cursor if enabled).
    func recompose() {
        let showCursor = UserDefaults.standard.bool(forKey: Pref.showCursor)
        limits = claudeLimits + (showCursor ? cursorLimits : [])
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            defer { loading = false }
            let tryClaude = Date() >= claudeNextAttempt
            async let claude = tryClaude ? Result(catching: { try await Self.fetchClaude() }) : nil
            async let cursor = Result(catching: { try await Self.fetchCursor() })

            switch await claude {
            case .success(let l)?:
                claudeLimits = l; error = nil; claudeBackoff = 0
                Self.saveCachedClaude(l)
            case .failure(let e)?:
                // Keep showing the last known numbers; back off when rate limited.
                if case .rateLimited = e as? WidgetError {
                    claudeBackoff = min(900, max(120, claudeBackoff * 2))
                    claudeNextAttempt = Date().addingTimeInterval(claudeBackoff)
                    error = "Claude API tạm giới hạn tần suất — hiển thị số cũ, thử lại sau \(Int(claudeBackoff / 60)) phút"
                } else {
                    error = (e as? WidgetError)?.text ?? e.localizedDescription
                }
            case nil: break
            }
            switch await cursor {
            case .success(let l): cursorLimits = l; cursorError = nil
            case .failure(let e): cursorError = (e as? WidgetError)?.text ?? e.localizedDescription
            }
            recompose()
            lastUpdate = Date()
        }
    }

    enum WidgetError: Error {
        case msg(String)
        case rateLimited
        var text: String {
            switch self {
            case .msg(let s): return s
            case .rateLimited: return "Bị giới hạn tần suất (HTTP 429)"
            }
        }
    }

    nonisolated static let cacheKey = "cachedClaudeLimits"

    nonisolated static func loadCachedClaude() -> [Limit] {
        guard let d = UserDefaults.standard.data(forKey: cacheKey),
              let l = try? JSONDecoder().decode([Limit].self, from: d) else { return [] }
        return l
    }

    nonisolated static func saveCachedClaude(_ l: [Limit]) {
        if let d = try? JSONEncoder().encode(l) { UserDefaults.standard.set(d, forKey: cacheKey) }
    }

    // MARK: Claude

    nonisolated static func fetchClaude() async throws -> [Limit] {
        let token = try readClaudeToken()
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("aiusage/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            throw WidgetError.msg("Token hết hạn — mở Claude Code một lần để làm mới")
        }
        if code == 429 { throw WidgetError.rateLimited }
        guard code == 200 else { throw WidgetError.msg("Claude: HTTP \(code)") }
        let r = try JSONDecoder().decode(UsageResponse.self, from: data)
        var out: [Limit] = []
        func add(_ kind: LimitKind, _ title: String, _ w: UsageWindow?) {
            guard let w, let u = w.utilization else { return }
            out.append(Limit(kind: kind, title: title, used: u, resetsAt: w.resets_at.flatMap(parseDate)))
        }
        add(.fiveHour, "Phiên 5 giờ", r.five_hour)
        add(.week, "Tuần (7 ngày)", r.seven_day)
        add(.opus, "Tuần — Opus", r.seven_day_opus)
        add(.sonnet, "Tuần — Sonnet", r.seven_day_sonnet)
        return out
    }

    /// Reads the OAuth token Claude Code stores in the login Keychain.
    ///
    /// Switching Claude accounts can leave more than one item under this service name
    /// (the CLI adds a fresh entry per account instead of always overwriting in place),
    /// and `security find-generic-password` only ever returns a single arbitrary match.
    /// Querying via the Security framework directly lets us fetch every match and pick
    /// the one most recently written, so a newly logged-in account is picked up right away.
    nonisolated static func readClaudeToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]], !items.isEmpty
        else { throw WidgetError.msg("Không đọc được token Claude Code trong Keychain") }

        let newest = items.max { a, b in
            let da = a[kSecAttrModificationDate as String] as? Date ?? .distantPast
            let db = b[kSecAttrModificationDate as String] as? Date ?? .distantPast
            return da < db
        }
        guard let data = newest?[kSecValueData as String] as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw WidgetError.msg("Không đọc được token Claude Code trong Keychain") }
        return token
    }

    // MARK: Cursor

    nonisolated static let cursorDB = NSHomeDirectory()
        + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

    /// Returns [] when Cursor is not installed / not logged in, so it simply doesn't show.
    nonisolated static func fetchCursor() async throws -> [Limit] {
        guard FileManager.default.fileExists(atPath: cursorDB) else { return [] }
        guard let raw = run("/usr/bin/sqlite3", ["-readonly", cursorDB,
                "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'"]),
              let token = String(data: raw, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        else { return [] }
        guard let userId = jwtUserId(token) else {
            throw WidgetError.msg("Cursor: token không hợp lệ")
        }
        let cookie = "WorkosCursorSessionToken=\(userId)%3A%3A\(token)"

        func get(_ url: String) async throws -> [String: Any] {
            var req = URLRequest(url: URL(string: url)!)
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            req.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
            req.setValue("Mozilla/5.0 aiusage/1.0", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                throw WidgetError.msg("Cursor: phiên đăng nhập hết hạn — mở Cursor để đăng nhập lại")
            }
            guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw WidgetError.msg("Cursor: HTTP \(code)") }
            return obj
        }

        // New usage-based plans: percentage of the included plan usage this billing cycle.
        if let summary = try? await get("https://cursor.com/api/usage-summary"),
           let individual = summary["individualUsage"] as? [String: Any],
           let plan = individual["plan"] as? [String: Any] {
            let used: Double? = num(plan["totalPercentUsed"]) ?? {
                guard let u = num(plan["used"]), let l = num(plan["limit"]), l > 0 else { return nil }
                return u / l * 100
            }()
            if let used {
                let end = (summary["billingCycleEnd"] as? String).flatMap(parseDate)
                return [Limit(kind: .cursor, title: "Cursor (chu kỳ tháng)", used: min(100, used), resetsAt: end)]
            }
        }

        // Legacy request-based plans: fast requests used / max this month.
        let usage = try await get("https://cursor.com/api/usage?user=\(userId)")
        guard let gpt = usage["gpt-4"] as? [String: Any],
              let n = num(gpt["numRequests"]), let max = num(gpt["maxRequestUsage"]), max > 0
        else { throw WidgetError.msg("Cursor: không đọc được dữ liệu usage") }
        let start = (usage["startOfMonth"] as? String).flatMap(parseDate)
        let end = start.flatMap { Calendar.current.date(byAdding: .month, value: 1, to: $0) }
        return [Limit(kind: .cursor, title: "Cursor (\(Int(n))/\(Int(max)) request)", used: min(100, n / max * 100), resetsAt: end)]
    }

    /// Cursor JWT `sub` looks like "auth0|user_XXXX"; the cookie needs the part after "|".
    nonisolated static func jwtUserId(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sub = obj["sub"] as? String else { return nil }
        return sub.split(separator: "|").last.map(String.init)
    }

    // MARK: Helpers

    nonisolated static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    nonisolated static func run(_ exe: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    nonisolated static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

// MARK: - Settings

enum Pref {
    static let showRemaining = "showRemaining"
    static let alwaysOnTop = "alwaysOnTop"
    static let showMenuBar = "showMenuBar"
    static let panelTop = "panelTop"
    static let showCursor = "showCursor"
    static let showTasks = "showTasks"
    static let showTokens = "showTokens"
}

/// Absolute reset time in GMT+7, e.g. "21:10 T2 28/09 (GMT+7)".
func resetClock(_ date: Date?) -> String {
    guard let date else { return "—" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "vi_VN")
    f.timeZone = TimeZone(secondsFromGMT: 7 * 3600)
    f.dateFormat = "HH:mm EEE dd/MM"
    return f.string(from: date) + " (GMT+7)"
}

func countdown(to date: Date?, now: Date = .now) -> String {
    guard let date else { return "—" }
    let s = Int(date.timeIntervalSince(now))
    if s <= 0 { return "đang reset" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)n \(h)g" }
    if h > 0 { return "\(h)g \(m)p" }
    return "\(m)p"
}

/// Claude brand orange.
let claudeOrange = Color(red: 0.851, green: 0.467, blue: 0.341)

/// Running-task badge green.
let runningGreen = Color(red: 0.20, green: 0.78, blue: 0.35)

/// Cursor ring: soft white, like its monochrome brand.
let cursorWhite = Color(white: 0.92)

func ringColor(_ kind: LimitKind) -> Color { kind == .cursor ? cursorWhite : claudeOrange }

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

/// Cursor-style mark: hexagonal cube with one shaded facet.
struct CursorMark: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let c = CGPoint(x: w / 2, y: h / 2)
            let top = CGPoint(x: w / 2, y: 0), bot = CGPoint(x: w / 2, y: h)
            let tl = CGPoint(x: w * 0.07, y: h * 0.25), bl = CGPoint(x: w * 0.07, y: h * 0.75)
            let tr = CGPoint(x: w * 0.93, y: h * 0.25), br = CGPoint(x: w * 0.93, y: h * 0.75)
            var hex = Path()
            hex.addLines([top, tr, br, bot, bl, tl]); hex.closeSubpath()
            ctx.fill(hex, with: .color(.white.opacity(0.35)))
            var facet = Path()
            facet.addLines([tl, tr, c]); facet.closeSubpath()
            ctx.fill(facet, with: .color(.white))
            var edges = Path()
            edges.move(to: c); edges.addLine(to: bot)
            ctx.stroke(hex, with: .color(.white), lineWidth: 1)
            ctx.stroke(edges, with: .color(.white), lineWidth: 1)
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
        case .cursor: CursorMark().frame(width: 12, height: 12)
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
        .help("\(limit.title)\nĐã dùng \(Int(limit.used.rounded()))% · còn \(Int(limit.remaining.rounded()))%\nReset sau \(countdown(to: limit.resetsAt)) — lúc \(resetClock(limit.resetsAt))\n(Bấm để mở cài đặt, kéo để di chuyển)")
    }
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
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return totals }
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
        let speed: Float = intense ? 1.7 : 0.8
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
        .help("""
            Token Claude Code hôm nay (máy này)
            Tổng: \(tokens.total.formatted())
            • Input: \(tokens.input.formatted())
            • Output: \(tokens.output.formatted())
            • Cache ghi: \(tokens.cacheWrite.formatted())
            • Cache đọc: \(tokens.cacheRead.formatted())
            \(tokens.messages) lượt trả lời
            """)
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
              ? "Claude Code đang chạy \(running.count) task:\n" + running.map { "• \($0.name)" }.joined(separator: "\n")
              : "Không có task Claude Code nào đang chạy (\(store.sessions.count) phiên đang mở)")
    }
}

// MARK: - Side widget view

struct SideWidgetView: View {
    @ObservedObject var store: UsageStore
    @AppStorage(Pref.showRemaining) private var showRemaining = false
    @AppStorage(Pref.showTasks) private var showTasks = true
    @AppStorage(Pref.showTokens) private var showTokens = true
    @State private var dragStart: (mouseY: CGFloat, top: CGFloat)?

    var body: some View {
        let count = max(1, store.limits.count)
        let shape = SideTabShape(shoulder: Layout.shoulder, corner: Layout.corner)
        ZStack {
            shape.fill(Color.black)
            VStack(spacing: Layout.ringSpacing) {
                if showTasks { TaskBadge(store: store) }
                if showTokens { TokenBadge(tokens: store.tokens, active: !store.runningSessions.isEmpty) }
                if store.limits.isEmpty {
                    placeholder
                } else {
                    ForEach(store.limits) { RingGauge(limit: $0, showRemaining: showRemaining) }
                }
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
            Text(store.error == nil ? "…" : "lỗi")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                .frame(height: 11)
        }
        .help(store.error ?? "Đang tải…")
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

    static func show(store: UsageStore) {
        handlers.removeAll()
        let d = UserDefaults.standard
        let menu = NSMenu()
        func item(_ title: String, checked: Bool? = nil, _ action: @escaping () -> Void) {
            let h = Handler(action)
            handlers.append(h)
            let it = NSMenuItem(title: title, action: #selector(Handler.run), keyEquivalent: "")
            it.target = h
            if let checked { it.state = checked ? .on : .off }
            menu.addItem(it)
        }
        if let t = store.lastUpdate {
            let info = NSMenuItem(title: "Cập nhật lúc \(t.formatted(date: .omitted, time: .shortened))", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        for l in store.limits {
            let info = NSMenuItem(title: "\(l.title): dùng \(Int(l.used.rounded()))% · reset sau \(countdown(to: l.resetsAt)) — lúc \(resetClock(l.resetsAt))", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        let tk = store.tokens
        let tokItem = NSMenuItem(title: "Token hôm nay: \(formatTokens(tk.total)) (output \(formatTokens(tk.output)), cache đọc \(formatTokens(tk.cacheRead)))", action: nil, keyEquivalent: "")
        tokItem.isEnabled = false
        menu.addItem(tokItem)
        let running = store.runningSessions
        let head = NSMenuItem(title: "Claude Code: \(running.count) đang chạy · \(store.sessions.count - running.count) rảnh", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        for s in running {
            let it = NSMenuItem(title: "   ▶ \(s.name)", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        }
        for e in [store.error, store.cursorError].compactMap({ $0 }) {
            let info = NSMenuItem(title: "⚠︎ \(e)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())
        item("Làm mới") { store.refresh() }
        item("Hiển thị % còn lại", checked: d.bool(forKey: Pref.showRemaining)) {
            d.set(!d.bool(forKey: Pref.showRemaining), forKey: Pref.showRemaining)
        }
        item("Luôn nằm trên cửa sổ khác", checked: d.bool(forKey: Pref.alwaysOnTop)) {
            d.set(!d.bool(forKey: Pref.alwaysOnTop), forKey: Pref.alwaysOnTop)
            SidePanel.shared.applyLevel()
        }
        item("Hiện token hôm nay", checked: d.bool(forKey: Pref.showTokens)) {
            d.set(!d.bool(forKey: Pref.showTokens), forKey: Pref.showTokens)
            SidePanel.shared.layout()
        }
        item("Hiện số task đang chạy", checked: d.bool(forKey: Pref.showTasks)) {
            d.set(!d.bool(forKey: Pref.showTasks), forKey: Pref.showTasks)
            SidePanel.shared.layout()
        }
        item("Hiện Cursor", checked: d.bool(forKey: Pref.showCursor)) {
            d.set(!d.bool(forKey: Pref.showCursor), forKey: Pref.showCursor)
            store.recompose()
        }
        item("Hiện trên menu bar", checked: d.bool(forKey: Pref.showMenuBar)) {
            d.set(!d.bool(forKey: Pref.showMenuBar), forKey: Pref.showMenuBar)
        }
        menu.addItem(.separator())
        item("Thoát") { NSApp.terminate(nil) }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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

    private var screenFrame: NSRect { (NSScreen.main ?? NSScreen.screens[0]).visibleFrame }

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

        store.$limits.map(\.count).removeDuplicates()
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
        let size = Layout.windowSize(count: max(1, store?.limits.count ?? 1))
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
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI usage").font(.system(size: 13, weight: .bold))
            ForEach([store.error, store.cursorError].compactMap { $0 }, id: \.self) { e in
                Text(e).font(.system(size: 11)).foregroundStyle(.red)
            }
            ForEach(store.limits) { l in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(l.title).font(.system(size: 12))
                        Spacer()
                        Text("dùng \(Int(l.used.rounded()))% · \(countdown(to: l.resetsAt))")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(severityColor(used: l.used))
                    }
                    Text("Reset lúc \(resetClock(l.resetsAt))")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Button("Làm mới") { store.refresh() }
                Spacer()
                Button("Thoát") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated { SidePanel.shared.install(store: .shared) }
    }
}

@main
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
            Pref.showCursor: true,
            Pref.showTasks: true,
            Pref.showTokens: true,
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
            let label = store.fiveHour.map { "\(Int($0.used.rounded()))%" } ?? "…"
            HStack(spacing: 3) {
                Image(systemName: "sparkle")
                Text(label).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
