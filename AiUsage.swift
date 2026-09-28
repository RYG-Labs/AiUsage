import SwiftUI
import AppKit
import Combine
import Security
import CryptoKit
@preconcurrency import UserNotifications
import ServiceManagement

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

/// One Claude login. Claude Code keeps one Keychain item per config dir:
/// "Claude Code-credentials" for ~/.claude, and "Claude Code-credentials-<sha256(dir)[0:8]>"
/// for each CLAUDE_CONFIG_DIR profile.
struct ClaudeAccount: Equatable, Sendable {
    static let defaultService = "Claude Code-credentials"
    let service: String
    let configDir: String?
    let email: String?
    var isDefault: Bool { service == Self.defaultService }
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

enum LimitKind: String, Codable { case fiveHour, week, opus, sonnet, cursor }

struct Limit: Identifiable, Codable, Equatable {
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
    @Published var forecasts: [LimitKind: Forecast] = [:]
    @Published var update: AppUpdate?
    /// Signed-in account for ~/.claude (what the desktop app and plain `claude` use).
    @Published var defaultAccount: ClaudeAccount?
    /// Other CLAUDE_CONFIG_DIR profiles, each with its own limits.
    @Published var accounts: [AccountUsage] = []
    private var accountNextAttempt: [String: Date] = [:]
    private var accountBackoff: [String: TimeInterval] = [:]
    /// Config dirs to scan for sessions and transcripts (read from background threads).
    nonisolated(unsafe) static var configDirs: [String] = [NSHomeDirectory() + "/.claude"]

    let watcher = LimitWatcher()
    private var busySince: [Int: Date] = [:]
    private var sessionsPrimed = false
    private var updateTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

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
        // After the lid opens, refresh right away instead of waiting for the next tick.
        // Wait a few seconds so Wi-Fi can reconnect first.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
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
            let found = await Task.detached { Self.discoverAccounts() }.value
            let home = NSHomeDirectory() + "/.claude"
            let def = found.first(where: \.isDefault)
                ?? ClaudeAccount(service: ClaudeAccount.defaultService, configDir: home, email: Self.accountEmail(configDir: home))
            defaultAccount = def
            Self.configDirs = Array(Set([home] + found.compactMap(\.configDir))).sorted()
            let tryClaude = Date() >= claudeNextAttempt
            async let claude = tryClaude ? Result(catching: { try await Self.fetchClaude(def) }) : nil
            async let cursor = Result(catching: { try await Self.fetchCursor() })

