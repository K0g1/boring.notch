import SwiftUI

struct TaskRowActions: View {
    let task: TaskItem
    @ObservedObject private var store = TaskStore.shared
    @State private var editing = false
    @State private var title = ""
    @State private var due = Date()
    @State private var hasDue = false
    @State private var allDay = true
    @State private var error: String?
    @State private var deleting = false

    var body: some View {
        Menu {
            Button("Rename or Reschedule…") {
                title = task.title
                due = task.due ?? Date()
                hasDue = task.due != nil
                allDay = task.isAllDay
                editing = true
            }
            Button("Postpone One Day") {
                let next = Calendar.current.date(byAdding: .day, value: 1, to: task.due ?? Date()) ?? Date()
                perform { try await store.edit(task, change: .due(next, isAllDay: task.due == nil || task.isAllDay)) }
            }
            Menu("Priority") {
                Button("None") { setPriority(nil) }
                Button("Low") { setPriority(.low) }
                Button("Normal") { setPriority(.normal) }
                Button("High") { setPriority(.high) }
                Button("Urgent") { setPriority(.urgent) }
            }
            Divider()
            Button("Delete…", role: .destructive) { deleting = true }
        } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Task actions").accessibilityLabel("Actions for \(task.title)")
        .disabled(!store.canEdit(task) || store.isMutating)
        .popover(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Task title", text: $title).textFieldStyle(.roundedBorder)
                Toggle("Due date", isOn: $hasDue)
                if hasDue {
                    Toggle("All day", isOn: $allDay)
                    DatePicker("Due", selection: $due, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                }
                if task.isRecurring { Text("Changing the date may change the recurring schedule.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") { saveEdits() }.keyboardShortcut(.defaultAction)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isMutating)
                }
            }.padding().frame(width: 300)
        }
        .confirmationDialog("Delete “\(task.title)” permanently?", isPresented: $deleting) {
            Button("Delete Task", role: .destructive) { perform { try await store.delete(task) } }
        }
        .alert("Couldn’t Change Task", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func setPriority(_ priority: TaskPriority?) {
        perform { try await store.edit(task, change: .priority(priority)) }
    }

    private func saveEdits() {
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        perform {
            if newTitle != task.title { try await store.edit(task, change: .title(newTitle)) }
            if (hasDue ? due : nil) != task.due || (hasDue && allDay != task.isAllDay) {
                try await store.edit(task, change: .due(hasDue ? due : nil, isAllDay: allDay))
            }
            editing = false
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await operation() }
            catch { self.error = error.localizedDescription }
        }
    }
}
