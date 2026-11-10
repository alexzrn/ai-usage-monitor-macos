import AppKit
import SwiftUI

private enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, value: key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: .current, arguments: arguments)
    }

    static func displayError(_ raw: String) -> String {
        if raw.contains("HTTP 401") { return text("error.opencgo.unauthorized") }
        if raw.contains("HTTP "), let status = raw.split(separator: " ").last { return format("error.http_status", String(status)) }
        switch raw {
        case "OpenCode Go CLI was not found", "Hermes CLI не найден": return text("error.hermes.missing")
        case "OpenClaw CLI was not found": return text("error.openclaw.missing")
        case "Could not read OpenClaw sessions": return text("error.openclaw.sessions")
        case "Could not read OpenClaw provider usage": return text("error.openclaw.usage")
        case "Не удалось получить Usage OpenCode Go": return text("error.usage.opencgo")
        case "Не удалось получить баланс DeepSeek": return text("error.usage.deepseek")
        case "Для этого провайдера ещё нет Usage-адаптера", "Usage недоступен для этого провайдера": return text("provider.unsupported")
        default: return raw
        }
    }
}

struct ProviderDefinition: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let usageAdapter: String
}

struct AppDefinition: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let adapter: String
    let providerIds: [String]
    var discoverProviders = false
    var providerFilter: String?

    private enum CodingKeys: String, CodingKey { case id, title, adapter, providerIds, discoverProviders, providerFilter }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        adapter = try values.decode(String.self, forKey: .adapter)
        providerIds = try values.decodeIfPresent([String].self, forKey: .providerIds) ?? []
        discoverProviders = try values.decodeIfPresent(Bool.self, forKey: .discoverProviders) ?? false
        providerFilter = try values.decodeIfPresent(String.self, forKey: .providerFilter)
    }
}

struct Registry: Decodable {
    let providers: [ProviderDefinition]
    let apps: [AppDefinition]

    static func load() -> Registry {
        let home = NSHomeDirectory()
        let userFile = URL(fileURLWithPath: "\(home)/.config/ai-usage-monitor/registry.json")
        let bundledFile = Bundle.main.resourceURL?.appendingPathComponent("registry.json")
        for url in [userFile, bundledFile].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Registry.self, from: data) {
                return value
            }
        }
        return Registry(providers: [], apps: [])
    }
}

struct UsageMetric: Identifiable, Equatable {
    let id: String
    let label: String
    var percent: Double?
    var value: String?
    var detail: String?
    var resetAt: Date?

    init(id: String, label: String, percent: Double? = nil, value: String? = nil,
         detail: String? = nil, resetAt: Date? = nil) {
        self.id = id
        self.label = label
        self.percent = percent
        self.value = value
        self.detail = detail
        self.resetAt = resetAt
    }
}

struct ProviderSnapshot: Equatable {
    var connected = false
    var metrics: [UsageMetric] = []
    var updatedAt: Date?
    var error: String?
    var note: String?

    init(connected: Bool = false, metrics: [UsageMetric] = [], updatedAt: Date? = nil,
         error: String? = nil, note: String? = nil) {
        self.connected = connected
        self.metrics = metrics
        self.updatedAt = updatedAt
        self.error = error
        self.note = note
    }
}

struct MonitorSession: Identifiable, Equatable {
    let id: String
    let appId: String
    let appTitle: String
    let providerId: String
    let title: String
    let project: String
    let workingDirectory: String?
    let model: String
    let updatedAt: Date?
    let tokenCount: Int
    let costUSD: Double?
}

struct MonitorSnapshot {
    var sessions: [MonitorSession] = []
    var providerUsage: [String: ProviderSnapshot] = [:]
    var sourceProviderIds: [String: [String]] = [:]
    var sourceErrors: [String: String] = [:]
    var updatedAt = Date()
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var registry = Registry.load()
    @Published var snapshot = MonitorSnapshot()
    @Published var selectedApp = "codex"
    @Published var interval = 30
    private var timer: Timer?
    private var loading = false

