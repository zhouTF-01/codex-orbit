import AppKit
import SwiftUI
import CoreFoundation
import SQLite3
import Darwin

struct QuotaWindow {
    let used: Double
    let minutes: Int?
    let reset: Date?
    var remaining: Double { min(100, max(0, 100 - used)) }
    var label: String {
        guard let m = minutes else { return "额度窗口" }
        if m == 10080 { return "本周剩余" }
        if m == 1440 { return "每日剩余" }
        if m % 60 == 0 { return "\(m / 60) 小时剩余" }
        return "\(m) 分钟剩余"
    }
    static func parse(_ obj: Any?) -> QuotaWindow? {
        guard let d = obj as? [String: Any], let number = d["usedPercent"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return QuotaWindow(used: number.doubleValue, minutes: d["windowDurationMins"] as? Int,
            reset: (d["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }
}
struct Snapshot {
    let windows: [QuotaWindow]
    let plan: String?
    static func parse(_ result: [String: Any]) throws -> Snapshot {
        let map = result["rateLimitsByLimitId"] as? [String: [String: Any]]
        // Select the Codex bucket explicitly; never substitute another product's quota.
        let bucket = map?["codex"] ?? result["rateLimits"] as? [String: Any]
        guard let b = bucket else { throw QueryError.message("暂未返回 Codex 额度") }
        let windows = [QuotaWindow.parse(b["primary"]), QuotaWindow.parse(b["secondary"])].compactMap { $0 }
        guard !windows.isEmpty else { throw QueryError.message("该账户暂未提供额度百分比") }
        return Snapshot(windows: windows, plan: b["planType"] as? String)
    }
}
enum QueryError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}
final class QuotaClient {
    static func executable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func read() throws -> Snapshot {
        guard let executable = executable() else { throw QueryError.message("未找到 Codex CLI，请先安装并登录") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let completion = DispatchSemaphore(value: 0), lock = NSLock()
        var buffer = Data(), answer: Result<Snapshot, Error>?
        func finish(_ value: Result<Snapshot, Error>) {
            lock.lock(); defer { lock.unlock() }
            if answer == nil { answer = value; completion.signal() }
        }
        func send(_ obj: [String: Any]) {
            do {
                var bytes = try JSONSerialization.data(withJSONObject: obj); bytes.append(10)
                try input.fileHandleForWriting.write(contentsOf: bytes)
            } catch { finish(.failure(QueryError.message("Codex 连接中断，请重试"))) }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { finish(.failure(QueryError.message("Codex 连接已关闭，请重试"))); return }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[..<newline]; buffer.removeSubrange(...newline)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = obj["id"] as? Int else { continue }
                if obj["error"] != nil {
                    finish(.failure(QueryError.message("额度读取失败，请确认 Codex 已登录后重试"))); continue
                }
                if id == 1 {
                    send(["method": "initialized"])
                    send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2, let result = obj["result"] as? [String: Any] {
                    finish(Result { try Snapshot.parse(result) })
                }
            }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
        try process.run()
        send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_orbit", "title": "Codex Orbit", "version": "1.0.1"]]])
        guard completion.wait(timeout: .now() + 20) == .success else { throw QueryError.message("连接超时，点击刷新重试") }
        lock.lock(); let result = answer; lock.unlock()
        return try result!.get()
    }
}

// Public WhenReset data never receives the Codex account identity or credentials.
struct ResetNews {
    let scheduled: Date?
    let scheduledDay: String?
    let scheduledZone: String?
    let timeZoneConfirmed: Bool
    let forecast: Date?
    let latest: Date?
    let kind: String
    let scope: String
    let original: URL?
    let checked: Date?
    let expires: Date?
    let pending: Bool
    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    static func sourceURL(_ value: Any?) -> URL? {
        guard let string = value as? String, let url = URL(string: string), url.scheme == "https",
              ["x.com", "www.x.com", "twitter.com", "whenreset.dev"].contains(url.host?.lowercased() ?? "") else { return nil }
        return url
    }
    static func parse(_ object: [String: Any], now: Date = Date()) throws -> ResetNews {
        guard object["dataSchemaVersion"] as? String == "public-api-1",
              let watch = object["watch"] as? [String: Any], let events = object["events"] as? [[String: Any]] else {
            throw QueryError.message("重置消息格式已变化")
        }
        let codex = watch["codex"] as? [String: Any]
        let latest = events.filter { $0["provider"] as? String == "codex" && date($0["landedAt"]).map { $0 <= now } == true }
            .max { (date($0["landedAt"]) ?? .distantPast) < (date($1["landedAt"]) ?? .distantPast) }
        let completedID = codex?["completedEventId"] as? String
        let completed = completedID.map { id in events.contains { $0["id"] as? String == id && date($0["landedAt"]).map { $0 <= now } == true } } ?? false
        let announced = date(codex?["at"]).map { $0 <= now } ?? true
        let pending = codex?["open"] as? Bool == true && !completed && announced
        let stats = (object["stats"] as? [String: [String: Any]])?["codex"]
        let sources = latest?["sources"] as? [[String: Any]]
        let confirmedSource = sources?.first { $0["role"] as? String == "landed" } ?? sources?.first
        return ResetNews(scheduled: pending ? date(codex?["scheduledAt"]) : nil,
            scheduledDay: pending ? codex?["scheduledDay"] as? String : nil,
            scheduledZone: pending ? codex?["scheduledTimeZone"] as? String : nil,
            timeZoneConfirmed: codex?["timeZoneConfirmed"] as? Bool == true,
            forecast: date(stats?["estimatedNextAt"]), latest: date(latest?["landedAt"]),
            kind: (pending ? codex?["type"] : latest?["type"]) as? String ?? "reset",
            scope: (pending ? codex?["scope"] : latest?["scope"]) as? String ?? "unknown",
            original: sourceURL(pending ? codex?["url"] : confirmedSource?["url"]),
            checked: date(object["checkedAt"]), expires: date(object["expiresAt"]), pending: pending)
    }
    static func time(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; return f.string(from: date)
    }
    func headline(now: Date) -> String {
        let prefix = kind == "card" || kind == "banked" ? "重置卡" : "加赠"
        if pending {
            if let scheduled { return scheduled > now ? "\(prefix)预告 \(Self.time(scheduled)) 前" : "\(prefix)预告已到期 · 待确认" }
            if let scheduledDay {
                // Day-only notices are never converted into an invented precise local timestamp.
                return "\(prefix)预告 \(scheduledDay.suffix(5)) · 时刻待定"
            }
            return "\(prefix)预告 · 时间待定"
        }
        if let forecast, forecast > now { return "加赠预测 \(Self.time(forecast))" }
        return "下次加赠 · 暂无预告"
    }
    var scopeText: String {
        switch scope { case "all": return "所有用户"; case "paid": return "付费用户"; case "some": return "部分用户"; default: return "\(scope)（以原文为准）" }
    }
}
struct NewsRateLimit: Error {
    let retryAt: Date
}
struct ResetNewsClient {
    static func retryDelay(_ header: String?, now: Date = Date()) -> TimeInterval {
        if let header, let seconds = Double(header.trimmingCharacters(in: .whitespacesAndNewlines)) { return max(60, seconds) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let header, let date = formatter.date(from: header.trimmingCharacters(in: .whitespacesAndNewlines)) { return max(60, date.timeIntervalSince(now)) }
        return 300
    }
    static func read(completion: @escaping (Result<ResetNews, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(Result {
                // Use the system HTTPS client with bounded requests and explicit HTTP error handling.
                // Disable implicit curl config before all other options; never inherit headers or uploads from ~/.curlrc.
                // Arguments are fixed; no shell, account information, or tokens are sent.
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                process.arguments = ["-q", "--silent", "--show-error", "--location", "--proto-redir", "=https", "--max-redirs", "3", "--include", "--max-time", "15", "--connect-timeout", "5", "--max-filesize", "2000000", "--proto", "=https", "--write-out", "\nORBIT_HTTP_STATUS:%{http_code}\n", "https://whenreset.dev/api/resets"]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8), let marker = text.range(of: "\nORBIT_HTTP_STATUS:", options: .backwards),
                      let status = Int(text[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) else { throw QueryError.message("公开消息连接失败，将自动重试") }
                let response = String(text[..<marker.lowerBound])
                if status == 429 {
                    let retry = response.components(separatedBy: .newlines).last { $0.lowercased().hasPrefix("retry-after:") }
                    let seconds = retryDelay(retry.map { String($0.dropFirst(12)) })
                    throw NewsRateLimit(retryAt: Date().addingTimeInterval(seconds))
                }
                guard status == 200 else { throw QueryError.message(status == 403 ? "消息源拒绝请求，将自动重试" : "消息源暂不可用（HTTP \(status)）") }
                guard let boundary = response.range(of: "\r\n\r\n", options: .backwards) ?? response.range(of: "\n\n", options: .backwards),
                      let json = response[boundary.upperBound...].data(using: .utf8), json.count <= 2_000_000,
                      let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw QueryError.message("消息源数据格式异常") }
                let news = try ResetNews.parse(object)
                let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("local.codex.orbit")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? json.write(to: folder.appendingPathComponent("whenreset.json"), options: .atomic)
                return news
            })
        }
    }
}
struct NewsLine: View {
    @ObservedObject var model: QuotaModel
    @State private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 9))
                Text(model.newsHeadline).lineLimit(1).font(.system(size: 9))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 7))
            }.foregroundStyle(model.newsStale || model.news?.pending != true ? muted : cyan)
        }
        .buttonStyle(.plain).help(model.newsHelp)
        .accessibilityLabel(model.newsHeadline + "，查看来源和消息详情")
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 9) {
                HStack { Text("重置消息").font(.system(size: 12, weight: .semibold)); Spacer(); Text("WhenReset").font(.system(size: 9)).foregroundStyle(.secondary) }
                Text(model.newsHeadline).font(.system(size: 11, weight: .medium))
                if let news = model.news {
                    if !news.pending { Text("暂无下一次官方预告；预测来自历史间隔，可能变化。").font(.system(size: 10)).foregroundStyle(.secondary) }
                    if news.pending, news.scheduledDay != nil, news.scheduled == nil {
                        Text("公告时区：\(news.scheduledZone ?? "未确认")；具体时刻待定。").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let latest = news.latest { Text("最近记录：\(ResetNews.time(latest))").font(.system(size: 10)) }
                    Text("\(news.pending ? "预告范围" : "最近记录范围")：\(news.scopeText)").font(.system(size: 10))
                    if let checked = news.checked { Text("来源检查：\(ResetNews.time(checked))").font(.system(size: 9)).foregroundStyle(.secondary) }
                    if model.newsStale { Text("消息已过期，保留上次读数并自动重试。").font(.system(size: 10)).foregroundStyle(amber) }
                    else if model.newsError != nil { Text("显示有效缓存，后台自动更新。").font(.system(size: 10)).foregroundStyle(.secondary) }
                    Text("公告与账户周期独立，实际到账以账户额度为准。").font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack {
                        Link("查看网站", destination: URL(string: "https://whenreset.dev/codex")!)
                        Spacer()
                        if let url = news.original { Link("公告原文", destination: url) }
                    }.font(.system(size: 10))
                } else {
                    Text(model.newsError ?? "正在读取公开消息…").font(.system(size: 10)).foregroundStyle(.secondary)
                    Link("查看网站", destination: URL(string: "https://whenreset.dev/codex")!).font(.system(size: 10))
                }
            }.padding(14).frame(width: 230).preferredColorScheme(.dark)
        }
    }
}

