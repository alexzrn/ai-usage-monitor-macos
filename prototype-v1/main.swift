import AppKit
import SwiftUI

struct UsageWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let percent: Double
    let resetAt: Date?
}

struct CodexSession: Identifiable, Equatable {
    let id: String
    let title: String
    let project: String
    let model: String
    let updatedAt: Date?
}

struct CodexData: Equatable {
    var plan = "Codex"
    var windows: [UsageWindow] = []
    var sessions: [CodexSession] = []
    var connected = false
    var updatedAt: Date?
    var error: String?
}

struct HermesData: Equatable {
    var windows: [UsageWindow] = []
    var connected = false
    var updatedAt: Date?
    var error: String?
}

@MainActor
final class DeskModel: ObservableObject {
    @Published var codex = CodexData()
    @Published var hermes = HermesData()
    @Published var selectedTab = 0
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
        Task.detached(priority: .utility) {
            let codex = Self.readCodex()
            let hermes = Self.readHermes()
            await MainActor.run { self.codex = codex; self.hermes = hermes; self.loading = false }
        }
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String]) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch { return nil }
    }

    nonisolated private static func jsonDict(_ data: Data?) -> [String: Any]? {
        guard let data, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value
    }

    nonisolated private static func readCodex() -> CodexData {
        var result = CodexData()
        let home = NSHomeDirectory()
        let dbPath = "\(home)/.codex/state_5.sqlite"
        let sql = "SELECT id,title,cwd,updated_at_ms,model,rollout_path FROM threads WHERE archived=0 ORDER BY updated_at_ms DESC LIMIT 12;"
        let rows = run("/usr/bin/sqlite3", ["-json", dbPath, sql]).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        result.sessions = rows.prefix(5).map { row in
            let rawTitle = (row["title"] as? String ?? "Сессия Codex").components(separatedBy: .newlines).first ?? "Сессия Codex"
            let title = rawTitle.count > 66 ? String(rawTitle.prefix(63)) + "…" : rawTitle
            let cwd = row["cwd"] as? String ?? ""
            let project = cwd.split(separator: "/").suffix(2).joined(separator: "/")
            let millis = (row["updated_at_ms"] as? NSNumber)?.doubleValue
            let updated = millis.map { Date(timeIntervalSince1970: $0 / 1000) }
            return CodexSession(id: row["id"] as? String ?? UUID().uuidString,
                                title: title, project: project.isEmpty ? "Codex" : project,
                                model: row["model"] as? String ?? "Codex",
                                updatedAt: updated)
        }

        for row in rows {
            guard let path = row["rollout_path"] as? String,
                  let limits = readRateLimits(path: path) else { continue }
            result.plan = (limits["plan_type"] as? String ?? "Codex").capitalized
            result.windows = [
                makeWindow(id: "primary", label: "5 ЧАСОВ", data: limits["primary"] as? [String: Any]),
                makeWindow(id: "weekly", label: "НЕДЕЛЯ", data: limits["secondary"] as? [String: Any])
            ].compactMap { $0 }
            result.connected = !result.windows.isEmpty
            break
        }
        if !result.connected { result.error = rows.isEmpty ? "Локальная история не найдена" : "Лимиты появятся после следующего ответа Codex" }
        result.updatedAt = Date()
        return result
    }

    nonisolated private static func readRateLimits(path: String) -> [String: Any]? {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 900_000 ? size - 900_000 : 0)
        let data = handle.readDataToEndOfFile()
        for line in data.split(separator: 10).reversed() {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  row["type"] as? String == "event_msg",
                  let payload = row["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            return limits
        }
        return nil
    }

    nonisolated private static func makeWindow(id: String, label: String, data: [String: Any]?) -> UsageWindow? {
        guard let data, let value = data["used_percent"] as? Double else { return nil }
        let epoch = (data["resets_at"] as? NSNumber)?.doubleValue
        return UsageWindow(id: id, label: label, percent: value, resetAt: epoch.map { Date(timeIntervalSince1970: $0) })
    }

    nonisolated private static func readHermes() -> HermesData {
        var result = HermesData()
        let home = NSHomeDirectory()
        let hermes = "\(home)/.local/bin/hermes"
        let helper = Bundle.main.resourceURL?.appendingPathComponent("hermes_usage.py").path
            ?? "\(home)/Projects/opencode-desk/Resources/hermes_usage.py"
        guard let command = run(hermes, ["--print-runtime-command"]),
              let pieces = try? JSONSerialization.jsonObject(with: command) as? [String],
              let runtimePython = pieces.first else {
            result.error = "Hermes не найден"
            return result
        }
        let runtimePath = URL(fileURLWithPath: runtimePython).resolvingSymlinksInPath().path
        let environments = "\(home)/.hermes/installs"
        let roots = (try? FileManager.default.contentsOfDirectory(atPath: environments)) ?? []
        var python: String?
        for root in roots {
            let environmentRoot = "\(environments)/\(root)/environments"
            for environment in (try? FileManager.default.contentsOfDirectory(atPath: environmentRoot)) ?? [] {
                let candidate = "\(environmentRoot)/\(environment)/venv/bin/python"
                let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
                if resolved == runtimePath, FileManager.default.isExecutableFile(atPath: candidate) { python = candidate; break }
            }
            if python != nil { break }
        }
        guard let python, let data = run(python, ["-I", helper]),
              let doc = jsonDict(data), doc["ok"] as? Bool == true,
              let rows = doc["windows"] as? [[String: Any]] else {
            result.error = "Нет ответа от OpenCode Go"
            return result
        }
        result.windows = rows.compactMap { row in
            guard let id = row["id"] as? String, let label = row["label"] as? String,
                  let percent = row["percent"] as? Double else { return nil }
            let reset = (row["reset_epoch"] as? NSNumber)?.doubleValue
            return UsageWindow(id: id, label: label, percent: percent, resetAt: reset.map { Date(timeIntervalSince1970: $0) })
        }
        result.connected = !result.windows.isEmpty
        result.updatedAt = Date()
        if !result.connected { result.error = "OpenCode Go не вернул лимиты" }
        return result
    }
}

