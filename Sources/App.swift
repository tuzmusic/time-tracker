import SwiftUI
import AppKit

@main
struct TimeTrackerApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        Window("Time Tracker", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 380, minHeight: 560)
        }
        .defaultSize(width: 380, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Start Timer") { store.start() }
                    .keyboardShortcut("n")
                    .disabled(store.runningEntry != nil || store.isPaused)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Stop Timer") { store.stop() }
                    .keyboardShortcut("s")
                    .disabled(store.runningEntry == nil && !store.isPaused)
            }
            CommandGroup(replacing: .printItem) {
                Button(store.isPaused ? "Resume Timer" : "Pause Timer") {
                    store.isPaused ? store.resume() : store.pause()
                }
                .keyboardShortcut("p")
                .disabled(store.runningEntry == nil && !store.isPaused)
            }
        }
    }
}

final class UIState: ObservableObject {
    @Published var editingName = false
    @Published var nameDraft = ""
    @Published var entryDraft: EntryDraft?
    @Published var selection: UUID?
    @Published var pendingDelete: UUID?
    /// Multi-chunk entries whose chunks are showing. Collapsed by default.
    @Published var expanded: Set<UUID> = []
    @Published var goalDraft: GoalDraft?
    @Published var pendingGoalDelete: UUID?
}

/// Backing state for the add/edit sheet. Edits a whole entry, one chunk, or (`entryID == nil`)
/// a new manual entry. A single-chunk entry edits its chunk's times directly.
final class EntryDraft: ObservableObject, Identifiable {
    let id = UUID()
    let entryID: UUID?
    /// The chunk whose times are being edited; nil for a new entry or a multi-chunk entry.
    let chunkID: UUID?
    /// Editing an entry rather than one of its chunks.
    let isEntry: Bool
    let isRunning: Bool
    let chunkCount: Int
    /// A single-chunk entry's own chunk description, passed through untouched.
    let chunkDescription: String?
    @Published var start: Date
    @Published var end: Date
    @Published var description: String
    @Published var confirmingDelete = false

    init(entry: Entry? = nil) {
        entryID = entry?.id
        isEntry = true
        isRunning = entry?.isRunning ?? false
        chunkCount = entry?.chunks.count ?? 1
        chunkID = chunkCount == 1 ? entry?.chunks.first?.id : nil
        chunkDescription = chunkCount == 1 ? entry?.chunks.first?.description : nil
        description = entry?.description ?? ""
        if let entry {
            start = entry.start
            end = entry.end ?? Date()
        } else {
            let now = Date()
            start = now.addingTimeInterval(-3600)
            end = now
        }
    }

    init(chunk: Chunk, of entry: Entry) {
        entryID = entry.id
        chunkID = chunk.id
        isEntry = false
        isRunning = chunk.end == nil
        chunkCount = entry.chunks.count
        chunkDescription = nil
        description = chunk.description ?? ""
        start = chunk.start
        end = chunk.end ?? Date()
    }

    var editsTimes: Bool { entryID == nil || chunkID != nil }

    var isValid: Bool {
        guard editsTimes else { return true }
        return isRunning ? start <= Date() : end > start
    }

    var title: String {
        entryID == nil ? "Add Entry" : isEntry ? "Edit Entry" : "Edit Chunk"
    }
}