struct ActivitySession: Identifiable, Equatable {
    let id: String
    let threadID: String
    let title: String
    var ordinal: Int64 = 0
    var completedAt: Date? = nil
}
struct ThreadRuntime {
    var type: String
    var flags: [String]
    var attentionIDs: [String] = []
}
struct AttentionRequest: Equatable {
    let key: String
    let session: ActivitySession
    var createdAt: Date? = nil
}
final class ActivityModel: ObservableObject {
    @Published var running: [ActivitySession] = []
    @Published var approvals: [ActivitySession] = []
    @Published var completed: [ActivitySession] = []
    @Published var connected = false
    @Published var issue: String?
    @Published var redPulse = 0
    @Published var yellowPulse = 0
    @Published var greenPulse = 0
    @Published var redBorderPulse = 0
    @Published var yellowBorderPulse = 0
    @Published var greenBorderPulse = 0
    var redTriggeredAt = Date.distantPast, yellowTriggeredAt = Date.distantPast, greenTriggeredAt = Date.distantPast
    var redBorderAt = Date.distantPast, yellowBorderAt = Date.distantPast, greenBorderAt = Date.distantPast
    var completionAlertActive: Bool { !completed.isEmpty }
    var pendingCompletions: [ActivitySession] { Self.uniqueThreads(completed) }
    private var runtimeFresh = Set<String>()
    private var lastClassification: [String: String] = [:]
    private var active: [ActivitySession] = []
    private var runtime: [String: ThreadRuntime] = [:]
    private var asynchronous: [AttentionRequest] = []
    private var unseenAttention: [String: ActivitySession] = [:]
    private var acknowledgedAttention = Set<String>()
    private var seenAttention = Set<String>()
    private var attentionReadBoundary: [String: Int64] = [:]
    private var seenCompleted = Set<String>()
    private var observedCompleted: [String: ActivitySession] = [:]
    private var viewedCompleted = Set<String>()
    private var legacyUnread: Set<String>?
    private var viewedAt: [String: Date] = [:]
    private var readThrough: [String: Int64] = [:]
    private var initialized = false
    private var monitor: NativeActivityMonitor?
    static func uniqueThreads(_ sessions: [ActivitySession]) -> [ActivitySession] {
        var seen = Set<String>()
        return sessions.sorted { $0.ordinal > $1.ordinal }.filter { seen.insert($0.threadID).inserted }
    }
    func start() {
        let monitor = NativeActivityMonitor(); self.monitor = monitor
        monitor.onDatabase = { [weak self] active, completed, attention, readThrough, legacyUnread, issue in self?.acceptDatabase(active, completed: completed, attention: attention, readThrough: readThrough, legacyUnread: legacyUnread, issue: issue) }
        monitor.onConnection = { [weak self] connected in self?.acceptConnection(connected) }
        monitor.onRuntime = { [weak self] id, status in self?.acceptRuntime(id, status) }
        monitor.onViewed = { [weak self] id in self?.acceptViewed(id) }
        monitor.start()
    }
    private func isRead(_ session: ActivitySession) -> Bool {
        if viewedCompleted.contains(session.id) { return true }
        if let completedAt = session.completedAt, let viewed = viewedAt[session.threadID], completedAt <= viewed { return true }
        if let legacyUnread, let completedAt = session.completedAt {
            // This desktop release keeps its visible unread state in this store; stale SQL receipts must not override it.
            if legacyUnread.contains(session.threadID) { return false }
            return Date().timeIntervalSince(completedAt) >= 2
        }
        if session.ordinal > 0, let through = readThrough[session.threadID], session.ordinal <= through { return true }
        return false
    }
    private func isAttentionRead(_ key: String, session: ActivitySession) -> Bool {
        let current = readThrough[session.threadID] ?? Int64.min
        guard let firstObserved = attentionReadBoundary[key] else {
            attentionReadBoundary[key] = current
            return false
        }
        return session.ordinal > 0 && current >= session.ordinal && current > firstObserved
    }
    func acceptDatabase(_ active: [ActivitySession], completed: [ActivitySession], attention: [AttentionRequest] = [], readThrough: [String: Int64] = [:], legacyUnread: Set<String>? = nil, issue: String? = nil) {
        self.issue = issue; guard issue == nil else { return }
        self.active = active; self.asynchronous = attention; self.readThrough = readThrough
        let previousLegacy = self.legacyUnread
        if let legacyUnread { self.legacyUnread = legacyUnread }
        if let previousLegacy, let legacyUnread {
            for thread in previousLegacy.subtracting(legacyUnread) {
                viewedAt[thread] = Date()
                acknowledgedAttention.formUnion(unseenAttention.filter { $0.value.threadID == thread }.map(\.key))
            }
        }
        let before = Set(self.completed.map(\.id))
        if initialized {
            for session in completed where !seenCompleted.contains(session.id) { observedCompleted[session.id] = session }
        }
        initialized = true; seenCompleted.formUnion(completed.map(\.id))
        self.completed = observedCompleted.values.filter { !isRead($0) }.sorted { $0.ordinal > $1.ordinal }
        let after = Set(self.completed.map(\.id))
        if !after.subtracting(before).isEmpty { greenTriggeredAt = Date(); greenPulse += 1 }
        if after != before { greenBorderAt = Date(); greenBorderPulse += 1 }
        publish()
    }
    func acceptViewed(_ threadID: String, now: Date = Date()) {
        viewedAt[threadID] = now
        viewedCompleted.formUnion(observedCompleted.values.filter { $0.threadID == threadID && ($0.completedAt.map { $0 <= now } ?? true) }.map(\.id))
        acknowledgedAttention.formUnion(unseenAttention.filter { $0.value.threadID == threadID }.map(\.key))
        let before = completed.count
        completed.removeAll { $0.threadID == threadID && ($0.completedAt.map { $0 <= now } ?? true) }
        if completed.count != before { greenBorderAt = Date(); greenBorderPulse += 1 }
        publish()
    }
    func acceptConnection(_ value: Bool) { connected = value; if !value { runtimeFresh.removeAll() }; publish() }
    func acceptRuntime(_ id: String, _ status: ThreadRuntime) { runtime[id] = status; runtimeFresh.insert(id); publish() }
    private func publish() {
        let oldAttentionKeys = Set(unseenAttention.keys)
        let activeByThread = Dictionary(active.map { ($0.threadID, $0) }, uniquingKeysWith: { _, newer in newer })
        var relevant: [String: ActivitySession] = [:]
        for request in asynchronous {
            if let created = request.createdAt, let viewed = viewedAt[request.session.threadID], created <= viewed { acknowledgedAttention.insert(request.key) }
            if isAttentionRead(request.key, session: request.session) { acknowledgedAttention.insert(request.key) }
            relevant[request.key] = request.session
        }
        for (threadID, session) in activeByThread {
            guard let status = runtime[threadID], status.type == "active" else { continue }
            let identifiers = status.attentionIDs.isEmpty && status.flags.contains(where: { $0 == "waitingOnApproval" || $0 == "waitingOnUserInput" }) ? ["waiting:\(session.id):\(status.flags.sorted().joined(separator: ","))"] : status.attentionIDs
            for id in identifiers {
                let key = threadID + ":" + id
                if isAttentionRead(key, session: session) { acknowledgedAttention.insert(key) }
                relevant[key] = session
            }
        }
        unseenAttention = relevant.filter { !acknowledgedAttention.contains($0.key) }
        let asyncKeys = Set(asynchronous.map(\.key))
        approvals = Self.uniqueThreads(unseenAttention.filter { asyncKeys.contains($0.key) || runtimeFresh.contains($0.value.threadID) }.map(\.value))
        let newAttention = Set(unseenAttention.keys).subtracting(seenAttention)
        seenAttention.formUnion(unseenAttention.keys)
        if !newAttention.isEmpty { redTriggeredAt = Date(); redPulse += 1 }
        if oldAttentionKeys != Set(unseenAttention.keys) { redBorderAt = Date(); redBorderPulse += 1 }
        running = active.filter {
            guard runtimeFresh.contains($0.threadID), let status = runtime[$0.threadID] else { return false }
            return status.type == "active" && !status.flags.contains("waitingOnApproval") && !status.flags.contains("waitingOnUserInput")
        }
        let yellow = Set(running.map(\.id)); var newYellow = false, yellowChanged = false
        for session in active where runtimeFresh.contains(session.threadID) {
            let classification = yellow.contains(session.id) ? "yellow" : "idle"
            if lastClassification[session.id] != classification {
                if classification == "yellow" { newYellow = true }
                if classification == "yellow" || lastClassification[session.id] == "yellow" { yellowChanged = true }
                lastClassification[session.id] = classification
            }
        }
        let ids = Set(active.map(\.id))
        if lastClassification.contains(where: { !ids.contains($0.key) && $0.value == "yellow" }) { yellowChanged = true }
        lastClassification = lastClassification.filter { ids.contains($0.key) }
        if newYellow { yellowTriggeredAt = Date(); yellowPulse += 1 }
        if yellowChanged { yellowBorderAt = Date(); yellowBorderPulse += 1 }
    }
    var diagnosticSummary: String { "dbActive=\(active.count) fresh=\(runtimeFresh.count) cached=\(runtime.values.map { $0.type + ":" + $0.flags.joined(separator: ",") }.joined(separator: "|"))" }
    func stop() { monitor?.stop() }
}