            switch await claude {
            case .success(let l)?:
                claudeLimits = l; error = nil; claudeBackoff = 0
                Self.saveCachedClaude(l)
                for x in l { forecasts[x.kind] = watcher.ingest(x) }
            case .failure(let e)?:
                // Keep showing the last known numbers; back off when rate limited.
                if case .rateLimited = e as? WidgetError {
                    claudeBackoff = min(900, max(120, claudeBackoff * 2))
                    claudeNextAttempt = Date().addingTimeInterval(claudeBackoff)
                    let mins = Int(claudeBackoff / 60)
                    error = L.t("Claude API tạm giới hạn tần suất — hiển thị số cũ, thử lại sau \(mins) phút",
                                 "Claude API is rate-limited — showing last known numbers, retrying in \(mins) min")
                } else {
                    error = (e as? WidgetError)?.text ?? e.localizedDescription
                }
            case nil: break
            }
            switch await cursor {
            case .success(let l):
                cursorLimits = l; cursorError = nil
                for x in l { forecasts[x.kind] = watcher.ingest(x) }
            case .failure(let e): cursorError = (e as? WidgetError)?.text ?? e.localizedDescription
            }
            await refreshExtraAccounts(found.filter { !$0.isDefault })
            recompose()
            lastUpdate = Date()
        }
    }

    /// Fetches every non-default profile one after another, keeping the last good numbers
    /// on failure and backing off per account when rate-limited.
    private func refreshExtraAccounts(_ list: [ClaudeAccount]) async {
        var out: [AccountUsage] = []
        for acct in list {
            var u = accounts.first { $0.id == acct.service } ?? AccountUsage(account: acct)
            u = AccountUsage(account: acct, limits: u.limits, forecasts: u.forecasts, error: u.error)
            if Date() >= accountNextAttempt[acct.service] ?? .distantPast {
                do {
                    let l = try await Self.fetchClaude(acct)
                    u.limits = l
                    u.error = nil
                    accountBackoff[acct.service] = 0
                    for x in l { u.forecasts[x.kind] = watcher.ingest(x, account: acct) }
                } catch {
                    if case .rateLimited = error as? WidgetError {
                        let b = min(900, max(120, (accountBackoff[acct.service] ?? 0) * 2))
                        accountBackoff[acct.service] = b
                        accountNextAttempt[acct.service] = Date().addingTimeInterval(b)
                    }
                    u.error = (error as? WidgetError)?.text ?? error.localizedDescription
                }
            }
            out.append(u)
        }
        if out != accounts { accounts = out }
    }

    enum WidgetError: Error {
        case msg(String)
        case rateLimited
        var text: String {
            switch self {
            case .msg(let s): return s
            case .rateLimited: return L.t("Bị giới hạn tần suất (HTTP 429)", "Rate-limited (HTTP 429)")
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

    nonisolated static func fetchClaude(_ account: ClaudeAccount) async throws -> [Limit] {
        let token = try await claudeToken(for: account)
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("aiusage/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            throw WidgetError.msg(L.t("Token hết hạn — mở Claude Code bằng tài khoản này một lần để làm mới",
                                       "Token expired — open Claude Code with this account once to refresh it"))
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

    /// Reads the Claude Code credentials JSON for one Keychain service.
    ///
    /// Switching Claude accounts can leave more than one item under the same service name
    /// (the CLI adds a fresh entry per account instead of always overwriting in place),
    /// and `security find-generic-password` only ever returns a single arbitrary match.
    /// Querying via the Security framework lets us list every match and pick the one most
    /// recently written, so a newly logged-in account is picked up right away.
    nonisolated static func loadCreds(service: String) throws -> (ref: CFTypeRef, root: [String: Any]) {
        // Step 1: list attributes only (no secret material, so no Keychain prompt).
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
        ]
        let keychainError = L.t("Không đọc được token Claude Code trong Keychain",
                                 "Couldn't read the Claude Code token from the Keychain")
        var listResult: CFTypeRef?
        guard SecItemCopyMatching(listQuery as CFDictionary, &listResult) == errSecSuccess,
              let items = listResult as? [[String: Any]], !items.isEmpty
        else { throw WidgetError.msg(keychainError) }
        let newest = items.max { a, b in
            let da = a[kSecAttrModificationDate as String] as? Date ?? .distantPast
            let db = b[kSecAttrModificationDate as String] as? Date ?? .distantPast
            return da < db
        }
        guard let ref = newest?[kSecValuePersistentRef as String] else { throw WidgetError.msg(keychainError) }

        // Step 2: fetch the secret for that one item (may show the one-time access prompt).
        let itemQuery: [String: Any] = [kSecValuePersistentRef as String: ref, kSecReturnData as String: true]
        var itemResult: CFTypeRef?
        guard SecItemCopyMatching(itemQuery as CFDictionary, &itemResult) == errSecSuccess,
              let data = itemResult as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw WidgetError.msg(keychainError) }
        return (ref as CFTypeRef, root)
    }

    /// Returns a usable access token, refreshing it first when it has expired.
    ///
    /// A refresh rotates the refresh token, so the new pair is written back to the same
    /// Keychain item — exactly what Claude Code does — and Claude Code keeps working.
    /// If a Claude Code session for that profile is running, it refreshes the token itself,
    /// so we leave it alone to avoid racing it.
    nonisolated static func claudeToken(for account: ClaudeAccount) async throws -> String {
        let (ref, root) = try loadCreds(service: account.service)
        guard var oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw WidgetError.msg(L.t("Không đọc được token Claude Code trong Keychain",
                                          "Couldn't read the Claude Code token from the Keychain")) }
        let expiresMs = num(oauth["expiresAt"]) ?? 0
        let expired = expiresMs > 0 && Date(timeIntervalSince1970: expiresMs / 1000) < Date().addingTimeInterval(60)
        guard expired, let refresh = oauth["refreshToken"] as? String else { return token }
        if let dir = account.configDir, hasLiveSession(configDir: dir) { return token }

        let fresh = try await refreshOAuth(refresh, scopes: oauth["scopes"] as? [String])
        oauth["accessToken"] = fresh.access
        if let r = fresh.refresh { oauth["refreshToken"] = r }
        oauth["expiresAt"] = Int64((Date().timeIntervalSince1970 + fresh.expiresIn) * 1000)
        var newRoot = root
        newRoot["claudeAiOauth"] = oauth
        let data = try JSONSerialization.data(withJSONObject: newRoot)
        let status = SecItemUpdate([kSecValuePersistentRef as String: ref] as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else {
            throw WidgetError.msg(L.t("Không ghi được token mới vào Keychain (\(status))",
                                       "Couldn't save the refreshed token to the Keychain (\(status))"))
        }
        return fresh.access
    }

    nonisolated static func refreshOAuth(_ refreshToken: String, scopes: [String]?) async throws
        -> (access: String, refresh: String?, expiresIn: Double) {
        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",   // Claude Code's OAuth client
        ]
        if let scopes, !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        var req = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String
        else {
            throw WidgetError.msg(L.t("Làm mới token thất bại (HTTP \(code)) — mở Claude Code bằng tài khoản này để đăng nhập lại",
                                       "Token refresh failed (HTTP \(code)) — open Claude Code with this account to sign in again"))
        }
        return (access, obj["refresh_token"] as? String, num(obj["expires_in"]) ?? 3600)
    }

    nonisolated static func hasLiveSession(configDir: String) -> Bool {
        let dir = configDir + "/sessions"
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".json") {
            if let data = FileManager.default.contents(atPath: dir + "/" + f),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) == 0 { return true }
        }
        return false
    }

    // MARK: Accounts

    /// Every Claude Code login in the Keychain, default (~/.claude) first.
    nonisolated static func discoverAccounts() -> [ClaudeAccount] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var r: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let items = r as? [[String: Any]] else { return [] }
        let prefix = ClaudeAccount.defaultService
        let services = Set(items.compactMap { $0[kSecAttrService as String] as? String }.filter {
            $0 == prefix || ($0.hasPrefix(prefix + "-") && $0.count == prefix.count + 9)   // "-" + 8 hex chars
        })

        // Map the 8-char suffix back to a config dir by hashing the candidate paths.
        let home = NSHomeDirectory()
        var candidates = [home + "/.claude"]
        for n in (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [] where n.hasPrefix(".claude") {
            var isDir: ObjCBool = false
            let path = home + "/" + n
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { candidates.append(path) }
        }
        var byHash: [String: String] = [:]
        for c in candidates {
            for v in [c, c + "/"] { byHash[hash8(v.precomposedStringWithCanonicalMapping)] = c }
        }

        return services.map { svc -> ClaudeAccount in
            let dir = svc == prefix ? home + "/.claude" : byHash[String(svc.suffix(8))]
            return ClaudeAccount(service: svc, configDir: dir, email: dir.flatMap { accountEmail(configDir: $0) })
        }
        .sorted { a, b in a.isDefault != b.isDefault ? a.isDefault : a.label < b.label }
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
            throw WidgetError.msg(L.t("Cursor: token không hợp lệ", "Cursor: invalid token"))
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
                throw WidgetError.msg(L.t("Cursor: phiên đăng nhập hết hạn — mở Cursor để đăng nhập lại",
                                           "Cursor: session expired — open Cursor to log in again"))
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
                let title = L.t("Cursor (chu kỳ tháng)", "Cursor (monthly cycle)")
                return [Limit(kind: .cursor, title: title, used: min(100, used), resetsAt: end)]
            }
        }

        // Legacy request-based plans: fast requests used / max this month.
        let usage = try await get("https://cursor.com/api/usage?user=\(userId)")
        guard let gpt = usage["gpt-4"] as? [String: Any],
              let n = num(gpt["numRequests"]), let max = num(gpt["maxRequestUsage"]), max > 0
        else { throw WidgetError.msg(L.t("Cursor: không đọc được dữ liệu usage", "Cursor: couldn't read usage data")) }
        let start = (usage["startOfMonth"] as? String).flatMap(parseDate)
        let end = start.flatMap { Calendar.current.date(byAdding: .month, value: 1, to: $0) }
        let title = L.t("Cursor (\(Int(n))/\(Int(max)) request)", "Cursor (\(Int(n))/\(Int(max)) requests)")
        return [Limit(kind: .cursor, title: title, used: min(100, n / max * 100), resetsAt: end)]
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
        case .cursor: return "Cursor"
        }
    }
}

