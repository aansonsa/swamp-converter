import Foundation

// JobRunner, continued: the job history, the per-job log files and the queue that survives a relaunch (queue.json / history.json, written with a short debounce).

extension JobRunner {
    var queueFileURL: URL { stateDirectory?.appendingPathComponent("queue.json") ?? AppPaths.queueFile }
    var historyFileURL: URL { stateDirectory?.appendingPathComponent("history.json") ?? AppPaths.historyFile }
    var jobLogsFolder: URL {
        guard let dir = stateDirectory else { return AppPaths.jobLogsDir }
        let url = dir.appendingPathComponent("Logs/Jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }



    /// Debounced like the queue: a flood of finished jobs (a watched folder) writes history.json once, not once per job.
    func persistHistory() {
        guard persistence else { return }
        historyWork?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in self?.writeHistory() } }
        historyWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func writeHistory() {
        historyWork = nil
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: historyFileURL, options: .atomic) }
    }

    func writeJobLog(_ job: Job) {
        guard persistence, !job.isAutomatic || job.state == .failed else { return }
        let name = "\(Util.safeFileName(job.title))-\(job.id.uuidString.prefix(8)).txt"
        try? job.logText.write(to: jobLogsFolder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Writes the unfinished queue and the history NOW (the app calls it from `applicationWillTerminate`, tests call it instead of waiting for the 0.3 s debounce).
    func flushPersistence() {
        guard persistence else { return }
        saveWork?.cancel()
        saveWork = nil
        writeQueue()
        if historyWork != nil { historyWork?.cancel(); writeHistory() }
    }

    func persistQueue() {
        guard persistence else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in self?.writeQueue() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func writeQueue() {
        let records: [QueuedJobRecord] = jobs.filter { !$0.state.isFinished }.map { j in
            var ov = j.overrides
            if let op = registry.operation(id: j.operationID) {   // never persist secrets
                for f in op.optionSchema(for: j.items).allFields where !f.persist { ov[f.key] = nil }
            }
            return QueuedJobRecord(id: j.id, batchID: j.batchID, operationID: j.operationID, title: j.title, itemPaths: j.items.map(\.url.path),
                                   linkURLs: j.isLinkJob ? j.links.map(\.url.absoluteString) : nil, overrides: ov, outputRules: j.outputRules, origin: j.origin, mode: j.mode,
                                   linkTitles: j.isLinkJob ? j.links.map { $0.title ?? "" } : nil)
        }
        if records.isEmpty { try? FileManager.default.removeItem(at: queueFileURL); return }
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: queueFileURL, options: .atomic) }
    }
}