    init() { schedule(); refresh() }

    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        let registrySnapshot = registry
        Task.detached(priority: .utility) {
            let data = Self.collect(registry: registrySnapshot)
            await MainActor.run { self.snapshot = data; self.loading = false }
        }
    }

    func sessions(for app: AppDefinition, providerId: String) -> [MonitorSession] {
        Array(allSessions(for: app, providerId: providerId).prefix(4))
    }

    func allSessions(for app: AppDefinition, providerId: String) -> [MonitorSession] {
        snapshot.sessions.filter { session in
            session.providerId == providerId && (app.adapter == "provider-view" || session.appId == app.id)
        }.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    func providers(for app: AppDefinition) -> [String] {
        if app.adapter == "provider-view" { return app.providerIds }
        var ids = app.providerIds
        if app.discoverProviders {
            ids += snapshot.sessions.filter { $0.appId == app.id }.map(\.providerId)
        }
        ids += snapshot.sourceProviderIds[app.id] ?? []
        return Array(NSOrderedSet(array: ids)).compactMap { $0 as? String }
    }

    func providerDefinition(_ id: String) -> ProviderDefinition {
        registry.providers.first(where: { $0.id == id }) ?? ProviderDefinition(id: id, title: Self.title(for: id), usageAdapter: "unsupported")
    }

    nonisolated private static func collect(registry: Registry) -> MonitorSnapshot {
        let codex = readCodex()
        let hermes = readHermes()
        let opencode = readOpenCode()
        let openclaw = readOpenClaw()
        let sessions = (codex.sessions + hermes + opencode + openclaw.sessions).sorted {
            ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }

        var usage = readProviderUsage()
        usage["openai-codex"] = codex.usage
        for (provider, snapshot) in openclaw.usage where usage[provider] == nil {
            usage[provider] = snapshot
        }
        // Provider definitions may be extended in registry.json; currently supported adapters
        // are resolved explicitly, while unknown providers remain visible with an honest status.
        for provider in registry.providers where usage[provider.id] == nil {
            usage[provider.id] = ProviderSnapshot(connected: false, error: "Для этого провайдера ещё нет Usage-адаптера")
        }
        for session in sessions where usage[session.providerId] == nil {
            usage[session.providerId] = ProviderSnapshot(connected: false, error: "Usage недоступен для этого провайдера")
        }
        return MonitorSnapshot(sessions: sessions, providerUsage: usage,
                               sourceProviderIds: ["openclaw": Array(openclaw.usage.keys)],
                               sourceErrors: openclaw.error.map { ["openclaw": $0] } ?? [:], updatedAt: Date())
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String],
                                       timeout: TimeInterval = 15, acceptNonzero: Bool = false) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let timeoutWork = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeoutWork.cancel()
            return process.terminationStatus == 0 || acceptNonzero ? data : nil
        } catch { return nil }
    }

    nonisolated private static func jsonObject(_ data: Data?) -> Any? {
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    nonisolated private static func sqliteRows(_ sql: String) -> [[String: Any]] {
        let codexDirectory = URL(fileURLWithPath: "\(NSHomeDirectory())/.codex", isDirectory: true)
        let databases = ((try? FileManager.default.contentsOfDirectory(at: codexDirectory,
                                                                       includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        guard let path = databases.first?.path else { return [] }
        guard let data = run("/usr/bin/sqlite3", ["-json", path, sql]),
              let rows = jsonObject(data) as? [[String: Any]] else { return [] }
        return rows
    }

    nonisolated private static func readCodex() -> (sessions: [MonitorSession], usage: ProviderSnapshot) {
        let sql = "SELECT id,title,cwd,updated_at_ms,model,rollout_path FROM threads WHERE archived=0 ORDER BY updated_at_ms DESC LIMIT 16;"
        let rows = sqliteRows(sql)
        let sessions = rows.prefix(8).map { row -> MonitorSession in
            let title = shortTitle(row["title"] as? String ?? "Codex session")
            let cwd = row["cwd"] as? String ?? "Codex"
            let project = shortPath(cwd)
            let updated = (row["updated_at_ms"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return MonitorSession(id: row["id"] as? String ?? UUID().uuidString, appId: "codex", appTitle: "Codex",
                                  providerId: "openai-codex", title: title, project: project, workingDirectory: cwd,
                                  model: row["model"] as? String ?? "Codex", updatedAt: updated,
                                  tokenCount: 0, costUSD: nil)
        }

        var snapshot = ProviderSnapshot()
        for row in rows {
            guard let path = row["rollout_path"] as? String, let rateLimits = readCodexRateLimits(path) else { continue }
            let plan = (rateLimits["plan_type"] as? String ?? "Plus").capitalized
            var metrics: [UsageMetric] = []
            if let primary = rateLimits["primary"] as? [String: Any],
               let percent = (primary["used_percent"] as? NSNumber)?.doubleValue {
                metrics.append(rateMetric(id: "five-hour", label: L10n.text("usage.five_hours"), data: primary, percent: percent))
            }
            if let secondary = rateLimits["secondary"] as? [String: Any],
               let percent = (secondary["used_percent"] as? NSNumber)?.doubleValue {
                metrics.append(rateMetric(id: "weekly", label: L10n.text("usage.week"), data: secondary, percent: percent))
            }
            snapshot = ProviderSnapshot(connected: !metrics.isEmpty, metrics: metrics, updatedAt: Date(),
                                        error: metrics.isEmpty ? L10n.text("error.codex.limits_pending") : nil,
                                        note: L10n.format("usage.codex.plan", plan))
            if snapshot.connected { break }
        }
        if !snapshot.connected && rows.isEmpty { snapshot.error = L10n.text("error.codex.history_missing") }
        return (sessions, snapshot)
    }

    nonisolated private static func readCodexRateLimits(_ path: String) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 900_000 ? size - 900_000 : 0)
        for line in handle.readDataToEndOfFile().split(separator: 10).reversed() {
            guard let object = jsonObject(Data(line)) as? [String: Any], object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            return limits
        }
        return nil
    }

    nonisolated private static func rateMetric(id: String, label: String, data: [String: Any], percent: Double) -> UsageMetric {
        let epoch = (data["resets_at"] as? NSNumber)?.doubleValue
        return UsageMetric(id: id, label: label, percent: percent, resetAt: epoch.map { Date(timeIntervalSince1970: $0) })
    }

    nonisolated private static func readHermes() -> [MonitorSession] {
        let db = "\(NSHomeDirectory())/.hermes/state.db"
        let sql = "SELECT id,title,cwd,model,billing_provider,source,COALESCE(last_activity_at,started_at) AS updated,input_tokens,output_tokens,reasoning_tokens,cache_read_tokens,actual_cost_usd,estimated_cost_usd FROM sessions WHERE archived=0 AND hidden=0 ORDER BY COALESCE(last_activity_at,started_at) DESC LIMIT 500;"
        guard let data = run("/usr/bin/sqlite3", ["-json", db, sql]),
              let rows = jsonObject(data) as? [[String: Any]] else { return [] }
        return rows.map { row in
            let provider = normalizedProvider(row["billing_provider"] as? String ?? "unknown")
            let seconds = (row["updated"] as? NSNumber)?.doubleValue
            let count = ["input_tokens", "output_tokens", "reasoning_tokens", "cache_read_tokens"]
                .compactMap { (row[$0] as? NSNumber)?.intValue }.reduce(0, +)
            let actual = (row["actual_cost_usd"] as? NSNumber)?.doubleValue
            let estimated = (row["estimated_cost_usd"] as? NSNumber)?.doubleValue
            return MonitorSession(id: "hermes-\(row["id"] as? String ?? UUID().uuidString)", appId: "hermes",
                                  appTitle: "Hermes", providerId: provider,
                                  title: shortTitle(row["title"] as? String ?? "Hermes session"),
                                  project: shortPath(row["cwd"] as? String ?? row["source"] as? String ?? "Hermes"),
                                  workingDirectory: row["cwd"] as? String,
                                  model: row["model"] as? String ?? "—",
                                  updatedAt: seconds.map { Date(timeIntervalSince1970: $0) },
                                  tokenCount: count, costUSD: actual ?? estimated)
        }
    }

    nonisolated private static func readOpenCode() -> [MonitorSession] {
        let cli = executable(named: "opencode", candidates: ["\(NSHomeDirectory())/.local/bin/opencode", "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"])
        guard let cli, let data = run(cli, ["api", "GET", "/api/session"]),
              let object = jsonObject(data) as? [String: Any], let rows = object["data"] as? [[String: Any]] else { return [] }
        return rows.prefix(500).map { row in
            let model = row["model"] as? [String: Any] ?? [:]
            let provider = normalizedProvider(model["providerID"] as? String ?? "unknown")
            let location = row["location"] as? [String: Any] ?? [:]
            let time = row["time"] as? [String: Any] ?? [:]
            let millis = (time["updated"] as? NSNumber)?.doubleValue
            let tokens = row["tokens"] as? [String: Any] ?? [:]
            let cache = tokens["cache"] as? [String: Any] ?? [:]
            let tokenCount = ["input", "output", "reasoning"].compactMap { (tokens[$0] as? NSNumber)?.intValue }.reduce(0, +)
                + ((cache["read"] as? NSNumber)?.intValue ?? 0)
            let modelName = model["id"] as? String ?? "—"
            return MonitorSession(id: "opencode-\(row["id"] as? String ?? UUID().uuidString)", appId: "opencode",
                                  appTitle: "OpenCode", providerId: provider,
                                  title: shortTitle(row["title"] as? String ?? "OpenCode session"),
                                  project: shortPath(location["directory"] as? String ?? "OpenCode"),
                                  workingDirectory: location["directory"] as? String,
                                  model: modelName, updatedAt: millis.map { Date(timeIntervalSince1970: $0 / 1000) },
                                  tokenCount: tokenCount, costUSD: (row["cost"] as? NSNumber)?.doubleValue)
        }
    }

    nonisolated private static func readOpenClaw() -> (sessions: [MonitorSession], usage: [String: ProviderSnapshot], error: String?) {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/openclaw", "\(home)/.npm-global/bin/openclaw",
                          "/opt/homebrew/bin/openclaw", "/usr/local/bin/openclaw", "/usr/bin/openclaw"]
        guard let cli = executable(named: "openclaw", candidates: candidates) else {
            return ([], [:], L10n.text("error.openclaw.missing"))
        }

        let sessionData = run(cli, ["sessions", "--all-agents", "--limit", "100", "--json"], timeout: 12)
        let sessionObject = jsonObject(sessionData) as? [String: Any]
        let sessionRows = sessionObject?["sessions"] as? [[String: Any]] ?? []
        let sessions = sessionRows.compactMap { row -> MonitorSession? in
            guard let key = row["key"] as? String else { return nil }
            let model = row["model"] as? String ?? "—"
            let provider = normalizedProvider(row["provider"] as? String ?? String(model.split(separator: "/").first ?? "unknown"))
            let agent = row["agentId"] as? String ?? "OpenClaw"
            let title = row["label"] as? String ?? row["displayName"] as? String ?? row["name"] as? String ?? key
            let workspace = row["workspace"] as? String ?? row["workspaceDir"] as? String
            let tokens = (row["totalTokens"] as? NSNumber)?.intValue ?? 0
            let cost = (row["costUSD"] as? NSNumber)?.doubleValue ?? (row["cost"] as? NSNumber)?.doubleValue
            let updated = parseDate(row["updatedAt"] ?? row["updatedAtMs"])
            return MonitorSession(id: key, appId: "openclaw", appTitle: "OpenClaw", providerId: provider,
                                  title: shortTitle(title), project: workspace.map(shortPath) ?? "agent: \(agent)",
                                  workingDirectory: workspace, model: model, updatedAt: updated,
                                  tokenCount: tokens, costUSD: cost)
        }

        let statusData = run(cli, ["status", "--usage", "--json", "--timeout", "5000"], timeout: 12, acceptNonzero: true)
        let status = jsonObject(statusData) as? [String: Any] ?? [:]
        let usageRoot = status["usage"] as? [String: Any] ?? status
        let providers = usageRoot["providers"] as? [[String: Any]] ?? []
        var usage: [String: ProviderSnapshot] = [:]
        for row in providers {
            guard let rawId = row["provider"] as? String else { continue }
            let id = normalizedProvider(rawId)
            let windows = row["windows"] as? [[String: Any]] ?? []
            let metrics = windows.compactMap { window -> UsageMetric? in
                guard let label = window["label"] as? String,
                      let percent = ((window["usedPercent"] ?? window["percent"]) as? NSNumber)?.doubleValue else { return nil }
                let reset = parseDate(window["resetAt"] ?? window["resetsAt"])
                return UsageMetric(id: "openclaw-\(id)-\(label)", label: label, percent: percent, resetAt: reset)
            }
            let plan = row["plan"] as? String
            let note = [row["displayName"] as? String, plan].compactMap { $0 }.joined(separator: " · ")
            usage[id] = ProviderSnapshot(connected: !metrics.isEmpty, metrics: metrics, updatedAt: Date(),
                                         error: row["error"] as? String, note: note.isEmpty ? nil : note)
        }
        let error: String?
        if sessionData == nil || sessionObject == nil {
            error = L10n.text("error.openclaw.sessions")
        } else if sessions.isEmpty && usage.isEmpty {
            error = L10n.text("error.openclaw.no_sessions")
        } else {
            error = nil
        }
        return (sessions, usage, error)
    }

    nonisolated private static func readProviderUsage() -> [String: ProviderSnapshot] {
        let home = NSHomeDirectory()
        let hermes = executable(named: "hermes", candidates: ["\(home)/.local/bin/hermes", "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"])
        guard let hermes else {
            return ["opencode-go": ProviderSnapshot(error: "Hermes CLI не найден"),
                    "deepseek": ProviderSnapshot(error: "Hermes CLI не найден")]
        }
        guard let command = run(hermes, ["--print-runtime-command"]),
              let pieces = jsonObject(command) as? [String], let runtimePython = pieces.first else {
            return ["opencode-go": ProviderSnapshot(error: "Hermes не найден"),
                    "deepseek": ProviderSnapshot(error: "Hermes не найден")]
        }
        let runtimePath = URL(fileURLWithPath: runtimePython).resolvingSymlinksInPath().path
        let envRoot = "\(home)/.hermes/installs"
        let roots = (try? FileManager.default.contentsOfDirectory(atPath: envRoot)) ?? []
        var python: String?
        for root in roots {
            let environments = "\(envRoot)/\(root)/environments"
            for environment in (try? FileManager.default.contentsOfDirectory(atPath: environments)) ?? [] {
                let candidate = "\(environments)/\(environment)/venv/bin/python"
                if URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path == runtimePath,
                   FileManager.default.isExecutableFile(atPath: candidate) { python = candidate; break }
            }
            if python != nil { break }
        }
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("provider_usage.py").path,
              let python, let data = run(python, ["-I", helper]),
              let doc = jsonObject(data) as? [String: Any], let providers = doc["providers"] as? [String: Any] else {
            return ["opencode-go": ProviderSnapshot(error: "Не удалось получить Usage OpenCode Go"),
                    "deepseek": ProviderSnapshot(error: "Не удалось получить баланс DeepSeek")]
        }
        var output: [String: ProviderSnapshot] = [:]
        if let go = providers["opencode-go"] as? [String: Any] {
            let rows = go["windows"] as? [[String: Any]] ?? []
            let metrics = rows.compactMap { row -> UsageMetric? in
                guard let id = row["id"] as? String, let label = row["label"] as? String,
                      let percent = (row["percent"] as? NSNumber)?.doubleValue else { return nil }
                let epoch = (row["reset_epoch"] as? NSNumber)?.doubleValue
                let localizedLabel = ["rolling": "usage.five_hours", "weekly": "usage.week", "monthly": "usage.month"][id]
                    .map(L10n.text) ?? label
                return UsageMetric(id: id, label: localizedLabel, percent: percent, resetAt: epoch.map { Date(timeIntervalSince1970: $0) })
            }
            output["opencode-go"] = ProviderSnapshot(connected: go["ok"] as? Bool == true,
                                                      metrics: metrics, updatedAt: Date(),
                                                      error: go["error"] as? String,
                                                      note: L10n.text("usage.opencode.plan"))
        }
        if let deepseek = providers["deepseek"] as? [String: Any] {
            let balances = deepseek["balances"] as? [[String: Any]] ?? []
            let metrics = balances.compactMap { row -> UsageMetric? in
                guard let currency = row["currency"] as? String, let total = row["total"] as? String else { return nil }
                let granted = row["granted"] as? String ?? "0"
                let topped = row["topped_up"] as? String ?? "0"
                return UsageMetric(id: "balance-\(currency.lowercased())", label: L10n.format("usage.balance", currency),
                                   value: "\(currency == "USD" ? "$" : "")\(total)\(currency == "CNY" ? " ¥" : "")",
                                   detail: L10n.format("usage.grant", granted, topped))
            }
            let available = deepseek["available"] as? Bool ?? false
            output["deepseek"] = ProviderSnapshot(connected: deepseek["ok"] as? Bool == true,
                                                   metrics: metrics, updatedAt: Date(),
                                                   error: deepseek["error"] as? String,
                                                   note: L10n.text(available ? "usage.account.available" : "usage.account.unavailable"))
        }
        return output
    }

    nonisolated private static func normalizedProvider(_ value: String) -> String {
        let key = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return "unknown" }
        if key == "openai-codex" || key == "chatgpt" { return "openai-codex" }
        if key == "opencode" || key == "opencode_zen" || key == "opencode-go-sub" { return "opencode-go" }
        return key
    }

    nonisolated private static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let epoch = number.doubleValue
            return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
        }
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    nonisolated static func executableForAction(_ app: String, home: String) -> String? {
        let name = app == "hermes" ? "hermes" : app == "codex" ? "codex" : app == "openclaw" ? "openclaw" : "opencode"
        let candidates: [String]
        switch app {
        case "hermes": candidates = ["\(home)/.local/bin/hermes", "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"]
        case "codex": candidates = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        case "openclaw": candidates = ["\(home)/.local/bin/openclaw", "\(home)/.npm-global/bin/openclaw", "/opt/homebrew/bin/openclaw", "/usr/local/bin/openclaw"]
        default: candidates = ["\(home)/.local/bin/opencode", "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
        }
        return executable(named: name, candidates: candidates)
    }

    nonisolated private static func executable(named name: String, candidates: [String]) -> String? {
        let home = NSHomeDirectory()
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var managedDirectories = ["\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.bun/bin",
                                  "\(home)/Library/pnpm", "/opt/homebrew/bin", "/usr/local/bin"]
        for root in ["\(home)/.nvm/versions/node", "\(home)/.local/share/mise/installs/node",
                     "\(home)/.asdf/installs/nodejs"] {
            for version in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
                managedDirectories.append("\(root)/\(version)/bin")
            }
        }
        return (candidates + managedDirectories + pathEntries).map { "\($0)/\(name)" }.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    nonisolated private static func title(for id: String) -> String {
        switch id {
        case "openai-codex": return L10n.text("provider.openai_codex")
        case "opencode-go": return L10n.text("provider.opencode_go")
        case "deepseek": return L10n.text("provider.deepseek")
        case "unknown": return L10n.text("provider.unknown")
        case "opencode-free": return "OpenCode Free"
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "google": return "Google AI"
        case "openrouter": return "OpenRouter"
        case "copilot": return "GitHub Copilot"
        default: return id.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    nonisolated private static func shortTitle(_ value: String) -> String {
        let first = value.components(separatedBy: .newlines).first ?? value
        return first.count > 76 ? String(first.prefix(73)) + "…" : first
    }

    nonisolated private static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        let display = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let components = display.split(separator: "/")
        return components.suffix(2).joined(separator: "/")
    }
}

@main
struct AIUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(MonitorAppDelegate.self) private var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class MonitorAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let model = MonitorModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = MonitorPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 405, height: 690),
                                    styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.contentView = MonitorHostingView(rootView: MonitorView(model: model))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = false
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.minSize = NSSize(width: 350, height: 500)
        window.maxSize = NSSize(width: 520, height: 860)
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 28, y: screen.visibleFrame.minY + 28))
        }
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