final class NativeActivityMonitor {
    var onDatabase: (([ActivitySession], [ActivitySession], [AttentionRequest], [String: Int64], Set<String>?, String?) -> Void)?
    var onConnection: ((Bool) -> Void)?
    var onRuntime: ((String, ThreadRuntime) -> Void)?
    var onViewed: ((String) -> Void)?
    private let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    private let queue = DispatchQueue(label: "orbit.activity.database", qos: .utility)
    private let socketQueue = DispatchQueue(label: "orbit.activity.socket", qos: .utility)
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var clientID: String?
    private var desired = Set<String>()
    private var subscribed = Set<String>()
    private var initialSnapshots = Set<String>()
    private var requestedAt: [String: Date] = [:]
    private var stopped = false
    private var poller: DispatchSourceTimer?
    private var readWatcher: DispatchSourceFileSystemObject?
    private var pendingReadPoll: DispatchWorkItem?
    private var lastPollAt = Date.distantPast
    private let startTime = Int(Date().timeIntervalSince1970)
    private var statuses: [String: ThreadRuntime] = [:]
    private var requestLists: [String: [[String: Any]]] = [:]
    func start() {
        let poller = DispatchSource.makeTimerSource(queue: queue)
        poller.schedule(deadline: .now(), repeating: 3, leeway: .milliseconds(300))
        poller.setEventHandler { [weak self] in self?.poll() }; self.poller = poller; poller.resume()
        queue.async { [weak self] in self?.armReadWatcher() }
        socketQueue.async { [weak self] in self?.connectAndRead() }
    }
    func stop() {
        poller?.cancel()
        queue.async { self.pendingReadPoll?.cancel(); self.readWatcher?.cancel(); self.readWatcher = nil }
        lock.lock(); stopped = true; let socket = fd; fd = -1; lock.unlock()
        if socket >= 0 { Darwin.shutdown(socket, SHUT_RDWR); Darwin.close(socket) }
    }
    private func query(_ name: String, _ sql: String, arguments: [String] = []) throws -> [[String: String]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(home + "/" + name, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }; throw QueryError.message("会话记录暂不可读")
        }
        defer { sqlite3_close(db) }; sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw QueryError.message("Codex 会话结构已变化") }
        defer { sqlite3_finalize(statement) }
        for (index, value) in arguments.enumerated() {
            _ = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        var rows: [[String: String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw QueryError.message("会话记录暂忙，稍后重试") }
            var row: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                if let key = sqlite3_column_name(statement, column), let value = sqlite3_column_text(statement, column) {
                    row[String(cString: key)] = String(cString: value)
                }
            }
            rows.append(row)
        }
        return rows
    }
    private func poll() {
        lastPollAt = Date()
        if readWatcher == nil { armReadWatcher() }
        do {
            let metadata = try query("state_5.sqlite", "SELECT id, COALESCE(name,title) AS title FROM threads WHERE archived=0 AND source NOT LIKE '%subAgent%' AND attached_thread_parent_id IS NULL")
            let names = Dictionary(uniqueKeysWithValues: metadata.compactMap { row -> (String, String)? in guard let id = row["id"] else { return nil }; return (id, row["title"] ?? "Codex 会话") })
            func sessions(_ rows: [[String: String]]) -> [ActivitySession] {
                rows.compactMap { row in
                    guard let id = row["thread_id"], let turn = row["turn_id"], let title = names[id] else { return nil }
                    return ActivitySession(id: turn, threadID: id, title: title, ordinal: Int64(row["rollout_ordinal"] ?? "") ?? 0, completedAt: Double(row["completed_at"] ?? "").map { Date(timeIntervalSince1970: $0) })
                }
            }
            let active = sessions(try query("thread_history_1.sqlite", "SELECT thread_id,turn_id,rollout_ordinal,completed_at FROM thread_turns WHERE status='inProgress'"))
            let completed = sessions(try query("thread_history_1.sqlite", "SELECT thread_id,turn_id,rollout_ordinal,completed_at FROM thread_turns WHERE status='completed' AND completed_at>=\(startTime) ORDER BY completed_at DESC"))
            lock.lock(); desired = Set(active.map(\.threadID)); lock.unlock()
            reconcile()
            let attention = try asyncAttention(active + completed)
            let through = try readWatermarks(active + completed)
            DispatchQueue.main.async { self.onDatabase?(active, completed, attention, through, Self.legacyUnreadState(), nil) }
        } catch {
            DispatchQueue.main.async { self.onDatabase?([], [], [], [:], nil, error.localizedDescription) }
        }
    }
    static func legacyUnreadState() -> Set<String>? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/.codex-global-state.json")
        guard let data = try? Data(contentsOf: path), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = root["electron-thread-read-state-v1"] as? [String: Any], state["version"] as? Int == 1,
              let identities = state["unreadByIdentity"] as? [String: Any] else { return nil }
        var result = Set<String>(), found = false
        for value in identities.values {
            guard let hosts = value as? [String: Any] else { continue }
            for (host, entries) in hosts where host.hasPrefix("local:") {
                if let ids = entries as? [String] { found = true; result.formUnion(ids) }
            }
        }
        return found ? result : nil
    }
    private func armReadWatcher() {
        lock.lock(); let done = stopped; lock.unlock(); guard !done else { return }
        readWatcher?.cancel(); readWatcher = nil
        let descriptor = Darwin.open(home + "/.codex-global-state.json", O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.readWatcher?.data ?? []
            self.pendingReadPoll?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.poll() }
            self.pendingReadPoll = work
            self.queue.asyncAfter(deadline: .now() + max(0.12, 0.7 - Date().timeIntervalSince(self.lastPollAt)), execute: work)
            if flags.contains(.rename) || flags.contains(.delete) {
                self.readWatcher?.cancel(); self.readWatcher = nil
                self.queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.armReadWatcher() }
            }
        }
        readWatcher = source; source.resume()
    }
    private func readWatermarks(_ sessions: [ActivitySession]) throws -> [String: Int64] {
        let threads = Set(sessions.map(\.threadID))
        guard !threads.isEmpty else { return [:] }
        let receipts = try query("state_5.sqlite", "SELECT thread_id,first_unread_turn,last_published_turn FROM thread_read_receipts").filter { threads.contains($0["thread_id"] ?? "") }
        let turns = Array(Set(receipts.flatMap { [$0["first_unread_turn"], $0["last_published_turn"]].compactMap { $0 } }))
        guard !turns.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: turns.count).joined(separator: ",")
        let rows = try query("thread_history_1.sqlite", "SELECT thread_id,turn_id,rollout_ordinal FROM thread_turns WHERE turn_id IN (\(placeholders))", arguments: turns)
        let ordinals = Dictionary(rows.compactMap { row -> (String, Int64)? in guard let id = row["turn_id"], let number = Int64(row["rollout_ordinal"] ?? "") else { return nil }; return (id, number) }, uniquingKeysWith: max)
        var result: [String: Int64] = [:]
        for receipt in receipts {
            guard let thread = receipt["thread_id"] else { continue }
            if let unread = receipt["first_unread_turn"] {
                if let ordinal = ordinals[unread] { result[thread] = ordinal - 1 }
            } else if let published = receipt["last_published_turn"], let ordinal = ordinals[published] { result[thread] = ordinal }
        }
        return result
    }
    private func asyncAttention(_ active: [ActivitySession]) throws -> [AttentionRequest] {
        guard !active.isEmpty else { return [] }
        let sessions = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        var rows: [[String: String]] = []
        for session in sessions.values {
            rows.append(contentsOf: try query("thread_history_1.sqlite", "SELECT turn_id,item_json,created_at_ms FROM thread_items WHERE thread_id=? AND turn_id=? AND item_type IN ('agentMessage','userMessage') ORDER BY rollout_ordinal", arguments: [session.threadID, session.id]))
        }
        var requests: [String: AttentionRequest] = [:], answered = Set<String>()
        for row in rows {
            guard let turn = row["turn_id"], let session = sessions[turn], let data = row["item_json"]?.data(using: .utf8), let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if item["type"] as? String == "agentMessage", let id = item["id"] as? String, let questions = item["questions"] as? [Any] {
                for index in questions.indices {
                    let key = session.threadID + ":async:" + id + ":" + String(index)
                    requests[key] = AttentionRequest(key: key, session: session, createdAt: Double(row["created_at_ms"] ?? "").map { Date(timeIntervalSince1970: $0 / 1000) })
                }
            }
            if item["type"] as? String == "userMessage", let content = item["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if let start = text.range(of: "<send_user_message_question_reply>"), let end = text.range(of: "</send_user_message_question_reply>", range: start.upperBound..<text.endIndex),
                   let bytes = text[start.upperBound..<end.lowerBound].data(using: .utf8), let replies = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] {
                    for reply in replies {
                        guard let id = reply["questionItemId"] as? String, let encoded = id.data(using: .utf8), let parts = try? JSONSerialization.jsonObject(with: encoded) as? [Any], parts.count == 3,
                              parts[0] as? String == "request_user_input_async", let itemID = parts[1] as? String, let index = parts[2] as? Int else { continue }
                        answered.insert(session.threadID + ":async:" + itemID + ":" + String(index))
                    }
                }
            }
        }
        return requests.filter { !answered.contains($0.key) }.map(\.value)
    }
    @discardableResult private func send(_ object: [String: Any]) -> Bool {
        guard let bytes = try? JSONSerialization.data(withJSONObject: object), bytes.count < 1_000_000 else { return false }
        var length = UInt32(bytes.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }; data.append(bytes)
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return false }
        return data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
    @discardableResult private func following(_ id: String, _ value: Bool) -> Bool {
        lock.lock(); let client = clientID; lock.unlock()
        guard let client else { return false }
        return send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1, "sourceClientId": client,
            "params": ["conversationId": id, "hostId": "local", "following": value]])
    }
    private func reconcile() {
        lock.lock()
        guard clientID != nil else { lock.unlock(); return }
        let removed = subscribed.subtracting(desired), added = desired.subtracting(subscribed)
        let retry = subscribed.intersection(desired).filter { !initialSnapshots.contains($0) && Date().timeIntervalSince(requestedAt[$0] ?? .distantPast) >= 6 }
        lock.unlock()
        for id in removed where following(id, false) {
            lock.lock(); subscribed.remove(id); initialSnapshots.remove(id); requestedAt.removeValue(forKey: id); lock.unlock()
        }
        for id in added where following(id, true) {
            lock.lock(); subscribed.insert(id); requestedAt[id] = Date(); lock.unlock()
        }
        for id in retry {
            following(id, false)
            if following(id, true) { lock.lock(); requestedAt[id] = Date(); lock.unlock() }
        }
    }
    private func read(_ socket: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        let success: Bool = data.withUnsafeMutableBytes { buffer in
            var received = 0
            while received < count {
                let n = Darwin.read(socket, buffer.baseAddress!.advanced(by: received), count - received)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                received += n
            }
            return true
        }
        return success ? data : nil
    }
    private func connectAndRead() {
        lock.lock(); let done = stopped; lock.unlock(); if done { return }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if socket < 0 { reconnect(); return }
        var noSignal: Int32 = 1; setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array((home + "/ipc/ipc.sock").utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(socket); reconnect(); return }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in path.withUnsafeBytes { memcpy(pointer, $0.baseAddress!, path.count) } }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { Darwin.close(socket); reconnect(); return }
        lock.lock(); fd = socket; clientID = nil; subscribed.removeAll(); initialSnapshots.removeAll(); requestedAt.removeAll(); lock.unlock()
        send(["type": "request", "requestId": UUID().uuidString, "version": 0, "method": "initialize", "params": ["clientType": "codex-orbit-monitor"], "timeoutMs": 5000])
        while let header = read(socket, count: 4) {
            let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (UInt32($1.offset) * 8) }
            guard length > 0, length <= 40_000_000, let data = read(socket, count: Int(length)), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            handle(object)
        }
        lock.lock(); if fd == socket { fd = -1; Darwin.close(socket) }; clientID = nil; subscribed.removeAll(); initialSnapshots.removeAll(); requestedAt.removeAll(); lock.unlock()
        statuses.removeAll(); requestLists.removeAll()
        DispatchQueue.main.async { self.onConnection?(false) }
        reconnect()
    }
    private func reconnect() {
        DispatchQueue.main.async { self.onConnection?(false) }
        socketQueue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.connectAndRead() }
    }
    private func handle(_ object: [String: Any]) {
        if object["type"] as? String == "client-discovery-request", let request = object["requestId"] {
            // This monitor never owns threads or handles commands, approvals, or user replies.
            send(["type": "client-discovery-response", "requestId": request, "response": ["canHandle": false]]); return
        }
        if object["method"] as? String == "initialize", object["resultType"] as? String == "success", let result = object["result"] as? [String: Any], let id = result["clientId"] as? String {
            lock.lock(); clientID = id; lock.unlock()
            DispatchQueue.main.async { self.onConnection?(true) }; reconcile(); return
        }
        if object["type"] as? String == "broadcast", object["method"] as? String == "thread-read-state-changed", object["version"] as? Int == 3,
           let params = object["params"] as? [String: Any], params["hostId"] as? String == "local", params["hasUnreadTurn"] as? Bool == false, let id = params["conversationId"] as? String {
            DispatchQueue.main.async { self.onViewed?(id) }
            queue.async { self.poll() }; return
        }
        guard object["type"] as? String == "broadcast", object["method"] as? String == "thread-stream-state-changed", object["version"] as? Int == 11,
              let params = object["params"] as? [String: Any], params["hostId"] as? String == "local", let id = params["conversationId"] as? String,
              let change = params["change"] as? [String: Any] else { return }
        lock.lock(); let wanted = desired.contains(id); lock.unlock(); guard wanted else { return }
        if change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any], let runtime = state["threadRuntimeStatus"] as? [String: Any] {
            lock.lock(); initialSnapshots.insert(id); lock.unlock()
            requestLists[id] = Self.sanitizeRequests(state["requests"])
            statuses[id] = Self.runtime(runtime)
        } else if change["type"] as? String == "patches", let patches = change["patches"] as? [[String: Any]] {
            for patch in patches {
                let path: [String]
                if let components = patch["path"] as? [Any] { path = components.map { String(describing: $0) } }
                else { path = (patch["path"] as? String ?? "").split(separator: "/").map(String.init) }
                if path.first == "requests" {
                    var requests = requestLists[id] ?? []
                    if path.count == 1 { requests = Self.sanitizeRequests(patch["value"]) }
                    else if path.count >= 2, let index = Int(path[1]) {
                        if path.count == 2, patch["op"] as? String == "remove", requests.indices.contains(index) { requests.remove(at: index) }
                        else if path.count == 2, let raw = patch["value"] as? [String: Any] {
                            let value = Self.sanitizeRequest(raw)
                            if patch["op"] as? String == "add", index <= requests.count { requests.insert(value, at: index) }
                            else if requests.indices.contains(index) { requests[index] = value }
                        } else if path.count == 3, path[2] == "completed", requests.indices.contains(index) { requests[index]["completed"] = patch["value"] }
                    }
                    requestLists[id] = requests; continue
                }
                guard path.first == "threadRuntimeStatus" else { continue }
                var runtime = statuses[id] ?? ThreadRuntime(type: "unknown", flags: [])
                if path.count == 1, let value = patch["value"] as? [String: Any] { runtime = Self.runtime(value) }
                else if path.count == 2, path[1] == "type", let value = patch["value"] as? String { runtime.type = value }
                else if path.count == 2, path[1] == "activeFlags" { runtime.flags = patch["value"] as? [String] ?? [] }
                else if path.count == 3, path[1] == "activeFlags", let index = Int(path[2]) {
                    if patch["op"] as? String == "remove", runtime.flags.indices.contains(index) { runtime.flags.remove(at: index) }
                    else if let value = patch["value"] as? String {
                        if index < runtime.flags.count { runtime.flags[index] = value } else if index == runtime.flags.count { runtime.flags.append(value) }
                    }
                }
                statuses[id] = runtime
            }
        }
        if var status = statuses[id] {
            status.attentionIDs = Self.attentionIDs(requestLists[id] ?? [])
            statuses[id] = status
            DispatchQueue.main.async { self.onRuntime?(id, status) }
        }
    }
    static func sanitizeRequest(_ raw: [String: Any]) -> [String: Any] {
        let params = raw["params"] as? [String: Any] ?? [:]
        let tool = params["tool"] as? String ?? ""
        let humanTools: Set<String> = ["request_environment_input", "request_onboarding_input", "request_option_picker", "setup_codex_step"]
        let complete = tool == "setup_codex_step" && (params["arguments"] as? [String: Any])?["step"] as? String == "complete"
        return ["id": raw["id"] ?? "", "method": raw["method"] ?? "", "completed": raw["completed"] ?? false, "needsHuman": humanTools.contains(tool) && !complete]
    }
    static func sanitizeRequests(_ raw: Any?) -> [[String: Any]] { (raw as? [[String: Any]] ?? []).map(sanitizeRequest) }
    static func attentionIDs(_ requests: [[String: Any]]) -> [String] {
        let methods: Set<String> = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "item/tool/requestUserInput", "item/tool/requestOptionPicker", "mcpServer/elicitation/request", "item/plan/requestImplementation", "applyPatchApproval", "execCommandApproval"]
        return requests.compactMap { request in
            guard request["completed"] as? Bool != true, let method = request["method"] as? String, methods.contains(method) || (method == "item/tool/call" && request["needsHuman"] as? Bool == true), let id = request["id"] else { return nil }
            return method + ":" + String(describing: id)
        }
    }
    static func runtime(_ object: [String: Any]) -> ThreadRuntime { ThreadRuntime(type: object["type"] as? String ?? "unknown", flags: object["activeFlags"] as? [String] ?? []) }
}
struct StatusLightBorder: View {
    @ObservedObject var activity: ActivityModel
    var cornerRadius: CGFloat = 14
    private let brightness: Double = 4
    @State private var lit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let events: [(Date, Color)] = [
            (activity.redBorderAt, Color(red: 1, green: 0.38, blue: 0.37)),
            (activity.yellowBorderAt, amber),
            (activity.greenBorderAt, Color(red: 0.37, green: 0.92, blue: 0.62))
        ]
        let event = events.max { $0.0 < $1.0 }!
        let key = "\(activity.redBorderPulse)-\(activity.yellowBorderPulse)-\(activity.greenBorderPulse)"
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            // A continuous falloff drawn entirely inside the perimeter; no outer glow or opaque inner rim.
            for step in stride(from: 20, through: 0, by: -1) {
                let depth = CGFloat(step) * 0.25
                let inset = 1.2 + depth
                let alpha = min(1, max(0, brightness) * 0.20 * exp(-Double(depth) / 1.35))
                let path = Path(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerRadius: max(0, cornerRadius - inset))
                context.stroke(path, with: .color(event.1.opacity(alpha)), lineWidth: 0.30)
            }
            let rim = Path(roundedRect: bounds.insetBy(dx: 0.85, dy: 0.85), cornerRadius: cornerRadius - 0.85)
            context.stroke(rim, with: .linearGradient(Gradient(colors: [event.1.opacity(min(1, max(0, brightness) * 0.80)), event.1.opacity(min(1, max(0, brightness) * 0.50))]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)), lineWidth: 1.05)
        }
        .opacity(CommandLine.arguments.contains("--render-band") ? 1 : (lit ? 1 : 0))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: lit)
        .allowsHitTesting(false).accessibilityHidden(true)
        .task(id: key) {
            lit = false
            let elapsed = max(0, Date().timeIntervalSince(event.0))
            guard elapsed < 3 else { return }
            if reduceMotion {
                lit = true
                try? await Task.sleep(nanoseconds: UInt64((3 - elapsed) * 1_000_000_000))
            } else {
                for phase in Int(elapsed / 0.5)..<6 {
                    lit = phase % 2 == 0
                    let remaining = max(0, event.0.addingTimeInterval(Double(phase + 1) * 0.5).timeIntervalSinceNow)
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    if Task.isCancelled { return }
                }
            }
            if !Task.isCancelled { lit = false }
        }
    }
}

