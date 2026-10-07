import SwiftUI
import AppKit

@main
struct TimeTrackerApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        Window("Time Tracker", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 380, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
    }
}

final class UIState: ObservableObject {
    @Published var editingName = false
    @Published var nameDraft = ""
    @Published var entryDraft: EntryDraft?
}

/// Backing state for the add/edit entry sheet. `entryID == nil` means a new manual entry.
final class EntryDraft: ObservableObject, Identifiable {
    let id = UUID()
    let entryID: UUID?
    let isRunning: Bool
    @Published var start: Date
    @Published var end: Date

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
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
        }
        .padding(20)
        .frame(width: 340)
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
            }, onCancel: { ui.entryDraft = nil })
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

    private func stat(_ label: String, _ value: TimeInterval) -> some View {
        VStack(spacing: 2) {
            Text(format(value, seconds: false)).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func entryList(now: Date) -> some View {
        List {
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
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { ui.entryDraft = EntryDraft(entry: entry) }
                        .contextMenu {
                            Button("Edit…") { ui.entryDraft = EntryDraft(entry: entry) }
                            Button("Delete", role: .destructive) { store.delete(entry) }
                        }
                    }
                }
            }
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
                .keyboardShortcut("n")
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([Store.fileURL])
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: helpers

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
