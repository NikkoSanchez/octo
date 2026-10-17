import Foundation
import OctoCore

/// Token counts recorded by provider CLIs in their local session logs, bucketed by hour.
/// Read-only: no network, no credentials and no files other than the CLIs' own transcripts.
public struct UsageRecord: Equatable, Sendable {
    public var provider: HarnessID
    public var model: String
    public var session: String
    public var hour: Date
    /// Input served from the prompt cache.
    public var cachedInput: Int
    /// Input written to the prompt cache (billed as input, not served from cache).
    public var cacheWrite: Int
    /// Input neither read from nor written to the cache.
    public var uncachedInput: Int
    /// Output including reasoning.
    public var output: Int
    public var total: Int { cachedInput + cacheWrite + uncachedInput + output }
    public init(provider: HarnessID, model: String, session: String, hour: Date, cachedInput: Int = 0, cacheWrite: Int = 0, uncachedInput: Int = 0, output: Int = 0) {
        self.provider = provider; self.model = model; self.session = session; self.hour = hour
        self.cachedInput = cachedInput; self.cacheWrite = cacheWrite; self.uncachedInput = uncachedInput; self.output = output
    }
    mutating func add(_ other: UsageRecord) {
        cachedInput += other.cachedInput; cacheWrite += other.cacheWrite; uncachedInput += other.uncachedInput; output += other.output
    }
}

enum TranscriptLines {
    /// Invokes `body` for each line containing one of `markers`, skipping JSON decoding for the rest.
    static func each(_ data: Data, markers: [Data], _ body: ([String: Any]) -> Void) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var start = 0
            while start < buffer.count {
                var end = start
                while end < buffer.count && base[end] != 0x0A { end += 1 }
                if end > start {
                    let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start), count: end - start, deallocator: .none)
                    if markers.contains(where: { line.range(of: $0) != nil }),
                       let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { body(object) }
                }
                start = end + 1
            }
        }
    }
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func hour(_ date: Date) -> Date { Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600) }
    static func int(_ value: Any?) -> Int { max(0, (value as? NSNumber)?.intValue ?? 0) }
    static func aggregate(_ records: [UsageRecord]) -> [UsageRecord] {
        var merged: [String: UsageRecord] = [:], order: [String] = []
        for record in records {
            let key = "\(record.model)\u{0}\(record.session)\u{0}\(record.hour.timeIntervalSince1970)"
            if merged[key] == nil { order.append(key); merged[key] = record } else { merged[key]!.add(record) }
        }
        return order.compactMap { merged[$0] }.filter { $0.total > 0 }
    }
}

