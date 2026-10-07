import SwiftUI

/// Backing state for the new/edit goal sheet. `goalID == nil` means a new goal.
final class GoalDraft: ObservableObject, Identifiable {
    let id = UUID()
    let goalID: UUID?
    private let existing: Goal?
    @Published var templateID: UUID?
    @Published var name = ""
    @Published var hours: Double = 10
    @Published var start: Date
    @Published var end: Date
    @Published var repeats = false
    @Published var confirmingDelete = false

    init(goal: Goal) {
        goalID = goal.id
        existing = goal
        name = goal.name
        hours = goal.hours
        start = goal.start
        end = goal.end
        repeats = goal.repeats
    }

    init(template: Goal?) {
        goalID = nil
        existing = nil
        let today = Calendar.current.startOfDay(for: Date())
        start = today
        end = Calendar.current.date(byAdding: .day, value: 6, to: today)!
        if let template { apply(template) }
    }

    func apply(_ template: Goal) {
        templateID = template.id
        name = template.name
        hours = template.hours
        repeats = template.repeats
        (start, end) = template.nextPeriod(today: Calendar.current.startOfDay(for: Date()))
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && hours > 0
            && Calendar.current.startOfDay(for: end) >= Calendar.current.startOfDay(for: start)
    }

    func makeGoal(projectID: UUID) -> Goal {
        let cal = Calendar.current
        var goal = existing ?? Goal(projectID: projectID, name: "", hours: 0, start: start, end: end,
                                    repeats: false, previousGoalID: templateID)
        goal.name = name.trimmingCharacters(in: .whitespaces)
        goal.hours = hours
        goal.start = cal.startOfDay(for: start)
        goal.end = cal.startOfDay(for: end)
        goal.repeats = repeats
        return goal
    }
}

struct GoalSheet: View {
    @ObservedObject var draft: GoalDraft
    let templates: [Goal]
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.goalID == nil ? "New Goal" : "Edit Goal").font(.headline)
            Form {
                if draft.goalID == nil && !templates.isEmpty {
                    Picker("Based on", selection: templateBinding) {
                        Text("Nothing").tag(UUID?.none)
                        ForEach(templates) { goal in
                            Text("\(goal.name) · \(goalDateRange(goal.start, goal.end))").tag(Optional(goal.id))
                        }
                    }
                }
                TextField("Name", text: $draft.name)
                TextField("Hours", value: $draft.hours, format: .number)
                DatePicker("Start", selection: $draft.start, displayedComponents: .date)
                DatePicker("End", selection: $draft.end, displayedComponents: .date)
                Toggle("Repeat", isOn: $draft.repeats)
                Text(draft.repeats
                     ? "When it ends, the same goal starts again for the following week."
                     : "When it ends, it's archived.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if draft.goalID != nil {
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
        .frame(width: 360)
        .confirmationDialog("Delete this goal?", isPresented: $draft.confirmingDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("This can't be undone.")
        }
    }

    private var templateBinding: Binding<UUID?> {
        Binding(
            get: { draft.templateID },
            set: { id in
                draft.templateID = id
                if let template = templates.first(where: { $0.id == id }) { draft.apply(template) }
            }
        )
    }
}

struct GoalRow: View {
    let goal: Goal
    let progress: TimeInterval
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(goal.name).font(.subheadline.weight(.medium))
                if goal.repeats {
                    Image(systemName: "repeat").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(hm(progress)) / \(hm(goal.target))")
                    .font(.subheadline.monospacedDigit())
            }
            ProgressView(value: min(progress / goal.target, 1))
                .tint(met ? .green : .accentColor)
            Text(details).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var met: Bool { progress >= goal.target }

    private var details: String {
        var parts = [goalDateRange(goal.start, goal.end)]
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        if today < goal.start {
            parts.append("starts \(goal.start.formatted(.dateTime.weekday(.wide)))")
        } else {
            let days = (cal.dateComponents([.day], from: today, to: goal.end).day ?? 0) + 1
            parts.append(days == 1 ? "last day" : "\(days) days left")
        }
        parts.append(met ? "done!" : "\(hm(goal.target - progress)) to go")
        return parts.joined(separator: " · ")
    }

    private func hm(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
    }
}

func goalDateRange(_ start: Date, _ end: Date) -> String {
    let style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
    return "\(start.formatted(style)) – \(end.formatted(style))"
}
