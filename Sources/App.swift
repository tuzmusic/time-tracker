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
                    .disabled(store.runningEntry != nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Stop Timer") { store.stop() }
                    .keyboardShortcut("s")
                    .disabled(store.runningEntry == nil)
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
    @Published var goalDraft: GoalDraft?
    @Published var pendingGoalDelete: UUID?
}

/// Backing state for the add/edit entry sheet. `entryID == nil` means a new manual entry.
final class EntryDraft: ObservableObject, Identifiable {
    let id = UUID()
    let entryID: UUID?
    let isRunning: Bool
    @Published var start: Date
    @Published var end: Date
    @Published var confirmingDelete = false

    init(entry: Entry? = nil) {
        entryID = entry?.id
        isRunning = entry != nil && entry?.end == nil
        if let entry {
            start = entry.start
            end = entry.end ?? Date()
        } else {
            let now = Date()
            start = now.addingTimeInterval(-3600)
            end = now
        }
    }

    var isValid: Bool { isRunning ? start <= Date() : end > start }
}

struct EntrySheet: View {
    @ObservedObject var draft: EntryDraft
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.entryID == nil ? "Add Entry" : "Edit Entry").font(.headline)
            Form {
                DatePicker("Start", selection: $draft.start)
                if draft.isRunning {
                    LabeledContent("End", value: "Running")
                } else {
                    DatePicker("End", selection: $draft.end)
                    LabeledContent("Duration", value: durationText)
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
        .confirmationDialog("Delete this entry?", isPresented: $draft.confirmingDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("This can't be undone.")
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
                if let id = draft.entryID {
                    store.updateEntry(id: id, start: draft.start, end: draft.isRunning ? nil : draft.end)
                } else {
                    store.addEntry(start: draft.start, end: draft.end)
                }
                ui.entryDraft = nil
            }, onCancel: { ui.entryDraft = nil }, onDelete: {
                if let id = draft.entryID { store.delete(id: id) }
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

            Text(format(store.runningEntry?.duration(now: now) ?? 0))
                .font(.system(size: 44, weight: .light, design: .monospaced))
                .foregroundStyle(store.runningEntry == nil ? .secondary : .primary)

            Button(action: store.toggle) {
                Text(store.runningEntry == nil ? "Start" : "Stop")
                    .frame(width: 120)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(store.runningEntry == nil ? .green : .red)
            .keyboardShortcut(.space, modifiers: [])

            HStack(spacing: 24) {
                stat("Today", store.total(since: Calendar.current.startOfDay(for: now), now: now))
                stat("This week", store.total(since: startOfWeek(now), now: now))
                stat("All time", store.total(since: .distantPast, now: now))
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
                Section(group.day.formatted(.dateTime.weekday(.wide).month().day())) {
                    ForEach(group.entries) { entry in
                        HStack {
                            Text(timeRange(entry))
                            Spacer()
                            Text(format(entry.duration(now: now)))
                                .monospacedDigit()
                                .foregroundStyle(entry.end == nil ? .green : .primary)
                        }
                        .tag(entry.id)
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
        .confirmationDialog("Delete this entry?", isPresented: Binding(
            get: { ui.pendingDelete != nil },
            set: { if !$0 { ui.pendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = ui.pendingDelete {
                    store.delete(id: id)
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

    private func edit(_ id: UUID) {
        if let entry = store.entries.first(where: { $0.id == id }) {
            ui.entryDraft = EntryDraft(entry: entry)
        }
    }

    private func groupedByDay() -> [(day: Date, entries: [Entry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: store.entries) { cal.startOfDay(for: $0.start) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    private func timeRange(_ e: Entry) -> String {
        let start = e.start.formatted(date: .omitted, time: .shortened)
        let end = e.end?.formatted(date: .omitted, time: .shortened) ?? "now"
        return "\(start) – \(end)"
    }

    private func startOfWeek(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    private func format(_ t: TimeInterval, seconds: Bool = true) -> String {
        let s = Int(t)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return seconds
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", h, m)
    }
}