struct SignalLamp: View {
    let name: String
    let color: Color
    let active: Bool
    let pulse: Int
    let triggeredAt: Date
    var phaseDuration: TimeInterval = 0.3
    let count: Int
    let action: () -> Void
    @State private var bright = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            Circle().fill(active ? color : ice.opacity(0.13))
                .opacity(active && !bright ? 0.25 : 1)
                .frame(width: 7, height: 7).frame(width: 18, height: 18).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(name)：\(count) 个会话")
            .help("\(name)：\(count) 个会话；新事件闪 5 次")
            .task(id: "\(active)-\(pulse)-\(reduceMotion)") {
                bright = true
                guard active, pulse > 0, !reduceMotion else { return }
                // Bound the flash window to the event time, so layout changes and reconnects never replay it.
                let elapsed = max(0, Date().timeIntervalSince(triggeredAt))
                guard elapsed < phaseDuration * 10 else { return }
                let firstPhase = Int(elapsed / phaseDuration)
                for phase in firstPhase..<10 {
                    bright = phase % 2 == 0
                    let deadline = triggeredAt.addingTimeInterval(Double(phase + 1) * phaseDuration)
                    let remaining = max(0, deadline.timeIntervalSinceNow)
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    if Task.isCancelled { return }
                }
                bright = true
            }
    }
}
struct TrafficLights: View {
    @ObservedObject var activity: ActivityModel
    @State private var selected: Int?
    var body: some View {
        VStack(spacing: 0) {
            SignalLamp(name: "需要你处理", color: Color(red: 1, green: 0.38, blue: 0.37), active: !activity.approvals.isEmpty, pulse: activity.redPulse, triggeredAt: activity.redTriggeredAt, phaseDuration: 0.5, count: activity.approvals.count) { selected = 0 }
            SignalLamp(name: "进行中", color: amber, active: activity.connected && !activity.running.isEmpty, pulse: activity.yellowPulse, triggeredAt: activity.yellowTriggeredAt, count: activity.running.count) { selected = 1 }
            SignalLamp(name: "新完成", color: Color(red: 0.37, green: 0.92, blue: 0.62), active: activity.completionAlertActive, pulse: activity.greenPulse, triggeredAt: activity.greenTriggeredAt, phaseDuration: 0.5, count: activity.pendingCompletions.count) { selected = 2 }
        }.padding(.horizontal, 3)
            .popover(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(selected == 0 ? "需要你处理" : selected == 1 ? "任务进行中" : "新完成的会话").font(.system(size: 12, weight: .semibold))
                    let sessions = selected == 0 ? activity.approvals : selected == 1 ? activity.running : activity.pendingCompletions
                    if sessions.isEmpty { Text("暂无会话").foregroundStyle(.secondary) }
                    ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                    ForEach(sessions) { session in
                        Button { if let url = URL(string: "codex://threads/\(session.threadID)"), NSWorkspace.shared.open(url) { activity.acceptViewed(session.threadID); selected = nil } } label: {
                            Text(session.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                    }
                    }.frame(height: min(210, CGFloat(sessions.count) * 34))
                    if selected == 2, !sessions.isEmpty { Button("知道了") { selected = nil } }
                    if !activity.connected { Text("实时监听未连接，将自动重连").foregroundStyle(amber) }
                    Text(selected == 1 ? "黄灯表示任务仍在进行。点击会话可打开 Codex。" : "圆点闪 5 秒后常亮；逐个打开会话后，清除对应提醒。").font(.system(size: 9)).foregroundStyle(.secondary)
                }.font(.system(size: 11)).padding(14).frame(width: 220).preferredColorScheme(.dark)
            }
    }
}