struct EntrySheet: View {
    @ObservedObject var draft: EntryDraft
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.title).font(.headline)
            Form {
                TextField("Description", text: $draft.description, prompt: Text("Optional"))
                if draft.editsTimes {
                    DatePicker("Start", selection: $draft.start)
                    if draft.isRunning {
                        LabeledContent("End", value: "Running")
                    } else {
                        DatePicker("End", selection: $draft.end)
                        LabeledContent("Duration", value: durationText)
                    }
                } else {
                    LabeledContent("Chunks", value: "\(draft.chunkCount) — expand the entry to edit them")
                }
            }
            HStack {
                if draft.entryID != nil {
                    Button("Delete", role: .destructive) { draft.confirmingDelete = true }
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
        }
        .padding(20)
        .frame(width: 340)
        .confirmationDialog(draft.isEntry ? "Delete this entry?" : "Delete this chunk?",
                            isPresented: $draft.confirmingDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text(draft.isEntry && draft.chunkCount > 1
                 ? "All \(draft.chunkCount) chunks will be deleted. This can't be undone."
                 : "This can't be undone.")
        }
    }

    private var durationText: String {
        guard draft.isValid else { return "End must be after start" }
        let s = Int(draft.end.timeIntervalSince(draft.start))
        return String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    // Plain ObservableObject instead of @State: @State is a macro whose plugin ships
    // only with Xcode, and this builds with Command Line Tools alone.
    @StateObject private var ui = UIState()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(spacing: 0) {
                header(now: now)
                Divider()
                goalsSection(now: now)
                Divider()
                entryList(now: now)
                Divider()
                footer
            }
        }
        .sheet(item: $ui.entryDraft) { draft in
            EntrySheet(draft: draft, onSave: {
                if let entryID = draft.entryID {
                    if draft.isEntry { store.updateEntry(id: entryID, description: draft.description) }
                    if let chunkID = draft.chunkID {
                        store.updateChunk(entryID: entryID, chunkID: chunkID, start: draft.start,
                                          end: draft.isRunning ? nil : draft.end,
                                          description: draft.isEntry ? draft.chunkDescription : draft.description)
                    }
                } else {
                    store.addEntry(start: draft.start, end: draft.end, description: draft.description)
                }
                ui.entryDraft = nil
            }, onCancel: { ui.entryDraft = nil }, onDelete: {
                if let entryID = draft.entryID {
                    if draft.isEntry {
                        store.delete(id: entryID)
                    } else if let chunkID = draft.chunkID {
                        store.deleteChunk(entryID: entryID, chunkID: chunkID)
                    }
                }
                ui.entryDraft = nil
            })
        }
        .sheet(item: $ui.goalDraft) { draft in
            GoalSheet(draft: draft, templates: store.allGoals, onSave: {
                store.saveGoal(draft.makeGoal(projectID: store.project.id))
                ui.goalDraft = nil
            }, onCancel: { ui.goalDraft = nil }, onDelete: {
                if let id = draft.goalID { store.deleteGoal(id: id) }
                ui.goalDraft = nil
            })
        }
        .alert("Goal met! 🎉", isPresented: Binding(
            get: { store.metGoal != nil },
            set: { if !$0 { store.metGoal = nil } }
        ), presenting: store.metGoal) { goal in
            if store.hasSuccessor(goal) {
                Button("Nice") {}
            } else {
                Button("Set Up Next Goal…") {
                    let draft = GoalDraft(template: goal)
                    DispatchQueue.main.async { ui.goalDraft = draft }
                }
                Button("Not Now", role: .cancel) {}
            }
        } message: { goal in
            Text("You hit \(goal.hours.formatted()) hours for “\(goal.name)”.")
        }
    }

    private func header(now: Date) -> some View {
        VStack(spacing: 14) {
            if ui.editingName {
                TextField("Project name", text: $ui.nameDraft, onCommit: {
                    store.renameProject(ui.nameDraft)
                    ui.editingName = false
                })
                .textFieldStyle(.roundedBorder)
                .font(.title2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            } else {
                Text(store.project.name)
                    .font(.title2.weight(.semibold))
                    .onTapGesture(count: 2) {
                        ui.nameDraft = store.project.name
                        ui.editingName = true
                    }
                    .help("Double-click to rename")
            }

            Text(format(store.sessionDuration(now: now)))
                .font(.system(size: 44, weight: .light, design: .monospaced))
                .foregroundStyle(store.runningEntry == nil ? .secondary : .primary)
                .overlay(alignment: .bottom) {
                    if store.isPaused {
                        Text("Paused").font(.caption).foregroundStyle(.orange).offset(y: 14)
                    }
                }

            HStack(spacing: 10) {
                Button(action: store.toggle) {
                    Text(store.runningEntry != nil ? "Pause" : store.isPaused ? "Resume" : "Start")
                        .frame(width: 100)
                }
                .tint(store.runningEntry != nil ? .orange : .green)
                .keyboardShortcut(.space, modifiers: [])

                if store.runningEntry != nil || store.isPaused {
                    Button(action: store.stop) {
                        Text("Stop").frame(width: 100)
                    }
                    .tint(.red)
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            HStack(spacing: 24) {
                stat("Today", store.total(since: Calendar.current.startOfDay(for: now), now: now))
                if let goal = store.activeGoals.first(where: { $0.start <= now && now < $0.end }) {
                    let progress = store.progress(goal, now: now)
                    stat(goal.name, progress)
                    stat("To go", max(goal.target - progress, 0))
                }
            }
        }
        .padding(20)
    }

    private func goalsSection(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Goals").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    ui.goalDraft = GoalDraft(template: store.allGoals.first)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New goal")
            }
            ForEach(store.activeGoals) { goal in
                GoalRow(goal: goal, progress: store.progress(goal, now: now), now: now)
                    .onTapGesture(count: 2) { ui.goalDraft = GoalDraft(goal: goal) }
                    .contextMenu {
                        Button("Edit…") { ui.goalDraft = GoalDraft(goal: goal) }
                        Button("Delete", role: .destructive) { ui.pendingGoalDelete = goal.id }
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .confirmationDialog("Delete this goal?", isPresented: Binding(
            get: { ui.pendingGoalDelete != nil },
            set: { if !$0 { ui.pendingGoalDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = ui.pendingGoalDelete { store.deleteGoal(id: id) }
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func stat(_ label: String, _ value: TimeInterval) -> some View {
        VStack(spacing: 2) {
            Text(format(value, seconds: false)).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func entryList(now: Date) -> some View {
        List(selection: $ui.selection) {
            ForEach(groupedByDay(), id: \.day) { group in
                Section {
                    ForEach(group.entries) { entry in
                        if entry.chunks.count > 1 {
                            DisclosureGroup(isExpanded: expandedBinding(entry.id)) {
                                ForEach(entry.chunks.reversed()) { chunk in
                                    row(start: chunk.start, end: chunk.end, description: chunk.description,
                                        duration: chunk.duration(now: now), running: chunk.end == nil)
                                        .tag(chunk.id)
                                }
                            } label: {
                                entryRow(entry, now: now)
                            }
                            .tag(entry.id)
                        } else {
                            entryRow(entry, now: now).tag(entry.id)
                        }
                    }
                } header: {
                    HStack {
                        Text(group.day.formatted(.dateTime.weekday(.wide).month().day()))
                        Spacer()
                        Text(format(group.entries.reduce(0) { $0 + $1.duration(now: now) }, seconds: false))
                            .monospacedDigit()
                    }
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first {
                Button("Edit…") { edit(id) }
                Button("Delete", role: .destructive) { ui.pendingDelete = id }
            }
        } primaryAction: { ids in
            if let id = ids.first { edit(id) }
        }
        .onDeleteCommand {
            ui.pendingDelete = ui.selection
        }
        .confirmationDialog(pendingDeleteIsChunk ? "Delete this chunk?" : "Delete this entry?",
                            isPresented: Binding(
            get: { ui.pendingDelete != nil },
            set: { if !$0 { ui.pendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = ui.pendingDelete {
                    delete(id)
                    if ui.selection == id { ui.selection = nil }
                }
            }
        } message: {
            Text("This can't be undone.")
        }
        .overlay {
            if store.entries.isEmpty {
                Text("No entries yet").foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(Store.fileURL.path(percentEncoded: false))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button("Add Entry…") { ui.entryDraft = EntryDraft() }
                .controlSize(.small)
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([Store.fileURL])
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: helpers

    private func entryRow(_ entry: Entry, now: Date) -> some View {
        let paused = entry.id == store.pausedEntry?.id
        return row(start: entry.start, end: paused ? nil : entry.end, endLabel: paused ? "paused" : "now",
                   description: entry.description, duration: entry.duration(now: now),
                   running: entry.isRunning)
    }

    private func row(start: Date, end: Date?, endLabel: String = "now", description: String?,
                     duration: TimeInterval, running: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(start.formatted(date: .omitted, time: .shortened)) – "
                     + (end?.formatted(date: .omitted, time: .shortened) ?? endLabel))
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(format(duration))
                .monospacedDigit()
                .foregroundStyle(running ? .green : .primary)
        }
        .listRowSeparator(.visible)
        .listRowSeparatorTint(Color.primary.opacity(0.25))
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { ui.expanded.contains(id) },
            set: { if $0 { ui.expanded.insert(id) } else { ui.expanded.remove(id) } }
        )
    }

    /// The entry with this id, or the entry and chunk when the id is a chunk's.
    private func lookup(_ id: UUID) -> (entry: Entry, chunk: Chunk?)? {
        for entry in store.entries {
            if entry.id == id { return (entry, nil) }
            if let chunk = entry.chunks.first(where: { $0.id == id }) { return (entry, chunk) }
        }
        return nil
    }

    private var pendingDeleteIsChunk: Bool {
        ui.pendingDelete.flatMap(lookup)?.chunk != nil
    }

    private func edit(_ id: UUID) {
        guard let found = lookup(id) else { return }
        if let chunk = found.chunk {
            ui.entryDraft = EntryDraft(chunk: chunk, of: found.entry)
        } else {
            ui.entryDraft = EntryDraft(entry: found.entry)
        }
    }

    private func delete(_ id: UUID) {
        guard let found = lookup(id) else { return }
        if let chunk = found.chunk {
            store.deleteChunk(entryID: found.entry.id, chunkID: chunk.id)
        } else {
            store.delete(id: id)
        }
    }

    private func groupedByDay() -> [(day: Date, entries: [Entry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: store.entries) { cal.startOfDay(for: $0.start) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    private func format(_ t: TimeInterval, seconds: Bool = true) -> String {
        let s = Int(t)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return seconds
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", h, m)
    }
}
