import Foundation

struct Project: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
}

/// One continuous stretch of work. Pausing ends a chunk; resuming starts a new one.
struct Chunk: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var start: Date
    var end: Date?
    var description: String?

    func duration(now: Date = Date()) -> TimeInterval {
        (end ?? now).timeIntervalSince(start)
    }
}

/// A unit of work made of one or more chunks, oldest first.
struct Entry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var projectID: UUID
    var description: String?
    var chunks: [Chunk]
    /// Pre-v4 files stored one chunk per entry, linked by pause/resume session. Read only.
    private(set) var legacySessionID: UUID?

    init(projectID: UUID, description: String? = nil, chunks: [Chunk]) {
        self.projectID = projectID
        self.description = description
        self.chunks = chunks
    }

    var start: Date { chunks.first?.start ?? .distantPast }
    var end: Date? { chunks.last?.end }
    var isRunning: Bool { chunks.contains { $0.end == nil } }

    func duration(now: Date = Date()) -> TimeInterval {
        chunks.reduce(0) { $0 + $1.duration(now: now) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, description, chunks
        case start, end, sessionID // legacy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        if let chunks = try c.decodeIfPresent([Chunk].self, forKey: .chunks) {
            self.chunks = chunks
        } else {
            chunks = [Chunk(start: try c.decode(Date.self, forKey: .start),
                            end: try c.decodeIfPresent(Date.self, forKey: .end))]
            legacySessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(projectID, forKey: .projectID)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(chunks, forKey: .chunks)
    }
}

/// A target number of hours between two moments.
struct Goal: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var projectID: UUID
    var name: String
    var hours: Double
    var start: Date
    /// Exclusive: the goal is over once this moment passes.
    var end: Date
    /// When the goal ends, roll it over to the next week instead of just archiving it.
    var repeats: Bool
    var archived = false
    var congratulated = false
    /// The goal this one was created from, so a repeating goal isn't rolled over twice.
    var previousGoalID: UUID?

    var target: TimeInterval { hours * 3600 }

    /// The same period shifted forward by the fewest whole weeks (at least one)
    /// that makes it still current at `now`.
    func nextPeriod(now: Date) -> (start: Date, end: Date) {
        let cal = Calendar.current
        var weeks = 1
        while true {
            let e = cal.date(byAdding: .day, value: 7 * weeks, to: end)!
            if e > now {
                return (cal.date(byAdding: .day, value: 7 * weeks, to: start)!, e)
            }
            weeks += 1
        }
    }
}

struct AppData: Codable {
    var version = 1
    var projects: [Project]
    var entries: [Entry]
    var goals: [Goal] = []
    /// Set while the timer is paused; resuming adds a chunk to this entry.
    var pausedEntryID: UUID?
    /// Pre-v4 equivalent of `pausedEntryID`. Read only.
    private(set) var legacyPausedSessionID: UUID?

    init(projects: [Project], entries: [Entry]) {
        self.projects = projects
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case version, projects, entries, goals, pausedEntryID
        case pausedSessionID // legacy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        projects = try c.decode([Project].self, forKey: .projects)
        entries = try c.decode([Entry].self, forKey: .entries)
        goals = try c.decodeIfPresent([Goal].self, forKey: .goals) ?? []
        pausedEntryID = try c.decodeIfPresent(UUID.self, forKey: .pausedEntryID)
        legacyPausedSessionID = try c.decodeIfPresent(UUID.self, forKey: .pausedSessionID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(projects, forKey: .projects)
        try c.encode(entries, forKey: .entries)
        try c.encode(goals, forKey: .goals)
        try c.encodeIfPresent(pausedEntryID, forKey: .pausedEntryID)
    }

    /// v3 → v4: entries that shared a pause/resume session become one entry with several chunks.
    /// In merged entries each old description moves onto its chunk.
    mutating func mergeLegacySessions() {
        var merged: [Entry] = []
        var indexBySession: [UUID: Int] = [:]
        for entry in entries.sorted(by: { $0.start < $1.start }) {
            guard let session = entry.legacySessionID else {
                merged.append(entry)
                continue
            }
            if let i = indexBySession[session] {
                if merged[i].chunks.count == 1 {
                    merged[i].chunks[0].description = merged[i].description
                    merged[i].description = nil
                }
                var chunk = entry.chunks[0]
                chunk.description = entry.description
                merged[i].chunks.append(chunk)
            } else {
                indexBySession[session] = merged.count
                merged.append(entry)
            }
            if session == legacyPausedSessionID {
                pausedEntryID = merged[indexBySession[session]!].id
            }
        }
        entries = merged
    }
}

/// Persists everything to a single JSON file in Application Support.
final class Store: ObservableObject {
    @Published private(set) var data: AppData
    /// Set when a goal is first met; the UI shows a congrats alert and clears it.
    @Published var metGoal: Goal?
    private var timer: Timer?