enum DoubleTapKey: String, CaseIterable, Identifiable {
    case shift, control, option, command
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var flag: CGEventFlags {
        switch self { case .shift: return .maskShift; case .control: return .maskControl; case .option: return .maskAlternate; case .command: return .maskCommand }
    }
}
struct ModifierTapDetector {
    var key: DoubleTapKey = .shift
    private var wasDown = false
    private var downAt: TimeInterval?
    private var firstRelease: TimeInterval?
    private var previousKeyCount: UInt32?
    init(key: DoubleTapKey = .shift) { self.key = key }
    mutating func sample(flags: CGEventFlags, keyCount: UInt32, now: TimeInterval) -> Bool {
        let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        let selected = flags.contains(key.flag)
        let other = !flags.intersection(modifiers.subtracting(key.flag)).isEmpty
        if other || previousKeyCount.map({ $0 != keyCount }) == true { firstRelease = nil; downAt = nil }
        previousKeyCount = keyCount
        defer { wasDown = selected }
        guard !other else { return false }
        if selected && !wasDown { downAt = now }
        if !selected && wasDown {
            guard let down = downAt, now - down <= 0.35 else { firstRelease = nil; downAt = nil; return false }
            downAt = nil
            if let previous = firstRelease, now - previous >= 0.05, now - previous <= 0.45 { firstRelease = nil; return true }
            firstRelease = now
        }
        if let previous = firstRelease, now - previous > 0.45 { firstRelease = nil }
        return false
    }
}
final class ModifierShortcutMonitor {
    private var timer: DispatchSourceTimer?
    private var detector = ModifierTapDetector()
    var onToggle: (() -> Void)?
    func configure(enabled: Bool, key: DoubleTapKey) {
        stop(); detector = ModifierTapDetector(key: key)
        guard enabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Read modifier bits and an aggregate counter only; never capture typed keys or text.
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let count = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
            if self.detector.sample(flags: flags, keyCount: count, now: ProcessInfo.processInfo.systemUptime) { self.onToggle?() }
        }
        self.timer = timer; timer.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
}