@main
struct OpenCodeDeskApp: App {
    @NSApplicationDelegateAdaptor(DeskAppDelegate.self) private var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class DeskAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let model = DeskModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = DeskPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 385, height: 660), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.contentView = DeskHostingView(rootView: DeskView(model: model))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = false
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.minSize = NSSize(width: 340, height: 500)
        window.maxSize = NSSize(width: 500, height: 820)
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - window.frame.width - 28, y: screen.visibleFrame.minY + 28))
        }
        window.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

final class DeskPanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class DeskHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct DeskView: View {
    @ObservedObject var model: DeskModel
    private var isCodex: Bool { model.selectedTab == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabs.padding(.top, 17)
            Divider().overlay(.white.opacity(0.12)).padding(.vertical, 15)
            if isCodex { codexPage } else { hermesPage }
            Spacer(minLength: 10)
            footer
        }
        .padding(19)
        .foregroundStyle(.white)
        .frame(minWidth: 340, maxWidth: 500, minHeight: 500, maxHeight: 820)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.black.opacity(0.45)))
                .environment(\.colorScheme, .dark)
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.19), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button("Обновить") { model.refresh() }
            Menu("Интервал обновления") {
                ForEach([15, 30, 60, 120], id: \.self) { seconds in
                    Button("\(seconds) секунд" + (model.interval == seconds ? " ✓" : "")) { model.interval = seconds; model.schedule() }
                }
            }
            Divider()
            Button("Выход") { NSApp.terminate(nil) }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(isCodex ? "CODEX" : "HERMES").font(.system(size: 12, weight: .bold, design: .rounded)).tracking(1.5).foregroundStyle(.white.opacity(0.82))
                HStack(spacing: 7) {
                    Circle().fill((isCodex ? model.codex.connected : model.hermes.connected) ? Color(red: 0.48, green: 0.91, blue: 0.66) : .orange).frame(width: 7, height: 7)
                    Text(isCodex ? model.codex.plan : "OpenCode Go").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.72))
                }
            }
            Spacer()
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.86))
                    .padding(8).background(.white.opacity(0.12), in: Circle())
            }.buttonStyle(.plain).help("Обновить данные")
        }
    }

    private var tabs: some View {
        HStack(spacing: 5) {
            tabButton("Codex", index: 0, icon: "chevron.left.forwardslash.chevron.right")
            tabButton("Hermes", index: 1, icon: "sparkles")
            Spacer()
        }.padding(4).background(.white.opacity(0.07), in: Capsule())
    }

    private func tabButton(_ title: String, index: Int, icon: String) -> some View {
        Button { model.selectedTab = index } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }.padding(.horizontal, 13).padding(.vertical, 8)
                .foregroundStyle(model.selectedTab == index ? .white : .white.opacity(0.58))
                .background(model.selectedTab == index ? .white.opacity(0.17) : .clear, in: Capsule())
        }.buttonStyle(.plain)
    }

    private var codexPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("USAGE CODEX")
            if model.codex.windows.isEmpty {
                emptyCard(model.codex.error ?? "Ожидание данных Codex")
            } else {
                VStack(spacing: 15) {
                    ForEach(model.codex.windows) { window in usageMeter(window) }
                }.padding(14).background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 15))
            }
            Divider().overlay(.white.opacity(0.12)).padding(.vertical, 1)
            HStack {
                sectionLabel("ПОСЛЕДНИЕ СЕССИИ")
                Spacer()
                Text("\(model.codex.sessions.count)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.72))
            }
            if model.codex.sessions.isEmpty { emptyCard("Локальные чаты Codex не найдены") }
            else { VStack(spacing: 3) { ForEach(model.codex.sessions) { sessionRow($0) } } }
        }
    }

    private var hermesPage: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("OPENCODE GO · ЛИМИТЫ")
                Spacer()
                Text("HERMES").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.white.opacity(0.45))
            }
            if model.hermes.windows.isEmpty {
                emptyCard(model.hermes.error ?? "Ожидание usage OpenCode Go")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.hermes.windows.enumerated()), id: \.element.id) { index, window in
                        usageMeter(window)
                        if index < model.hermes.windows.count - 1 { Divider().overlay(.white.opacity(0.09)).padding(.vertical, 13) }
                    }
                }.padding(15).background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 16))
            }
            Text("Usage аккаунта OpenCode Go, которым пользуется Hermes. Это квоты провайдера, а не локальная оценка токенов.")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.54)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionLabel(_ value: String) -> some View {
        Text(value).font(.system(size: 9, weight: .bold)).tracking(1.1).foregroundStyle(.white.opacity(0.56))
    }

    private func usageMeter(_ window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.white.opacity(0.74))
                Spacer()
                Text("\(Int(window.percent.rounded()))% использовано").font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(window.percent >= 80 ? Color(red: 1, green: 0.76, blue: 0.33) : Color(red: 0.34, green: 0.86, blue: 0.61))
                        .frame(width: proxy.size.width * min(max(window.percent / 100, 0), 1))
                }
            }.frame(height: 6)
            HStack {
                Text("Осталось \(Int(max(0, 100 - window.percent).rounded()))%")
                Spacer()
                Text(resetText(window.resetAt))
            }.font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.53))
        }
    }

    private func sessionRow(_ session: CodexSession) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.48, green: 0.91, blue: 0.66)).frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.system(size: 10, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text(session.project).lineLimit(1)
                    Text("·")
                    Text(session.model).lineLimit(1)
                    Spacer(minLength: 2)
                    if let date = session.updatedAt { Text(date, style: .relative).lineLimit(1) }
                }.font(.system(size: 8)).foregroundStyle(.white.opacity(0.49))
            }
        }.padding(.vertical, 6)
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.58))
            .frame(maxWidth: .infinity, alignment: .leading).padding(13)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
    }

    private var footer: some View {
        HStack {
            Text("ОБНОВЛЕНИЕ · \(model.interval) СЕК").font(.system(size: 8, weight: .semibold)).tracking(0.7)
            Spacer()
            let date = isCodex ? model.codex.updatedAt : model.hermes.updatedAt
            Text(date.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—").font(.system(size: 9, weight: .medium, design: .monospaced))
        }.foregroundStyle(.white.opacity(0.42)).padding(.top, 4)
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return "сброс —" }
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        if seconds < 3600 { return "сброс через \(max(1, seconds / 60)) мин" }
        if seconds < 86400 { return "сброс через \(seconds / 3600) ч \((seconds % 3600) / 60) мин" }
        return "сброс через \(seconds / 86400) д \((seconds % 86400) / 3600) ч"
    }
}
