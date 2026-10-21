import Foundation

struct Project: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
}

struct Entry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var projectID: UUID
    var start: Date
    var end: Date?
    var description: String?

    func duration(now: Date = Date()) -> TimeInterval {
        (end ?? now).timeIntervalSince(start)
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

    init(projects: [Project], entries: [Entry]) {
        self.projects = projects
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        projects = try c.decode([Project].self, forKey: .projects)
        entries = try c.decode([Entry].self, forKey: .entries)
        goals = try c.decodeIfPresent([Goal].self, forKey: .goals) ?? []
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
        data.entries.first { $0.projectID == project.id && $0.end == nil }
    }

    var entries: [Entry] {
        data.entries.filter { $0.projectID == project.id }.sorted { $0.start > $1.start }
    }

    func total(since: Date, until: Date = .distantFuture, now: Date = Date()) -> TimeInterval {
        entries.reduce(0) { sum, e in
            let start = max(e.start, since)
            let end = min(e.end ?? now, until)
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

    func toggle() {
        runningEntry == nil ? start() : stop()
    }

    func start() {
        guard runningEntry == nil else { return }
        data.entries.append(Entry(projectID: project.id, start: Date()))
        save()
    }

    func stop() {
        guard let running = runningEntry, let i = data.entries.firstIndex(of: running) else { return }
        data.entries[i].end = Date()
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
        data.entries.append(Entry(projectID: project.id, start: start, end: end,
                                  description: Store.clean(description)))
        save()
        refreshGoals()
    }

    func updateEntry(id: UUID, start: Date, end: Date?, description: String?) {
        guard let i = data.entries.firstIndex(where: { $0.id == id }) else { return }
        data.entries[i].start = start
        data.entries[i].end = end
        data.entries[i].description = Store.clean(description)
        save()
        refreshGoals()
    }

    func delete(id: UUID) {
        data.entries.removeAll { $0.id == id }
        save()
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