    static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TimeTracker", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("data.json")

    init() {
        if let raw = try? Data(contentsOf: Store.fileURL),
           let decoded = try? Store.decoder.decode(AppData.self, from: raw) {
            data = decoded
        } else {
            data = AppData(projects: [Project(name: "My Project")], entries: [])
            save()
        }
        if data.version < 3 {
            if data.version < 2 {
                seedFirstGoal()
            } else {
                // v2 stored `end` as the start of the last day, inclusive.
                for i in data.goals.indices {
                    data.goals[i].end = Calendar.current.date(byAdding: .day, value: 1, to: data.goals[i].end)!
                }
            }
            data.version = 3
            save()
        }
        if data.version < 4 {
            data.mergeLegacySessions()
            data.version = 4
            save()
        }
        refreshGoals()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshGoals()
        }
    }

    /// 15 hours from today through the end of next Wednesday.
    private func seedFirstGoal() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let nextWednesday = cal.nextDate(after: today, matching: DateComponents(weekday: 4),
                                         matchingPolicy: .nextTime)!
        data.goals.append(Goal(projectID: project.id, name: "Weekly goal", hours: 15, start: today,
                               end: cal.date(byAdding: .day, value: 1, to: nextWednesday)!, repeats: false))
    }

    var project: Project { data.projects[0] }

    var runningEntry: Entry? {
        data.entries.first { $0.projectID == project.id && $0.isRunning }
    }

    var pausedEntry: Entry? {
        guard runningEntry == nil, let id = data.pausedEntryID else { return nil }
        return data.entries.first { $0.id == id }
    }

    var isPaused: Bool { pausedEntry != nil }

    /// Time in the current (running or paused) entry, across pauses.
    func sessionDuration(now: Date = Date()) -> TimeInterval {
        (runningEntry ?? pausedEntry)?.duration(now: now) ?? 0
    }

    var entries: [Entry] {
        data.entries.filter { $0.projectID == project.id }.sorted { $0.start > $1.start }
    }

    func total(since: Date, until: Date = .distantFuture, now: Date = Date()) -> TimeInterval {
        entries.flatMap(\.chunks).reduce(0) { sum, c in
            let start = max(c.start, since)
            let end = min(c.end ?? now, until)
            return sum + max(0, end.timeIntervalSince(start))
        }
    }

    // MARK: goals

    var activeGoals: [Goal] {
        data.goals.filter { $0.projectID == project.id && !$0.archived }.sorted { $0.start < $1.start }
    }

    /// Every goal, newest first, for use as a template.
    var allGoals: [Goal] {
        data.goals.filter { $0.projectID == project.id }.sorted { $0.start > $1.start }
    }

    func progress(_ goal: Goal, now: Date = Date()) -> TimeInterval {
        total(since: goal.start, until: goal.end, now: now)
    }

    func hasSuccessor(_ goal: Goal) -> Bool {
        data.goals.contains { $0.previousGoalID == goal.id }
    }

    func saveGoal(_ goal: Goal) {
        var goal = goal
        if progress(goal) < goal.target { goal.congratulated = false }
        if let i = data.goals.firstIndex(where: { $0.id == goal.id }) {
            data.goals[i] = goal
        } else {
            data.goals.append(goal)
        }
        save()
        refreshGoals()
    }

    func deleteGoal(id: UUID) {
        data.goals.removeAll { $0.id == id }
        save()
    }

    /// Fires congrats for newly met goals, and archives (or rolls over) goals that have ended.
    func refreshGoals(now: Date = Date()) {
        var changed = false
        for i in data.goals.indices where !data.goals[i].archived {
            let goal = data.goals[i]
            if !goal.congratulated && progress(goal, now: now) >= goal.target {
                data.goals[i].congratulated = true
                changed = true
                if metGoal == nil { metGoal = data.goals[i] }
            }
            if now >= goal.end {
                data.goals[i].archived = true
                changed = true
                if goal.repeats && !hasSuccessor(goal) {
                    let period = goal.nextPeriod(now: now)
                    data.goals.append(Goal(projectID: goal.projectID, name: goal.name, hours: goal.hours,
                                           start: period.start, end: period.end, repeats: true,
                                           previousGoalID: goal.id))
                }
            }
        }
        if changed { save() }
    }

    /// Start when idle, pause when running, resume when paused.
    func toggle() {
        if runningEntry != nil { pause() } else if isPaused { resume() } else { start() }
    }

    func start() {
        guard runningEntry == nil else { return }
        data.pausedEntryID = nil
        data.entries.append(Entry(projectID: project.id, chunks: [Chunk(start: Date())]))
        save()
    }

    func pause() {
        guard let i = data.entries.firstIndex(where: { $0.id == runningEntry?.id }) else { return }
        data.entries[i].chunks[data.entries[i].chunks.count - 1].end = Date()
        data.pausedEntryID = data.entries[i].id
        save()
        refreshGoals()
    }

    func resume() {
        guard let i = data.entries.firstIndex(where: { $0.id == pausedEntry?.id }) else { return }
        data.pausedEntryID = nil
        data.entries[i].chunks.append(Chunk(start: Date()))
        save()
    }

    func stop() {
        data.pausedEntryID = nil
        if let i = data.entries.firstIndex(where: { $0.id == runningEntry?.id }) {
            data.entries[i].chunks[data.entries[i].chunks.count - 1].end = Date()
        }
        save()
        refreshGoals()
    }

    func renameProject(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        data.projects[0].name = trimmed
        save()
    }

    func addEntry(start: Date, end: Date, description: String?) {
        data.entries.append(Entry(projectID: project.id, description: Store.clean(description),
                                  chunks: [Chunk(start: start, end: end)]))
        save()
        refreshGoals()
    }

    func updateEntry(id: UUID, description: String?) {
        guard let i = data.entries.firstIndex(where: { $0.id == id }) else { return }
        data.entries[i].description = Store.clean(description)
        save()
    }

    func updateChunk(entryID: UUID, chunkID: UUID, start: Date, end: Date?, description: String?) {
        guard let i = data.entries.firstIndex(where: { $0.id == entryID }),
              let j = data.entries[i].chunks.firstIndex(where: { $0.id == chunkID }) else { return }
        data.entries[i].chunks[j].start = start
        data.entries[i].chunks[j].end = end
        data.entries[i].chunks[j].description = Store.clean(description)
        data.entries[i].chunks.sort { $0.start < $1.start }
        save()
        refreshGoals()
    }

    func delete(id: UUID) {
        data.entries.removeAll { $0.id == id }
        if data.pausedEntryID == id { data.pausedEntryID = nil }
        save()
    }

    /// Deleting an entry's only chunk deletes the entry.
    func deleteChunk(entryID: UUID, chunkID: UUID) {
        guard let i = data.entries.firstIndex(where: { $0.id == entryID }) else { return }
        data.entries[i].chunks.removeAll { $0.id == chunkID }
        if data.entries[i].chunks.isEmpty {
            delete(id: entryID)
        } else {
            save()
        }
    }

    /// Trims whitespace; blank becomes nil.
    private static func clean(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
            try Store.encoder.encode(data).write(to: Store.fileURL, options: .atomic)
        } catch {
            NSLog("TimeTracker save failed: \(error)")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