/// Cursor's title carries dynamic, already-localized detail (billing cycle / request count)
/// baked in at fetch time; the Claude kinds ignore the cached `title` and localize live.
func displayTitle(_ l: Limit) -> String { l.kind == .cursor ? l.title : l.kind.localizedTitle }

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
                Text(usage.limits.isEmpty && usage.error != nil ? "!" : usage.account.initial)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(usage.limits.isEmpty && usage.error != nil ? Color.orange : Color.white)
            }
            .frame(width: Layout.ring, height: Layout.ring)
            Text(five.map { "\(Int(value($0).rounded()))%" } ?? "–")
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
        let count = max(1, store.limits.count + store.accounts.count)
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
                if store.limits.isEmpty {
                    placeholder
                } else {
                    ForEach(store.limits) { RingGauge(limit: $0, showRemaining: showRemaining, forecast: store.forecasts[$0.kind]) }
                }
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
        if let u = store.update {
            item(L.t("⬆︎ Có bản mới v\(u.version) — Tải về", "⬆︎ v\(u.version) available — Download")) {
                NSWorkspace.shared.open(u.url)
            }
            menu.addItem(.separator())
        }
        if let t = store.lastUpdate {
            let time = t.formatted(date: .omitted, time: .shortened)
            let info = NSMenuItem(title: L.t("Cập nhật lúc \(time)", "Updated at \(time)"), action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        if !store.accounts.isEmpty, let def = store.defaultAccount {
            let h = NSMenuItem(title: "👤 " + def.label + L.t(" (tài khoản chính)", " (main account)"), action: nil, keyEquivalent: "")
            h.isEnabled = false
            menu.addItem(h)
        }
        for l in store.limits {
            let title = L.t(
                "\(displayTitle(l)): dùng \(Int(l.used.rounded()))% · reset sau \(countdown(to: l.resetsAt)) — lúc \(resetClock(l.resetsAt))",
                "\(displayTitle(l)): \(Int(l.used.rounded()))% used · resets in \(countdown(to: l.resetsAt)) — at \(resetClock(l.resetsAt))"
            )
            let info = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            if let f = forecastText(store.forecasts[l.kind]) {
                let fi = NSMenuItem(title: "     " + f, action: nil, keyEquivalent: "")
                fi.isEnabled = false
                menu.addItem(fi)
            }
        }
        for u in store.accounts {
            menu.addItem(.separator())
            for line in accountTooltip(u).split(separator: "\n").dropLast() {
                let it = NSMenuItem(title: String(line), action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
            }
        }
        if !store.accounts.isEmpty { menu.addItem(.separator()) }
        let tk = store.tokens
        let tokTitle = L.t(
            "Token hôm nay: \(formatTokens(tk.total)) (output \(formatTokens(tk.output)), cache đọc \(formatTokens(tk.cacheRead)))",
            "Tokens today: \(formatTokens(tk.total)) (output \(formatTokens(tk.output)), cache read \(formatTokens(tk.cacheRead)))"
        )
        let tokItem = NSMenuItem(title: tokTitle, action: nil, keyEquivalent: "")
        tokItem.isEnabled = false
        menu.addItem(tokItem)
        let running = store.runningSessions
        let headTitle = L.t(
            "Claude Code: \(running.count) đang chạy · \(store.sessions.count - running.count) rảnh",
            "Claude Code: \(running.count) running · \(store.sessions.count - running.count) idle"
        )
        let head = NSMenuItem(title: headTitle, action: nil, keyEquivalent: "")
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
        item(L.t("📊 Biểu đồ token…", "📊 Token chart…")) { ChartWindow.show() }
        item(L.t("Làm mới", "Refresh")) { store.refresh() }
        item(L.t("Hiển thị % còn lại", "Show % remaining"), checked: d.bool(forKey: Pref.showRemaining)) {
            d.set(!d.bool(forKey: Pref.showRemaining), forKey: Pref.showRemaining)
        }
        item(L.t("Luôn nằm trên cửa sổ khác", "Always on top of other windows"), checked: d.bool(forKey: Pref.alwaysOnTop)) {
            d.set(!d.bool(forKey: Pref.alwaysOnTop), forKey: Pref.alwaysOnTop)
            SidePanel.shared.applyLevel()
        }
        do {
            let langMenu = NSMenu()
            for lang in [Lang.vi, .en] {
                let h = Handler { d.set(lang.rawValue, forKey: Pref.language) }
                handlers.append(h)
                let it = NSMenuItem(title: lang == .vi ? "Tiếng Việt" : "English",
                                     action: #selector(Handler.run), keyEquivalent: "")
                it.target = h
                it.state = L.current == lang ? .on : .off
                langMenu.addItem(it)
            }
            let langItem = NSMenuItem(title: "Ngôn ngữ / Language", action: nil, keyEquivalent: "")
            langItem.submenu = langMenu
            menu.addItem(langItem)
        }
        if NSScreen.screens.count > 1 {
            let screenMenu = NSMenu()
            let current = SidePanel.shared.selectedScreen ?? NSScreen.main
            for (i, s) in NSScreen.screens.enumerated() {
                guard let id = SidePanel.displayID(for: s) else { continue }
                let h = Handler {
                    d.set(Int(id), forKey: Pref.panelScreenID)
                    SidePanel.shared.layout()
                }
                handlers.append(h)
                let it = NSMenuItem(title: L.t("Màn hình \(i + 1)", "Display \(i + 1)"), action: #selector(Handler.run), keyEquivalent: "")
                it.target = h
                it.state = s == current ? .on : .off
                screenMenu.addItem(it)
            }
            let screenItem = NSMenuItem(title: L.t("Hiển thị trên màn hình", "Show on display"), action: nil, keyEquivalent: "")
            screenItem.submenu = screenMenu
            menu.addItem(screenItem)
        }
        item(L.t("Hiện token hôm nay", "Show today's tokens"), checked: d.bool(forKey: Pref.showTokens)) {
            d.set(!d.bool(forKey: Pref.showTokens), forKey: Pref.showTokens)
            SidePanel.shared.layout()
        }
        item(L.t("Hiện số task đang chạy", "Show running task count"), checked: d.bool(forKey: Pref.showTasks)) {
            d.set(!d.bool(forKey: Pref.showTasks), forKey: Pref.showTasks)
            SidePanel.shared.layout()
        }
        item(L.t("Hiện Cursor", "Show Cursor"), checked: d.bool(forKey: Pref.showCursor)) {
            d.set(!d.bool(forKey: Pref.showCursor), forKey: Pref.showCursor)
            store.recompose()
        }
        item(L.t("Hiện trên menu bar", "Show in menu bar"), checked: d.bool(forKey: Pref.showMenuBar)) {
            d.set(!d.bool(forKey: Pref.showMenuBar), forKey: Pref.showMenuBar)
        }
        do {
            let notifMenu = NSMenu()
            let toggles: [(String, String, String)] = [
                (Pref.notifyLimits, "Limit chạm 80% / 95%", "Limit reaches 80% / 95%"),
                (Pref.notifyReset, "Limit vừa reset", "Limit has reset"),
                (Pref.notifyForecast, "Cảnh báo sớm (dự báo sắp hết)", "Early warning (forecast)"),
                (Pref.notifyTasks, "Task Claude Code chạy xong", "Claude Code task finished"),
            ]
            for (key, vi, en) in toggles {
                let h = Handler { d.set(!d.bool(forKey: key), forKey: key) }
                handlers.append(h)
                let it = NSMenuItem(title: L.t(vi, en), action: #selector(Handler.run), keyEquivalent: "")
                it.target = h
                it.state = d.bool(forKey: key) ? .on : .off
                notifMenu.addItem(it)
            }
            notifMenu.addItem(.separator())
            let h = Handler {
                Notifier.post(L.t("🔔 Thông báo thử", "🔔 Test notification"),
                              L.t("Thông báo của AiUsage đang hoạt động.", "AiUsage notifications are working."))
            }
            handlers.append(h)
            let test = NSMenuItem(title: L.t("Gửi thông báo thử", "Send test notification"), action: #selector(Handler.run), keyEquivalent: "")
            test.target = h
            notifMenu.addItem(test)
            let notifItem = NSMenuItem(title: L.t("Thông báo", "Notifications"), action: nil, keyEquivalent: "")
            notifItem.submenu = notifMenu
            menu.addItem(notifItem)
        }
        item(L.t("Tự chạy khi mở máy", "Launch at login"), checked: LoginItem.isEnabled) { LoginItem.toggle() }
        menu.addItem(.separator())
        item(L.t("Kiểm tra bản mới…", "Check for updates…")) { store.checkForUpdate(manual: true) }
        let ver = NSMenuItem(title: "AiUsage v\(UsageStore.appVersion)", action: nil, keyEquivalent: "")
        ver.isEnabled = false
        menu.addItem(ver)
        item(L.t("Thoát", "Quit")) { NSApp.terminate(nil) }
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

        store.$limits.map(\.count).combineLatest(store.$accounts.map(\.count)).map { $0 + $1 }.removeDuplicates()
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
        let size = Layout.windowSize(count: max(1, (store?.limits.count ?? 1) + (store?.accounts.count ?? 0)))
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
            ForEach([store.error, store.cursorError].compactMap { $0 }, id: \.self) { e in
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

    private let hourDays = 14
    private let calendarWeeks = 26
    private let cell: CGFloat = 18

    private func value(_ b: TokenHistory.Bucket?) -> Int {
        guard let b else { return 0 }
        return noCache ? b.noCacheRead : b.total
    }

    private var todayStart: Date { gmt7.startOfDay(for: Date()) }

    private func dayTotal(_ day: Date) -> Int {
        let h0 = Int(day.timeIntervalSince1970 / 3600)
        return (0..<24).reduce(0) { $0 + value(model.buckets[h0 + $1]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("", selection: $mode) {
                    Text(L.t("Theo giờ (14 ngày)", "By hour (14 days)")).tag(0)
                    Text(L.t("Theo ngày (6 tháng)", "By day (6 months)")).tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                Spacer()
                Toggle(L.t("Bỏ cache đọc", "Exclude cache reads"), isOn: $noCache)
                    .toggleStyle(.checkbox)
                    .help(L.t("Cache đọc chiếm phần lớn token nhưng rẻ hơn nhiều. Bỏ đi để thấy mức dùng \"thật\".",
                              "Cache reads are most tokens but much cheaper. Exclude them to see \"real\" usage."))
                Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(model.loading)
            }

            if !model.loaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L.t("Đang đọc lịch sử Claude Code… (lần đầu có thể mất vài giây)",
                             "Reading Claude Code history… (the first time can take a few seconds)"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 280)
            } else if mode == 0 {
                hourGrid
            } else {
                dayGrid
            }
        }
        .padding(20)
        .frame(minWidth: 720)
        .onAppear { model.load() }
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
        let busiest = days.max { dayTotal($0) < dayTotal($1) }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 3) {
                Text("").frame(width: 76)
                ForEach(0..<24, id: \.self) { h in
                    Text(h % 3 == 0 ? String(format: "%02d", h) : "")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: cell)
                }
            }
            ForEach(days, id: \.self) { d in
                let h0 = Int(d.timeIntervalSince1970 / 3600)
                HStack(spacing: 3) {
                    Text("\(weekdayShort(d)) \(dayMonth(d))")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        let v = value(model.buckets[h0 + h])
                        RoundedRectangle(cornerRadius: 3)
                            .fill(pal.color(heatLevel(v, t)))
                            .frame(width: cell, height: cell)
                            .help("\(weekdayShort(d)) \(dayMonth(d)) · \(String(format: "%02d:00–%02d:00", h, (h + 1) % 24))\n\(formatTokens(v)) token")
                    }
                    Text(formatTokens(dayTotal(d)))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
            HStack {
                legend(pal)
                Spacer()
                Text(L.t("14 ngày: \(formatTokens(total)) · Giờ cao điểm: \(String(format: "%02d:00", peakHour))",
                         "14 days: \(formatTokens(total)) · Peak hour: \(String(format: "%02d:00", peakHour))")
                     + (busiest.map { L.t(" · Nhiều nhất: \(weekdayShort($0)) \(dayMonth($0))", " · Busiest: \(weekdayShort($0)) \(dayMonth($0))") } ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: By day — GitHub contribution calendar

    private var dayGrid: some View {
        // Start on the Monday `calendarWeeks - 1` weeks before this week's Monday.
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
        let best = totals.max { $0.value < $1.value }
        let c: CGFloat = 18
        let rowLabels = L.current == .vi ? ["T2", "", "T4", "", "T6", "", "CN"] : ["Mon", "", "Wed", "", "Fri", "", "Sun"]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 3) {
                VStack(spacing: 3) {
                    Text("").frame(height: 12)
                    ForEach(0..<7, id: \.self) { i in
                        Text(rowLabels[i]).font(.system(size: 9)).foregroundStyle(.secondary).frame(height: c)
                    }
                }
                .frame(width: 26)
                ForEach(weeks.indices, id: \.self) { w in
                    VStack(spacing: 3) {
                        let first = weeks[w][0]
                        let showMonth = w == 0 || gmt7.component(.month, from: first) != gmt7.component(.month, from: weeks[w - 1][0])
                        Text(showMonth ? monthLabel(first) : "")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: c, height: 12, alignment: .leading)
                        ForEach(weeks[w], id: \.self) { d in
                            if d > todayStart {
                                Color.clear.frame(width: c, height: c)
                            } else {
                                let v = totals[d] ?? 0
                                RoundedRectangle(cornerRadius: 2.5)
                                    .fill(pal.color(heatLevel(v, t)))
                                    .frame(width: c, height: c)
                                    .help("\(weekdayShort(d)) \(dayMonth(d))\n\(formatTokens(v)) token")
                            }
                        }
                    }
                }
            }
            HStack {
                legend(pal)
                Spacer()
                Text(L.t("6 tháng: \(formatTokens(sum)) · \(active) ngày có dùng",
                         "6 months: \(formatTokens(sum)) · \(active) active days")
                     + (best.map { L.t(" · Cao nhất: \(dayMonth($0.key)) (\(formatTokens($0.value)))",
                                       " · Top day: \(dayMonth($0.key)) (\(formatTokens($0.value)))") } ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func monthLabel(_ d: Date) -> String {
        let m = gmt7.component(.month, from: d)
        return L.current == .vi ? "Th\(m)" : ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][m - 1]
    }

    private func legend(_ pal: HeatPalette) -> some View {
        HStack(spacing: 3) {
            Text(L.t("Ít", "Less")).font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { RoundedRectangle(cornerRadius: 2.5).fill(pal.color($0)).frame(width: 11, height: 11) }
            Text(L.t("Nhiều", "More")).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

@MainActor
enum ChartWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = L.t("AiUsage — Token Claude Code", "AiUsage — Claude Code tokens")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: TokenChartView())
            w.setContentSize(w.contentView?.fittingSize ?? NSSize(width: 780, height: 560))
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
            let label = store.fiveHour.map { "\(Int($0.used.rounded()))%" } ?? "…"
            HStack(spacing: 3) {
                Image(systemName: "sparkle")
                Text(label).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