final class MonitorPanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class MonitorHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    private var selectedApp: AppDefinition? { model.registry.apps.first(where: { $0.id == model.selectedApp }) }

    var body: some View {
        VStack(spacing: 0) {
            header
            appTabs.padding(.top, 15)
            Divider().overlay(.white.opacity(0.12)).padding(.vertical, 12)
            ScrollView(.vertical) {
                if let app = selectedApp { providerCards(for: app) }
            }
            .scrollIndicators(.hidden)
            footer.padding(.top, 9)
        }
        .padding(18)
        .foregroundStyle(.white)
        .frame(minWidth: 350, maxWidth: 520, minHeight: 500, maxHeight: 860)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.black.opacity(0.48)))
                .environment(\.colorScheme, .dark)
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button(L10n.text("action.refresh")) { model.refresh() }
            Menu(L10n.text("menu.refresh.interval")) {
                ForEach([15, 30, 60, 120], id: \.self) { value in
                    Button(L10n.format("menu.seconds", value) + (model.interval == value ? " ✓" : "")) { model.interval = value; model.schedule() }
                }
            }
            Divider()
            Button(L10n.text("action.quit")) { NSApp.terminate(nil) }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(selectedApp?.title.uppercased() ?? "AI MONITOR")
                    .font(.system(size: 12, weight: .bold, design: .rounded)).tracking(1.5).foregroundStyle(.white.opacity(0.84))
                HStack(spacing: 7) {
                    Circle().fill(model.snapshot.sessions.isEmpty ? .orange : Color(red: 0.48, green: 0.91, blue: 0.66)).frame(width: 7, height: 7)
                    Text(statusText).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.86))
                    .padding(8).background(.white.opacity(0.12), in: Circle())
            }.buttonStyle(.plain).help(L10n.text("action.refresh"))
        }
    }

    private var statusText: String {
        guard let app = selectedApp else { return L10n.text("app.status.none") }
        let providerIds = model.providers(for: app)
        let connected = providerIds.compactMap { model.snapshot.providerUsage[$0] }.filter(\.connected).count
        return connected > 0 ? L10n.format("app.status.connected", connected) : L10n.text("app.status.waiting")
    }

    private var appTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(model.registry.apps) { app in
                    Button { model.selectedApp = app.id } label: {
                        HStack(spacing: 6) {
                            Image(systemName: icon(for: app.id)).font(.system(size: 10, weight: .semibold))
                            Text(app.title).font(.system(size: 10, weight: .semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .foregroundStyle(model.selectedApp == app.id ? .white : .white.opacity(0.58))
                        .background(model.selectedApp == app.id ? .white.opacity(0.17) : .clear, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }.padding(4)
        }
        .scrollIndicators(.hidden)
        .background(.white.opacity(0.07), in: Capsule())
    }

    @ViewBuilder private func providerCards(for app: AppDefinition) -> some View {
        let ids = model.providers(for: app)
        if ids.isEmpty {
            emptyCard(model.snapshot.sourceErrors[app.id]
                      ?? (app.adapter == "provider-view" ? L10n.text("session.none") : L10n.text("provider.none")))
        } else {
            VStack(spacing: 11) {
                ForEach(ids, id: \.self) { providerId in
                    providerCard(providerId, app: app)
                }
            }
        }
    }

    private func providerCard(_ providerId: String, app: AppDefinition) -> some View {
        let provider = model.providerDefinition(providerId)
        let usage = model.snapshot.providerUsage[providerId] ?? ProviderSnapshot(error: L10n.text("error.usage.adapter_missing"))
        let sessions = model.sessions(for: app, providerId: providerId)
        let aggregate = aggregateUsage(model.allSessions(for: app, providerId: providerId))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(usage.connected ? Color(red: 0.48, green: 0.91, blue: 0.66) : .orange).frame(width: 7, height: 7)
                Text(provider.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 3)
                Text("\(sessions.count)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 7).padding(.vertical, 3).background(.white.opacity(0.1), in: Capsule())
            }
            Divider().overlay(.white.opacity(0.09))
            sectionTitle(L10n.text("section.usage"))
            if usage.metrics.isEmpty {
                emptyCard(usage.error.map(L10n.displayError) ?? L10n.text("usage.waiting"))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(usage.metrics.enumerated()), id: \.element.id) { index, metric in
                        metricView(metric)
                        if index < usage.metrics.count - 1 { Divider().overlay(.white.opacity(0.08)).padding(.vertical, 10) }
                    }
                }.padding(11).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
            }
            if providerId == "deepseek", aggregate.tokens > 0 {
                HStack {
                    Text(L10n.text("usage.sessions.30d")).font(.system(size: 8, weight: .bold)).tracking(0.7).foregroundStyle(.white.opacity(0.48))
                    Spacer()
                    Text(L10n.format("usage.tokens.cost", compact(aggregate.tokens), aggregate.cost.map { String(format: "$%.2f", $0) } ?? L10n.text("usage.cost.unavailable")))
                        .font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.68))
                }
            }
            if let note = usage.note {
                Text(note).font(.system(size: 9)).foregroundStyle(.white.opacity(0.48)).fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(.white.opacity(0.09))
            HStack {
                sectionTitle(L10n.text("section.recent"))
                Spacer()
                Text(app.adapter == "provider-view" ? L10n.text("section.all_apps") : app.title.uppercased())
                    .font(.system(size: 7, weight: .bold)).tracking(0.55).foregroundStyle(.white.opacity(0.4))
            }
            if sessions.isEmpty {
                Text(L10n.text("session.none")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.48)).padding(.vertical, 4)
            } else {
                VStack(spacing: 2) { ForEach(sessions) { session in
                    Button { open(session) } label: { sessionRow(session, showApp: app.adapter == "provider-view") }
                        .buttonStyle(.plain).help(L10n.format("action.open_session", session.appTitle))
                } }
            }
        }
        .padding(13)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder private func metricView(_ metric: UsageMetric) -> some View {
        if let percent = metric.percent {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.label).font(.system(size: 9, weight: .bold)).tracking(0.7).foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Text(L10n.format("usage.percent", Int(percent.rounded()))).font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule().fill(percent >= 80 ? Color(red: 1, green: 0.75, blue: 0.29) : Color(red: 0.34, green: 0.86, blue: 0.61))
                            .frame(width: proxy.size.width * min(max(percent / 100, 0), 1))
                    }
                }.frame(height: 6)
                HStack {
                    Text(L10n.format("usage.remaining", Int(max(0, 100 - percent).rounded())))
                    Spacer()
                    Text(resetText(metric.resetAt))
                }.font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.49))
            }
        } else {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(metric.label).font(.system(size: 8, weight: .bold)).tracking(0.7).foregroundStyle(.white.opacity(0.55))
                    if let detail = metric.detail { Text(detail).font(.system(size: 8)).foregroundStyle(.white.opacity(0.47)) }
                }
                Spacer()
                Text(metric.value ?? "—").font(.system(size: 18, weight: .semibold, design: .rounded))
            }
        }
    }

    private func sessionRow(_ session: MonitorSession, showApp: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.48, green: 0.91, blue: 0.66)).frame(width: 3, height: 29)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.system(size: 9, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    if showApp { Text(session.appTitle); Text("·") }
                    Text(session.project).lineLimit(1)
                    Text("·")
                    Text(session.model).lineLimit(1)
                    Spacer(minLength: 2)
                    if let date = session.updatedAt { Text(date, style: .relative).lineLimit(1) }
                }.font(.system(size: 7)).foregroundStyle(.white.opacity(0.46))
            }
        }.padding(.vertical, 4)
    }

    private func open(_ session: MonitorSession) {
        let home = NSHomeDirectory()
        guard let cli = MonitorModel.executableForAction(session.appId, home: home) else {
            if session.appId == "codex", let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            return
        }
        var arguments: [String]
        var directory = home
        switch session.appId {
        case "codex":
            arguments = ["--cd", session.workingDirectory ?? home, "resume", session.id]
        case "opencode":
            arguments = ["--session", session.id.replacingOccurrences(of: "opencode-", with: "")]
            directory = session.workingDirectory ?? home
        case "hermes":
            arguments = ["--in", session.workingDirectory ?? home, "--resume", session.id.replacingOccurrences(of: "hermes-", with: ""), "chat"]
        case "openclaw":
            arguments = ["tui", session.id]
            directory = session.workingDirectory ?? home
        default:
            return
        }
        let command = ([cli] + arguments).map(Self.shellQuote).joined(separator: " ")
        let terminalCommand = "cd \(Self.shellQuote(directory)) && \(command)"
        let script = "tell application \"Terminal\" to do script \"\(Self.applescriptQuote(terminalCommand))\"\ntell application \"Terminal\" to activate"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func applescriptQuote(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    private func sectionTitle(_ value: String) -> some View {
        Text(value).font(.system(size: 8, weight: .bold)).tracking(0.85).foregroundStyle(.white.opacity(0.51))
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text).font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
    }

    private var footer: some View {
        HStack {
            Text(L10n.format("footer.refresh", model.interval)).font(.system(size: 7, weight: .bold)).tracking(0.65)
            Spacer()
            Text(model.snapshot.updatedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 8, weight: .medium, design: .monospaced))
        }.foregroundStyle(.white.opacity(0.42))
    }

    private func icon(for id: String) -> String {
        switch id {
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "hermes": return "sparkles"
        case "opencode": return "terminal"
        case "deepseek": return "waveform.path"
        case "openclaw": return "pawprint"
        default: return "square.grid.2x2"
        }
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return L10n.text("usage.reset.none") }
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        if seconds < 3600 { return L10n.format("usage.reset.minutes", max(1, seconds / 60)) }
        if seconds < 86400 { return L10n.format("usage.reset.hours", seconds / 3600, (seconds % 3600) / 60) }
        return L10n.format("usage.reset.days", seconds / 86400, (seconds % 86400) / 3600)
    }

    private func aggregateUsage(_ sessions: [MonitorSession]) -> (tokens: Int, cost: Double?) {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let recent = sessions.filter { ($0.updatedAt ?? .distantPast) >= cutoff }
        let costRows = recent.compactMap(\.costUSD)
        return (recent.reduce(0) { $0 + $1.tokenCount }, costRows.isEmpty ? nil : costRows.reduce(0, +))
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fk", Double(value) / 1_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }
}