/// Claude Code transcripts (`~/.claude/projects/<project>/<session>.jsonl`, checked with 2.1.302):
/// each content block of a response is written as its own `assistant` line repeating the same
/// `message.id` and `usage`, so usage is counted once per message id.
public enum ClaudeTranscriptUsage {
    public static func records(_ data: Data, session fallback: String) -> [UsageRecord] {
        var seen = Set<String>(), records: [UsageRecord] = []
        TranscriptLines.each(data, markers: [Data(#""usage""#.utf8)]) { object in
            guard object["type"] as? String == "assistant", let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any], let date = TranscriptLines.date(object["timestamp"]) else { return }
            let id = (message["id"] as? String).map { $0 + ":" + (object["requestId"] as? String ?? "") }
            if let id, !seen.insert(id).inserted { return }
            records.append(UsageRecord(provider: .claude, model: message["model"] as? String ?? "unknown",
                                       session: object["sessionId"] as? String ?? fallback, hour: TranscriptLines.hour(date),
                                       cachedInput: TranscriptLines.int(usage["cache_read_input_tokens"]),
                                       cacheWrite: TranscriptLines.int(usage["cache_creation_input_tokens"]),
                                       uncachedInput: TranscriptLines.int(usage["input_tokens"]),
                                       output: TranscriptLines.int(usage["output_tokens"])))
        }
        return TranscriptLines.aggregate(records)
    }
}

/// Codex rollouts (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, checked with CLI 0.133–0.158):
/// `token_count` events carry cumulative `total_token_usage` and may repeat, so usage is the increase
/// in the cumulative total. `input_tokens` includes cached input; `output_tokens` includes reasoning.
/// The model comes from the most recent `turn_context`.
public enum CodexRolloutUsage {
    public static func records(_ data: Data, session fallback: String) -> [UsageRecord] {
        var model = "unknown", session = fallback, previous: [String: Int]?, records: [UsageRecord] = []
        let markers = [Data(#""token_count""#.utf8), Data(#""turn_context""#.utf8), Data(#""session_meta""#.utf8)]
        TranscriptLines.each(data, markers: markers) { object in
            let payload = object["payload"] as? [String: Any] ?? [:]
            switch object["type"] as? String {
            case "session_meta": if let id = payload["id"] as? String, !id.isEmpty { session = id }
            case "turn_context": if let value = payload["model"] as? String, !value.isEmpty { model = value }
            case "event_msg":
                guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
                      let date = TranscriptLines.date(object["timestamp"]) else { return }
                let keys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens"]
                var delta: [String: Int]
                if let total = info["total_token_usage"] as? [String: Any] {
                    let current = Dictionary(uniqueKeysWithValues: keys.map { ($0, TranscriptLines.int(total[$0])) })
                    if let previous, keys.allSatisfy({ current[$0]! >= previous[$0]! }) {
                        delta = Dictionary(uniqueKeysWithValues: keys.map { ($0, current[$0]! - previous[$0]!) })
                    } else if previous == nil {
                        delta = current
                    } else {
                        // A smaller cumulative total means the counter restarted; trust the last turn only.
                        let last = info["last_token_usage"] as? [String: Any] ?? [:]
                        delta = Dictionary(uniqueKeysWithValues: keys.map { ($0, TranscriptLines.int(last[$0])) })
                    }
                    previous = current
                } else { return }
                let cached = delta["cached_input_tokens"]!, write = delta["cache_write_input_tokens"]!
                records.append(UsageRecord(provider: .codex, model: model, session: session, hour: TranscriptLines.hour(date),
                                           cachedInput: cached, cacheWrite: write,
                                           uncachedInput: max(0, delta["input_tokens"]! - cached - write), output: delta["output_tokens"]!))
            default: break
            }
        }
        return TranscriptLines.aggregate(records)
    }
}

/// Scans local CLI session logs, re-reading only files whose size or modification date changed.
public actor UsageLedger {
    public struct Source: Sendable {
        public var provider: HarnessID
        public var directories: [URL]
        public init(provider: HarnessID, directories: [URL]) { self.provider = provider; self.directories = directories }
    }
    private struct Entry { var modified: Date; var size: Int; var records: [UsageRecord] }
    private let sources: [Source]
    private var cache: [String: Entry] = [:]
    public init(sources: [Source] = UsageLedger.defaultSources()) { self.sources = sources }

    public static func defaultSources(environment: [String: String] = ProcessInfo.processInfo.environment) -> [Source] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claude = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        let codex = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        return [Source(provider: .codex, directories: [codex.appendingPathComponent("sessions"), codex.appendingPathComponent("archived_sessions")]),
                Source(provider: .claude, directories: [claude.appendingPathComponent("projects")])]
    }

    /// Records from files modified at or after `since`; a file last written earlier cannot contain newer usage.
    public func records(since: Date) async -> [UsageRecord] {
        var result: [UsageRecord] = [], live = Set<String>()
        for source in sources {
            for file in Self.transcripts(in: source.directories) {
                if Task.isCancelled { return [] }
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modified = values.contentModificationDate, let size = values.fileSize else { continue }
                live.insert(file.path)
                guard modified >= since else { continue }
                if let entry = cache[file.path], entry.modified == modified, entry.size == size { result += entry.records; continue }
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
                let name = file.deletingPathExtension().lastPathComponent
                let records = source.provider == .claude ? ClaudeTranscriptUsage.records(data, session: name) : CodexRolloutUsage.records(data, session: name)
                cache[file.path] = Entry(modified: modified, size: size, records: records)
                result += records
            }
        }
        cache = cache.filter { live.contains($0.key) }
        return result.filter { $0.hour >= TranscriptLines.hour(since) }
    }

    private static func transcripts(in directories: [URL]) -> [URL] {
        directories.flatMap { directory -> [URL] in
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            return enumerator.compactMap { $0 as? URL }.filter {
                $0.pathExtension == "jsonl" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        }
    }
}

/// Aggregates for one time range. Pure so it can be tested without files.
public struct UsageSummary: Equatable, Sendable {
    public struct Provider: Identifiable, Equatable, Sendable {
        public var id: HarnessID
        public var tokens: Int
        public var sessions: Int
    }
    public struct Point: Identifiable, Equatable, Sendable {
        public var id: String { "\(provider.rawValue)-\(start.timeIntervalSince1970)" }
        public var start: Date
        public var provider: HarnessID
        public var tokens: Int
    }
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var provider: HarnessID?
        public var date: Date?
        public var tokens: Int
        public var share: Double
    }
    public var interval: DateInterval
    public var hourly: Bool
    public var total = 0, sessions = 0, cachedInput = 0, cacheWrite = 0, uncachedInput = 0, output = 0
    public var providers: [Provider] = []
    public var series: [Point] = []
    public var models: [Row] = []
    public var days: [Row] = []

    public init(records: [UsageRecord], interval: DateInterval, calendar: Calendar = .current) {
        self.interval = interval
        hourly = interval.duration <= 48 * 3600
        let first = TranscriptLines.hour(interval.start)
        let records = records.filter { $0.hour >= first && $0.hour <= interval.end }
        var providerTokens: [HarnessID: Int] = [:], providerSessions: [HarnessID: Set<String>] = [:]
        var modelTokens: [String: (HarnessID, Int)] = [:], bucketTokens: [Date: [HarnessID: Int]] = [:], dayTokens: [Date: Int] = [:]
        func bucket(_ date: Date) -> Date { hourly ? TranscriptLines.hour(date) : calendar.startOfDay(for: date) }
        for record in records {
            total += record.total; cachedInput += record.cachedInput; cacheWrite += record.cacheWrite
            uncachedInput += record.uncachedInput; output += record.output
            providerTokens[record.provider, default: 0] += record.total
            providerSessions[record.provider, default: []].insert(record.session)
            modelTokens[record.provider.rawValue + "\u{0}" + record.model, default: (record.provider, 0)].1 += record.total
            bucketTokens[bucket(record.hour), default: [:]][record.provider, default: 0] += record.total
            dayTokens[calendar.startOfDay(for: record.hour), default: 0] += record.total
        }
        sessions = providerSessions.values.reduce(0) { $0 + $1.count }
        let active = HarnessID.allCases.filter { providerTokens[$0] != nil }
        providers = active.map { Provider(id: $0, tokens: providerTokens[$0]!, sessions: providerSessions[$0]?.count ?? 0) }
            .sorted { $0.tokens > $1.tokens }
        // Every bucket in the range is present so empty periods draw as zero rather than interpolating.
        var cursor = bucket(interval.start), starts: [Date] = []
        while cursor <= interval.end {
            starts.append(cursor)
            guard let next = hourly ? cursor.addingTimeInterval(3600) : calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        series = active.flatMap { provider in starts.map { Point(start: $0, provider: provider, tokens: bucketTokens[$0]?[provider] ?? 0) } }
        let denominator = Double(max(total, 1))
        models = modelTokens.map { key, value in
            let model = String(key.split(separator: "\u{0}", maxSplits: 1).last ?? "")
            return Row(id: key, title: model, provider: value.0, tokens: value.1, share: Double(value.1) / denominator)
        }.sorted { ($0.tokens, $1.title) > ($1.tokens, $0.title) }
        days = dayTokens.map { Row(id: "\($0.key.timeIntervalSince1970)", title: "", date: $0.key, tokens: $0.value, share: Double($0.value) / denominator) }
            .sorted { $0.date! > $1.date! }
    }
}
