import Foundation

/// Structured log entry mirrored both to stdout (for Google Cloud Logging `jsonPayload`) and to the Xcode app via `/logs`.
struct ActivityLogEntry: Codable, Identifiable, Sendable {
    let id: String
    let timestampISO8601: String
    let severity: String
    let operation: String
    let message: String
    let durationSeconds: Double?
    let metadata: [String: String]
}

actor ActivityLogger {
    private let store: (any ObjectStore)?
    private let logObjectPath = "corpus/activity_log.json"
    private let maxEntries = 250
    private var entries: [ActivityLogEntry] = []
    private var didLoad = false

    init(store: (any ObjectStore)?) {
        self.store = store
    }

    func recentEntries() async -> [ActivityLogEntry] {
        await ensureLoaded()
        return entries
    }

    func record(
        severity: String = "INFO",
        operation: String,
        message: String,
        durationSeconds: Double? = nil,
        metadata: [String: String] = [:]
    ) async {
        await ensureLoaded()
        let entry = ActivityLogEntry(
            id: UUID().uuidString,
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            severity: severity,
            operation: operation,
            message: message,
            durationSeconds: durationSeconds,
            metadata: metadata
        )

        // Emit single-line structured JSON to stdout so Google Cloud Logging indexes `jsonPayload.*` automatically.
        var cloudPayload: [String: String] = metadata
        cloudPayload["severity"] = severity
        cloudPayload["time"] = entry.timestampISO8601
        cloudPayload["operation"] = operation
        cloudPayload["message"] = message
        if let durationSeconds {
            cloudPayload["durationSeconds"] = String(format: "%.2f", durationSeconds)
        }
        if let lineData = try? JSONEncoder().encode(cloudPayload),
           let line = String(data: lineData, encoding: .utf8) {
            print(line)
        }

        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        await persist()
    }

    private func ensureLoaded() async {
        guard !didLoad else { return }
        didLoad = true
        guard let store,
              let (data, _) = try? await store.read(logObjectPath),
              let saved = try? JSONDecoder().decode([ActivityLogEntry].self, from: data) else {
            return
        }
        entries = saved
    }

    private func persist() async {
        guard let store else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? await store.write(data, to: logObjectPath, contentType: "application/json")
        }
    }
}
