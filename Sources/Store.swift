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

    func duration(now: Date = Date()) -> TimeInterval {
        (end ?? now).timeIntervalSince(start)
    }
}

struct AppData: Codable {
    var version = 1
    var projects: [Project]
    var entries: [Entry]
}

/// Persists everything to a single JSON file in Application Support.
final class Store: ObservableObject {
    @Published private(set) var data: AppData

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
    }

    var project: Project { data.projects[0] }

    var runningEntry: Entry? {
        data.entries.first { $0.projectID == project.id && $0.end == nil }
    }

    var entries: [Entry] {
        data.entries.filter { $0.projectID == project.id }.sorted { $0.start > $1.start }
    }

    func total(since: Date, now: Date = Date()) -> TimeInterval {
        entries.reduce(0) { sum, e in
            let start = max(e.start, since)
            let end = e.end ?? now
            return sum + max(0, end.timeIntervalSince(start))
        }
    }

    func toggle() {
        if let running = runningEntry, let i = data.entries.firstIndex(of: running) {
            data.entries[i].end = Date()
        } else {
            data.entries.append(Entry(projectID: project.id, start: Date()))
        }
        save()
    }

    func renameProject(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        data.projects[0].name = trimmed
        save()
    }

    func addEntry(start: Date, end: Date) {
        data.entries.append(Entry(projectID: project.id, start: start, end: end))
        save()
    }

    func updateEntry(id: UUID, start: Date, end: Date?) {
        guard let i = data.entries.firstIndex(where: { $0.id == id }) else { return }
        data.entries[i].start = start
        data.entries[i].end = end
        save()
    }

    func delete(_ entry: Entry) {
        data.entries.removeAll { $0.id == entry.id }
        save()
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