final class QuotaModel: ObservableObject {
    let activity = ActivityModel()
    @Published var shortcutEnabled = UserDefaults.standard.object(forKey: "shortcutEnabled") as? Bool ?? true
    @Published var shortcutKey = DoubleTapKey(rawValue: UserDefaults.standard.string(forKey: "shortcutKey") ?? "shift") ?? .shift
    @Published var news: ResetNews?
    @Published var newsError: String?
    @Published var newsLoading = false
    var newsFetched = UserDefaults.standard.object(forKey: "newsFetched") as? Date
    var newsRetryAt = UserDefaults.standard.object(forKey: "newsRetryAt") as? Date
    var newsStale: Bool {
        guard let news else { return false }
        let validUntil = news.expires ?? news.checked?.addingTimeInterval(1800)
        return validUntil.map { $0 < now } ?? true
    }
    var newsHeadline: String {
        let text = news?.headline(now: now) ?? (newsLoading ? "重置消息 · 读取中" : "重置消息 · 暂不可用")
        return news != nil && newsStale ? "旧 · " + text : text
    }
    var newsHelp: String { "来源 whenreset.dev；加赠预测为历史估算，非官方承诺。点击查看原文、适用范围和更新时间。" }
    func loadNewsCache() {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("local.codex.orbit/whenreset.json")
        for url in [cache, Bundle.main.url(forResource: "whenreset-cache", withExtension: "json")].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = try? ResetNews.parse(object) {
                news = value; newsError = "当前为缓存消息，等待在线确认"; break
            }
        }
    }
    func refreshNews(force: Bool = false) {
        guard !newsLoading, newsRetryAt.map({ Date() >= $0 }) ?? true,
              force || newsFetched.map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { return }
        newsLoading = true
        ResetNewsClient.read { result in
            DispatchQueue.main.async {
                self.newsLoading = false; self.newsFetched = Date()
                UserDefaults.standard.set(self.newsFetched, forKey: "newsFetched")
                switch result {
                case .success(let news): self.news = news; self.newsError = nil; self.newsRetryAt = nil
                    UserDefaults.standard.removeObject(forKey: "newsRetryAt")
                case .failure(let error):
                    if let limit = error as? NewsRateLimit {
                        self.newsRetryAt = limit.retryAt
                        UserDefaults.standard.set(limit.retryAt, forKey: "newsRetryAt")
                        self.newsError = "消息源暂时限流，将自动重试；当前保留缓存"
                    } else { self.newsError = error.localizedDescription }
                }
                self.onUpdate?()
            }
        }
    }
    @Published var snapshot: Snapshot?
    @Published var updated: Date?
    @Published var error: String?
    @Published var loading = false
    @Published var now = Date()
    @Published var compact = UserDefaults.standard.object(forKey: "compact") as? Bool ?? true
    @Published var glass = UserDefaults.standard.object(forKey: "glass") as? Double ?? 0.70
    var onUpdate: (() -> Void)?
    var first: QuotaWindow? { snapshot?.windows.first }
    var stale: Bool { error != nil || updated.map { now.timeIntervalSince($0) > 150 } ?? false }
    var freshness: String {
        guard let updated = updated else { return loading ? "正在连接 Codex…" : "等待额度数据" }
        if error != nil { return "刷新失败 · 保留上次读数" }
        let seconds = max(0, Int(now.timeIntervalSince(updated)))
        return seconds < 60 ? "刚刚更新" : "\(seconds / 60) 分钟前更新"
    }
    func refresh() {
        guard !loading else { return }
        loading = true
        if !CommandLine.arguments.contains("--render") { refreshNews() }
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try QuotaClient.read() }
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let value): self.snapshot = value; self.updated = Date(); self.now = Date(); self.error = nil
                case .failure(let error): self.error = error.localizedDescription
                }
                self.onUpdate?()
            }
        }
    }
}
let ice = Color(red: 0.88, green: 0.96, blue: 1)
let muted = Color(red: 0.65, green: 0.78, blue: 0.84)
let cyan = Color(red: 0.30, green: 0.91, blue: 0.96)
let amber = Color(red: 1, green: 0.75, blue: 0.35)
struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active; return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
struct Meter: View {
    let remaining: Double?
    let color: Color
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2), radius = min(71, min(size.width, size.height) / 2 - 3)
            for i in 0..<50 {
                let degrees = 135 + Double(i) * 5.4
                let radians = degrees * .pi / 180
                let major = i % 5 == 0
                let inner = radius - (major ? (radius < 40 ? 5 : 10) : (radius < 40 ? 3 : 6))
                var line = Path()
                line.move(to: CGPoint(x: center.x + cos(radians) * inner, y: center.y + sin(radians) * inner))
                line.addLine(to: CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius))
                let active = remaining.map { Double(i) < $0 / 2 } ?? false
                context.stroke(line, with: .color(active ? color : ice.opacity(0.16)), style: StrokeStyle(lineWidth: major ? (radius < 40 ? 1.7 : 2.5) : (radius < 40 ? 1 : 1.5), lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

struct SettingsButton: View {
    @ObservedObject var model: QuotaModel
    @State private var presented = false
    var body: some View {
        Button { presented.toggle() } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).help("设置").accessibilityLabel("设置")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                SettingsView(model: model, close: { presented = false })
            }
    }
}
struct SettingsView: View {
    @ObservedObject var model: QuotaModel
    var close: () -> Void
    @State private var pinned = UserDefaults.standard.object(forKey: "pinned") as? Bool ?? true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("悬浮窗设置").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("关闭设置")
            }
            Toggle("始终置顶", isOn: $pinned).toggleStyle(.switch)
                .onChange(of: pinned) { value in
                    guard let delegate = NSApp.delegate as? AppDelegate else { return }
                    delegate.pinned = value; delegate.panel.level = value ? .floating : .normal
                    UserDefaults.standard.set(value, forKey: "pinned")
                }
            Toggle("紧凑模式", isOn: $model.compact).toggleStyle(.switch)
                .onChange(of: model.compact) { value in
                    UserDefaults.standard.set(value, forKey: "compact")
                    (NSApp.delegate as? AppDelegate)?.updateSize()
                }
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text("玻璃透明度"); Spacer(); Text(model.glass < 0.5 ? "轻透" : model.glass < 0.85 ? "均衡" : "深色").foregroundStyle(.secondary) }
                Slider(value: $model.glass, in: 0.25...0.95).tint(cyan)
                    .accessibilityLabel("玻璃透明度")
                    .onChange(of: model.glass) { value in UserDefaults.standard.set(value, forKey: "glass") }
            }
            VStack(alignment: .leading, spacing: 9) {
                Toggle("双击按键显示 / 隐藏", isOn: $model.shortcutEnabled).toggleStyle(.switch)
                    .onChange(of: model.shortcutEnabled) { value in UserDefaults.standard.set(value, forKey: "shortcutEnabled"); (NSApp.delegate as? AppDelegate)?.configureShortcut() }
                Picker("双击按键", selection: $model.shortcutKey) { ForEach(DoubleTapKey.allCases) { key in Text(key.title).tag(key) } }
                    .disabled(!model.shortcutEnabled)
                    .onChange(of: model.shortcutKey) { value in UserDefaults.standard.set(value.rawValue, forKey: "shortcutKey"); (NSApp.delegate as? AppDelegate)?.configureShortcut() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("后台每 60 秒更新额度").foregroundStyle(.secondary)
                Text(model.freshness).foregroundStyle(model.stale ? amber : .secondary)
                if let error = model.error { Text(error).foregroundStyle(amber).fixedSize(horizontal: false, vertical: true) }
                Text(model.activity.connected ? "会话灯：实时监听已连接" : "会话灯：等待连接 Codex").foregroundStyle(.secondary)
                if let issue = model.activity.issue { Text(issue).foregroundStyle(amber) }
                if let error = model.newsError { Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.font(.system(size: 10))
            HStack {
                Spacer()
                Button("隐藏") { close(); (NSApp.delegate as? AppDelegate)?.panel.orderOut(nil) }
            }
            Button("退出 Codex Orbit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }.font(.system(size: 12)).padding(16).frame(width: 228).preferredColorScheme(.dark)
    }
}

struct CompactOrbitView: View {
    @ObservedObject var model: QuotaModel
    var showMenu: () -> Void
    var tint: Color { model.stale || (model.first?.remaining ?? 100) <= 20 ? amber : cyan }
    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "command").foregroundStyle(cyan)
                Text("Codex").fontWeight(.semibold)
                Spacer(minLength: 0)
                Button { model.refreshNews(force: true); model.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 21, height: 20) }
                    .buttonStyle(.plain).disabled(model.loading).help("立即刷新额度").accessibilityLabel("立即刷新额度")
                SettingsButton(model: model)
            }.font(.system(size: 10))
            HStack(spacing: 7) {
                ZStack {
                    Meter(remaining: model.first?.remaining, color: tint)
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(model.first.map { String(format: "%.0f", $0.remaining) } ?? "—")
                            .font(.system(size: 23, weight: .light, design: .rounded)).monospacedDigit()
                        if model.first != nil { Text("%").font(.system(size: 9)).foregroundStyle(muted) }
                    }
                }.frame(width: 57, height: 57)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.first?.label ?? "剩余额度").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(resetText).font(.system(size: 9)).monospacedDigit().foregroundStyle(muted).lineLimit(1).minimumScaleFactor(0.85)
                    if let extra = model.snapshot?.windows.dropFirst().first {
                        Text("\(extra.label) \(Int(extra.remaining))%")
                            .font(.system(size: 9)).foregroundStyle(extra.remaining <= 20 ? amber : muted)
                    }
                }
                Spacer(minLength: 0)
                TrafficLights(activity: model.activity)
            }
            NewsLine(model: model)

        }
        .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 10)
        .foregroundStyle(ice).frame(width: 200)
        .background { Glass().overlay(Color(red: 0.025, green: 0.065, blue: 0.10).opacity(model.glass)) }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { StatusLightBorder(activity: model.activity) }.preferredColorScheme(.dark)
    }
    var resetText: String {
        guard let reset = model.first?.reset else { return "重置时间未知" }
        if reset <= model.now { return "已到期 · 等待刷新" }
        let formatter = DateFormatter(); formatter.dateFormat = "M/d HH:mm"
        return "账户 \(formatter.string(from: reset))"
    }
}
struct RootView: View {
    @ObservedObject var model: QuotaModel
    var showMenu: () -> Void
    var body: some View {
        if model.compact { CompactOrbitView(model: model, showMenu: showMenu) }
        else { OrbitView(model: model, showMenu: showMenu) }
    }
}
struct OrbitView: View {
    @ObservedObject var model: QuotaModel
    var showMenu: () -> Void
    var tint: Color { model.stale || (model.first?.remaining ?? 100) <= 20 ? amber : cyan }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "command").font(.system(size: 15, weight: .medium)).foregroundStyle(cyan)
                Text("Codex").font(.system(size: 15, weight: .semibold))
                if let plan = model.snapshot?.plan { Text(plan.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(muted).padding(.horizontal, 5).padding(.vertical, 3).background(ice.opacity(0.08), in: RoundedRectangle(cornerRadius: 4)) }
                Spacer()
                Button { model.refreshNews(force: true); model.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26)
                }.buttonStyle(.plain).disabled(model.loading).help("立即刷新额度").accessibilityLabel("立即刷新额度")
                SettingsButton(model: model)
            }.padding(.horizontal, 20).padding(.top, 14)
            ZStack {
                Meter(remaining: model.first?.remaining, color: tint)
                VStack(spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(model.first.map { String(format: "%.0f", $0.remaining) } ?? "—")
                            .font(.system(size: 51, weight: .light, design: .rounded)).monospacedDigit()
                        if model.first != nil { Text("%").font(.system(size: 19, weight: .light)).foregroundStyle(muted) }
                    }
                    Text(model.first?.label ?? "剩余额度").font(.system(size: 11, weight: .medium)).lineLimit(1).foregroundStyle(muted)
                }.offset(y: -1)
                HStack(spacing: 5) {
                    Circle().fill(tint).frame(width: 4, height: 4)
                    Text(model.stale ? "数据待更新" : model.first != nil ? "可用额度" : "连接中")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(model.stale ? amber : muted)
                }.offset(y: 69)
            }.frame(height: 177).overlay(alignment: .trailing) { TrafficLights(activity: model.activity).padding(.trailing, 17) }
            VStack(spacing: 10) {
                NewsLine(model: model)
                if let secondary = model.snapshot?.windows.dropFirst().first {
                    HStack {
                        Text(secondary.label).foregroundStyle(muted)
                        Spacer()
                        Text(String(format: "%.0f%%", secondary.remaining)).monospacedDigit()
                    }.font(.system(size: 11))
                    GeometryReader { geometry in
                        Capsule().fill(ice.opacity(0.12)).overlay(alignment: .leading) {
                            Capsule().fill(secondary.remaining <= 20 ? amber : cyan).frame(width: geometry.size.width * secondary.remaining / 100)
                        }
                    }.frame(height: 3)
                }
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 10))
                    Text(resetText).font(.system(size: 11)).monospacedDigit()
                    Spacer(minLength: 0)
                }.foregroundStyle(muted)

            }.padding(.horizontal, 24).padding(.bottom, 18)
        }
        .foregroundStyle(ice)
        .frame(width: 300)
        .background { Glass().overlay(Color(red: 0.025, green: 0.065, blue: 0.10).opacity(model.glass)) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { StatusLightBorder(activity: model.activity, cornerRadius: 16) }
        .preferredColorScheme(.dark)
    }
    var resetText: String {
        guard let reset = model.first?.reset else { return "重置时间暂不可用" }
        if reset <= model.now { return "额度窗口已到期 · 等待刷新" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "M月d日 HH:mm"
        return "\(formatter.string(from: reset)) 重置"
    }
}
final class OrbitPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = QuotaModel()
    var panel: OrbitPanel!
    var status: NSStatusItem!
    var timer: Timer?
    var clock: Timer?
    let shortcut = ModifierShortcutMonitor()
    var pinned = UserDefaults.standard.object(forKey: "pinned") as? Bool ?? true
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--check-activity") {
            model.activity.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let activity = self.model.activity
                print("ACTIVITY: connected=\(activity.connected) running=\(activity.running.count) approvals=\(activity.approvals.count) completed=\(activity.completed.count) issue=\(activity.issue ?? "none") \(activity.diagnosticSummary)")
                activity.stop(); exit(activity.connected && activity.issue == nil ? 0 : 1)
            }; return
        }
        if CommandLine.arguments.contains("--check-news") {
            ResetNewsClient.read { result in
                switch result {
                case .success(let value): print("NEWS OK: \(value.headline(now: Date())) | pending=\(value.pending)"); exit(0)
                case .failure(let error): print("NEWS FAILED: \(error.localizedDescription)"); exit(1)
                }
            }; return
        }
        if CommandLine.arguments.contains("--check") {
            DispatchQueue.global().async {
                do { let value = try QuotaClient.read(); print("LIVE OK: \(value.windows.map { "\($0.label) \(Int($0.remaining))%" }.joined(separator: ", "))"); exit(0) }
                catch { print("LIVE FAILED: \(error.localizedDescription)"); exit(1) }
            }; return
        }
        model.loadNewsCache()
        model.activity.start()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "circle.dotted.circle", accessibilityDescription: "Codex Orbit")
        status.button?.title = " —"
        status.button?.target = self; status.button?.action = #selector(statusClicked)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        panel = OrbitPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 285), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Codex Orbit"; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = pinned ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: RootView(model: model, showMenu: { [weak self] in self?.popup() }))
        panel.contentView = host
        panel.setFrameAutosaveName("CodexOrbitPosition")
        if !panel.setFrameUsingName("CodexOrbitPosition"), let screen = NSScreen.main {
            let rect = screen.visibleFrame; panel.setFrameOrigin(NSPoint(x: rect.maxX - 324, y: rect.maxY - 335))
        }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }), let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 324, y: screen.visibleFrame.maxY - 335))
        }
        updateSize(); panel.orderFrontRegardless()
        if !CommandLine.arguments.contains("--render") { configureShortcut() }
        model.onUpdate = { [weak self] in self?.updateStatus(); self?.updateSize() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.model.refresh() }
        clock = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.model.now = Date(); self?.updateStatus() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        if let i = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > i + 1 {
            let path = CommandLine.arguments[i + 1]
            model.onUpdate = { [weak self] in
                guard let self else { return }; self.updateSize()
                guard !self.model.loading && !self.model.newsLoading else { return }
                if CommandLine.arguments.contains("--render-band") {
                    self.model.activity.yellowBorderAt = Date()
                    self.model.activity.yellowBorderPulse += 1
                }
                let latest = [self.model.activity.redBorderAt, self.model.activity.yellowBorderAt, self.model.activity.greenBorderAt].max() ?? .distantPast
                let elapsed = Date().timeIntervalSince(latest)
                let phase = max(0, Int(min(1000, elapsed) / 0.5))
                let delay = elapsed >= 0 && elapsed < 2.5 && phase % 2 == 1 ? Double(phase + 1) * 0.5 - elapsed + 0.05 : 0.05
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, delay)) { self.capture(path: path); NSApp.terminate(nil) }
            }
        }
        model.refresh()
    }
    func configureShortcut() {
        shortcut.onToggle = { [weak self] in self?.toggle() }
        shortcut.configure(enabled: model.shortcutEnabled, key: model.shortcutKey)
    }
    func updateSize() {
        let height = model.compact ? 116.0 : ((model.snapshot?.windows.count ?? 0) > 1 ? 309.0 : 272.0)
        let errorExtra = 0.0
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height - errorExtra, width: model.compact ? 200 : 300, height: height + errorExtra), display: true)
    }
    func updateStatus() {
        status.button?.title = model.first.map { " \(Int($0.remaining))%\(model.stale ? " !" : "")" } ?? " —"
        status.button?.toolTip = "Codex Orbit · 左键显示/隐藏，右键打开设置"
    }
    func menu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, state: Bool? = nil, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.tag = tag
            if let state { item.state = state ? .on : .off }; menu.addItem(item)
        }
        add(panel.isVisible ? "隐藏悬浮窗" : "显示悬浮窗", #selector(toggle))
        add(model.loading ? "正在刷新…" : "立即刷新", #selector(refresh))
        menu.items.last?.isEnabled = !model.loading
        menu.addItem(.separator())
        add("始终置顶", #selector(pin), state: pinned)
        add("紧凑模式", #selector(toggleCompact), state: model.compact)
        let transparency = NSMenuItem(title: "玻璃透明度", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (title, tag) in [("轻透", 35), ("均衡", 70), ("深色", 92)] {
            let item = NSMenuItem(title: title, action: #selector(setGlass(_:)), keyEquivalent: ""); item.target = self; item.tag = tag
            item.state = Int((model.glass * 100).rounded()) == tag ? .on : .off; submenu.addItem(item)
        }
        transparency.submenu = submenu; menu.addItem(transparency)
        menu.addItem(.separator())
        let info = NSMenuItem(title: "每 60 秒刷新 · 拖动空白处移动", action: nil, keyEquivalent: ""); menu.addItem(info)
        add("退出 Codex Orbit", #selector(quit))
        return menu
    }
    func popup() {
        let m = menu(); m.popUp(positioning: nil, at: NSPoint(x: panel.contentView!.bounds.width - 26, y: panel.contentView!.bounds.height - 40), in: panel.contentView)
    }
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = status.button { let m = menu(); m.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 5), in: button) }
        else { toggle() }
    }
    @objc func toggle() { if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() } }
    @objc func refresh() { model.refreshNews(force: true); model.refresh() }
    @objc func toggleCompact() { model.compact.toggle(); UserDefaults.standard.set(model.compact, forKey: "compact"); updateSize() }
    @objc func woke() { model.refresh() }
    @objc func pin() { pinned.toggle(); panel.level = pinned ? .floating : .normal; UserDefaults.standard.set(pinned, forKey: "pinned") }
    @objc func setGlass(_ sender: NSMenuItem) { model.glass = Double(sender.tag) / 100; UserDefaults.standard.set(model.glass, forKey: "glass") }
    @objc func quit() { NSApp.terminate(nil) }
    func capture(path: String) {
        guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)); print("RENDER OK: \(path)") }
    }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); clock?.invalidate(); shortcut.stop(); model.activity.stop() }
}
if CommandLine.arguments.contains("--test") {
    var checks = 0
    func check(_ condition: Bool, _ label: String) { checks += 1; if !condition { print("FAIL: \(label)"); exit(1) } }
    check(QuotaWindow.parse(["usedPercent": 42, "windowDurationMins": 10080])?.remaining == 58, "usage is inverted")
    check(QuotaWindow.parse(["usedPercent": 0])?.remaining == 100, "zero used is full")
    check(QuotaWindow.parse(["usedPercent": 110])?.remaining == 0, "overrun clamps")
    check(QuotaWindow.parse(["windowDurationMins": 300]) == nil, "missing usage is unknown")
    check(QuotaWindow.parse(["usedPercent": Double.nan]) == nil, "nonfinite usage rejected")
    check(QuotaWindow.parse(["usedPercent": true]) == nil, "boolean usage rejected")
    check(QuotaWindow.parse(["usedPercent": "42"]) == nil, "string usage rejected")
    let bucket: [String: Any] = ["primary": ["usedPercent": 42, "windowDurationMins": 10080], "secondary": ["usedPercent": 99, "windowDurationMins": 300]]
    let value = try! Snapshot.parse(["rateLimitsByLimitId": ["codex": bucket], "rateLimits": ["primary": ["usedPercent": 2]]])
    check(value.windows.count == 2 && value.windows[0].remaining == 58 && value.windows[1].remaining == 1, "correct bucket and both windows")
    do { _ = try Snapshot.parse([:]); check(false, "empty response rejected") } catch {}
    do { _ = try Snapshot.parse(["rateLimits": [:]]); check(false, "unknown never becomes zero") } catch {}

    let instant = ResetNews.date("2026-10-29T08:00:00Z")!
    let future = "2026-10-30T08:00:00Z"
    let oldEvent: [String: Any] = ["id": "done", "provider": "codex", "landedAt": "2026-10-28T08:00:00Z", "type": "reset", "scope": "all", "sources": [["role": "landed", "url": "https://x.com/thsottiaux/status/123"]]]
    func feed(_ watch: [String: Any], _ events: [[String: Any]] = []) -> [String: Any] {
        ["dataSchemaVersion": "public-api-1", "watch": ["codex": watch], "events": events,
         "stats": ["codex": ["estimatedNextAt": future]]]
    }
    let closed = try! ResetNews.parse(feed(["open": false, "scheduledAt": future], [oldEvent]), now: instant)
    check(!closed.pending && closed.scheduled == nil && closed.headline(now: instant).contains("预测"), "closed watch never becomes an official preview")
    let upcoming = try! ResetNews.parse(feed(["open": true, "scheduledAt": future, "type": "reset"]), now: instant)
    check(upcoming.pending && upcoming.headline(now: instant).contains("预告") && upcoming.headline(now: instant).hasSuffix("前"), "future notice is a deadline not a promise")
    let due = try! ResetNews.parse(feed(["open": true, "scheduledAt": "2026-10-28T08:00:00Z"]), now: instant)
    check(due.headline(now: instant).contains("待确认"), "past preview is unconfirmed not completed")
    let completed = try! ResetNews.parse(feed(["open": true, "scheduledAt": future, "completedEventId": "done"], [oldEvent]), now: instant)
    check(!completed.pending, "confirmed event closes old announcement")
    let day = try! ResetNews.parse(feed(["open": true, "scheduledDay": "2026-10-30", "scheduledTimeZone": "America/Los_Angeles"]), now: instant)
    check(day.scheduled == nil && day.headline(now: instant).contains("时刻待定"), "day-only announcement never invents a precise time")
    let futurePost = try! ResetNews.parse(feed(["open": true, "scheduledAt": future, "at": future]), now: instant)
    check(!futurePost.pending, "future-dated unpublished notice ignored")
    check(ResetNews.sourceURL("file:///etc/passwd") == nil && ResetNews.sourceURL("https://example.com") == nil, "source URL allowlist")
    check(closed.latest != nil && closed.scopeText == "所有用户", "latest completed Codex record retained")
    do { _ = try ResetNews.parse(["dataSchemaVersion": "future-v2"]); check(false, "unsupported news schema rejected") } catch {}
    let noForecast = try! ResetNews.parse(["dataSchemaVersion": "public-api-1", "watch": [:], "events": []], now: instant)
    check(noForecast.headline(now: instant).contains("暂无预告"), "absence never invents a future reset")

    let activity = ActivityModel()
    let a = ActivitySession(id: "turn-a", threadID: "thread-a", title: "Test A")
    let b = ActivitySession(id: "turn-b", threadID: "thread-b", title: "Test B")
    let old = ActivitySession(id: "old-turn", threadID: "old-thread", title: "Historical")
    activity.acceptDatabase([a], completed: [old])
    check(activity.completed.isEmpty && activity.running.isEmpty, "initial history never creates a completion or unverified runtime alert")
    activity.acceptRuntime(a.threadID, ThreadRuntime(type: "active", flags: ["waitingOnApproval"]))
    check(activity.approvals.count == 1 && activity.running.isEmpty, "approval is red not yellow for the same session")
    let redPulse = activity.redPulse
    activity.acceptRuntime(a.threadID, ThreadRuntime(type: "active", flags: ["waitingOnApproval"]))
    check(activity.redPulse == redPulse, "unchanged approval does not restart five flashes")
    activity.acceptDatabase([a,b], completed: [old])
    activity.acceptRuntime(b.threadID, ThreadRuntime(type: "active", flags: []))
    check(activity.approvals.count == 1 && activity.running.count == 1, "independent red and yellow sessions coexist")
    activity.acceptRuntime(a.threadID, ThreadRuntime(type: "active", flags: []))
    check(activity.approvals.isEmpty && activity.running.count == 2, "resolved approval returns to running")
    activity.acceptDatabase([b], completed: [old,a])
    check(activity.completed == [a] && activity.greenPulse == 1, "only new explicit completion creates green event")
    activity.acceptDatabase([b], completed: [old,a])
    check(activity.greenPulse == 1 && activity.completed.count == 1, "completion replay does not flash again")
    activity.acceptViewed(a.threadID); activity.acceptDatabase([b], completed: [old,a])
    check(activity.completed.isEmpty && activity.greenPulse == 1, "acknowledged completion stays cleared")
    let previousPulse = activity.yellowPulse
    activity.acceptDatabase([], completed: [], issue: "temporary database lock")
    check(activity.running.count == 1 && activity.yellowPulse == previousPulse, "transient read failure preserves state without new flashing")
    activity.acceptRuntime(b.threadID, ThreadRuntime(type: "idle", flags: ["waitingOnApproval"]))
    check(activity.approvals.isEmpty && activity.running.isEmpty, "idle runtime cannot retain a stale approval flag")

    let headerFixture = "HTTP/2 200\r\nreport-to: {\"group\":\"network\"}\r\ncontent-type: application/json\r\n\r\n{\"dataSchemaVersion\":\"public-api-1\",\"watch\":{},\"events\":[]}".replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\n", with: "\n")
    if let end = headerFixture.range(of: "\r\n\r\n", options: .backwards), let bytes = headerFixture[end.upperBound...].data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
        check((try? ResetNews.parse(object)) != nil, "JSON-valued HTTP headers are excluded from body parsing")
    } else { check(false, "HTTP body fixture parses") }
    activity.acceptRuntime(b.threadID, ThreadRuntime(type: "active", flags: ["waitingOnApproval"]))
    let reconnectPulse = activity.redPulse
    activity.acceptConnection(false)
    check(activity.approvals.isEmpty && activity.running.isEmpty, "disconnection invalidates visible runtime classifications")
    activity.acceptConnection(true)
    check(activity.approvals.isEmpty && activity.running.isEmpty, "reconnection never relights an old approval before a fresh snapshot")
    activity.acceptRuntime(b.threadID, ThreadRuntime(type: "active", flags: ["waitingOnApproval"]))
    check(activity.approvals.count == 1 && activity.redPulse == reconnectPulse, "same approval snapshot after reconnect does not replay flashes")
    activity.acceptRuntime(b.threadID, ThreadRuntime(type: "active", flags: []))
    check(activity.approvals.isEmpty && activity.running.count == 1, "fresh resolved approval removes obsolete red state")
    check(ResetNewsClient.retryDelay("90", now: instant) == 90, "numeric Retry-After")
    check(ResetNewsClient.retryDelay("Thu, 29 Oct 2026 08:02:00 GMT", now: instant) == 120, "HTTP-date Retry-After")
    check(ResetNewsClient.retryDelay("invalid", now: instant) == 300, "invalid Retry-After uses bounded fallback")

    let alerts = ActivityModel()
    alerts.acceptDatabase([], completed: [])
    alerts.acceptDatabase([], completed: [a,b])
    check(alerts.completionAlertActive && alerts.pendingCompletions.count == 2, "two completed sessions remain unread")
    let pulseBeforeView = alerts.greenPulse
    alerts.acceptViewed(a.threadID)
    check(alerts.completed == [b] && alerts.completionAlertActive, "opening one completion does not clear another session")
    alerts.acceptDatabase([], completed: [a,b])
    check(alerts.greenPulse == pulseBeforeView && alerts.completed == [b], "opened completion cannot relight from polling")
    alerts.acceptViewed(b.threadID)
    check(alerts.completed.isEmpty && !alerts.completionAlertActive, "green extinguishes only when all completed sessions were viewed")
    let laterA = ActivitySession(id: "later-a", threadID: a.threadID, title: a.title, ordinal: 100, completedAt: Date().addingTimeInterval(1))
    alerts.acceptDatabase([], completed: [a,b,laterA])
    check(alerts.completionAlertActive && alerts.completed == [laterA], "a later completion in an already viewed thread is a new unread event")
    let receipts = ActivityModel()
    let earlier = ActivitySession(id: "earlier", threadID: "same", title: "Same", ordinal: 10)
    let later = ActivitySession(id: "later", threadID: "same", title: "Same", ordinal: 20)
    receipts.acceptDatabase([], completed: [])
    receipts.acceptDatabase([], completed: [earlier,later], readThrough: ["same": 10])
    check(receipts.completed == [later], "old read receipt never clears a newer completion")
    check(receipts.pendingCompletions.count == 1, "multiple turns in one session appear once")
    receipts.acceptDatabase([], completed: [earlier,later], readThrough: ["same": 20])
    check(receipts.completed.isEmpty, "fresh read-through receipt clears the matching completed turns")
    let manual = ActivityModel()
    let input1 = AttentionRequest(key: "input-1", session: a)
    let input2 = AttentionRequest(key: "input-2", session: b)
    manual.acceptDatabase([a,b], completed: [], attention: [input1,input2])
    check(manual.approvals.count == 2, "async human questions trigger red independently of runtime approval flags")
    manual.acceptViewed(a.threadID)
    check(manual.approvals == [b], "viewing one manual-action session clears only its red reminder")
    manual.acceptViewed(b.threadID)
    check(manual.approvals.isEmpty, "red clears when every manual-action session was viewed")
    let input3 = AttentionRequest(key: "input-3", session: a)
    manual.acceptDatabase([a,b], completed: [], attention: [input1,input2,input3])
    check(manual.approvals == [a], "new manual request in a previously viewed session relights red")
    let methods = ["item/tool/requestUserInput", "item/tool/requestOptionPicker", "mcpServer/elicitation/request", "item/permissions/requestApproval"]
    check(NativeActivityMonitor.attentionIDs(methods.enumerated().map { ["id": $0.offset, "method": $0.element] }).count == 4, "inputs, options, elicitation, and approvals all require human attention")
    check(NativeActivityMonitor.attentionIDs([["id": 1, "method": "item/tool/call"], ["id": 2, "method": "item/tool/requestUserInput", "completed": true]]).isEmpty, "ordinary tool calls and resolved requests never create red alerts")
    let finishedQuestion = ActivityModel()
    let finishedSession = ActivitySession(id: "finished-q", threadID: "finished-thread", title: "Question", ordinal: 30)
    let pendingFinished = AttentionRequest(key: "finished-input", session: finishedSession)
    finishedQuestion.acceptDatabase([], completed: [], attention: [pendingFinished])
    check(finishedQuestion.approvals.count == 1, "unanswered async question remains visible after its turn completes")
    finishedQuestion.acceptDatabase([], completed: [], attention: [pendingFinished], readThrough: [finishedSession.threadID: 30])
    check(finishedQuestion.approvals.isEmpty, "persisted read-through also clears red attention after a missed IPC read event")
    let sameTurn = ActivityModel()
    sameTurn.acceptDatabase([finishedSession], completed: [], readThrough: [finishedSession.threadID: 30])
    sameTurn.acceptDatabase([finishedSession], completed: [], attention: [pendingFinished], readThrough: [finishedSession.threadID: 30])
    check(sameTurn.approvals.count == 1, "existing turn read watermark cannot consume a newly arriving manual request")
    sameTurn.acceptViewed(finishedSession.threadID)
    check(sameTurn.approvals.isEmpty, "viewing the new same-turn request acknowledges just the observed request")
    let secondSameTurn = AttentionRequest(key: "second-same-turn", session: finishedSession)
    sameTurn.acceptDatabase([finishedSession], completed: [], attention: [pendingFinished,secondSameTurn], readThrough: [finishedSession.threadID: 30])
    check(sameTurn.approvals.count == 1, "another same-turn request relights red despite unchanged persisted read watermark")
    let nativeSameTurn = ActivityModel()
    nativeSameTurn.acceptDatabase([finishedSession], completed: [], readThrough: [finishedSession.threadID: 30])
    nativeSameTurn.acceptRuntime(finishedSession.threadID, ThreadRuntime(type: "active", flags: ["waitingOnUserInput"], attentionIDs: ["native-new-request"]))
    check(nativeSameTurn.approvals.count == 1, "native request arriving after a turn was read remains visible")
    let uiState = ActivityModel()
    let screenshotSession = ActivitySession(id: "screenshot-complete", threadID: "opened-on-desktop", title: "Opened", ordinal: 3040, completedAt: Date().addingTimeInterval(-10))
    uiState.acceptDatabase([], completed: [], legacyUnread: [screenshotSession.threadID])
    uiState.acceptDatabase([], completed: [screenshotSession], readThrough: [screenshotSession.threadID: 0], legacyUnread: [screenshotSession.threadID])
    check(uiState.completionAlertActive, "desktop unread completion illuminates green")
    uiState.acceptDatabase([], completed: [screenshotSession], readThrough: [screenshotSession.threadID: 0], legacyUnread: [])
    check(!uiState.completionAlertActive, "actual desktop read flag clears green even when SQLite receipt remains stale")
    let lateStore = ActivityModel()
    lateStore.acceptDatabase([], completed: [], legacyUnread: [])
    lateStore.acceptDatabase([], completed: [screenshotSession], legacyUnread: [])
    check(!lateStore.completionAlertActive, "already-open conversation does not remain green after completion")
    lateStore.acceptDatabase([], completed: [screenshotSession], legacyUnread: nil)
    check(!lateStore.completionAlertActive, "temporary unread-store replacement cannot relight an already-read completion")
    lateStore.acceptDatabase([], completed: [screenshotSession], legacyUnread: [screenshotSession.threadID])
    check(lateStore.completionAlertActive, "late desktop unread publication restores a completion instead of losing it")
    let setup = NativeActivityMonitor.sanitizeRequest(["id": "setup", "method": "item/tool/call", "params": ["tool": "request_onboarding_input"]])
    check(NativeActivityMonitor.attentionIDs([setup]).count == 1, "onboarding/environment prompts also require human attention")
    var detector = ModifierTapDetector()
    _ = detector.sample(flags: [], keyCount: 0, now: 0)
    _ = detector.sample(flags: .maskShift, keyCount: 0, now: 0.1)
    _ = detector.sample(flags: [], keyCount: 0, now: 0.2)
    _ = detector.sample(flags: .maskShift, keyCount: 0, now: 0.3)
    check(detector.sample(flags: [], keyCount: 0, now: 0.4), "double Shift toggles once")
    check(!detector.sample(flags: [], keyCount: 0, now: 0.5), "held release state does not retrigger")
    var typing = ModifierTapDetector()
    _ = typing.sample(flags: .maskShift, keyCount: 0, now: 0)
    _ = typing.sample(flags: .maskShift, keyCount: 1, now: 0.1)
    _ = typing.sample(flags: [], keyCount: 1, now: 0.2)
    _ = typing.sample(flags: .maskShift, keyCount: 1, now: 0.3)
    check(!typing.sample(flags: [], keyCount: 1, now: 0.4), "using Shift while typing cannot count as double tap")
    var slow = ModifierTapDetector()
    _ = slow.sample(flags: .maskShift, keyCount: 0, now: 0)
    _ = slow.sample(flags: [], keyCount: 0, now: 0.1)
    _ = slow.sample(flags: .maskShift, keyCount: 0, now: 1)
    check(!slow.sample(flags: [], keyCount: 0, now: 1.1), "widely separated taps never toggle")
    var command = ModifierTapDetector(key: .command)
    _ = command.sample(flags: .maskCommand, keyCount: 0, now: 0)
    _ = command.sample(flags: [], keyCount: 0, now: 0.1)
    _ = command.sample(flags: .maskCommand, keyCount: 0, now: 0.2)
    check(command.sample(flags: [], keyCount: 0, now: 0.3), "configured modifier uses the selected key")
    let realtime = ActivityModel()
    realtime.acceptDatabase([], completed: [])
    realtime.acceptDatabase([], completed: [a])
    RunLoop.main.run(until: Date().addingTimeInterval(5.2))
    check(realtime.completionAlertActive, "green remains on after its five-second flashing window until viewed")
    realtime.acceptViewed(a.threadID)
    check(!realtime.completionAlertActive, "viewing the completed thread extinguishes its sticky green dot")
    print("PASS: \(checks) observed boundary and timing checks"); exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
