import AppKit
import SwiftUI

/// One reusable utility panel; no polling or network work while it is hidden.
@MainActor
final class TaskCaptureController {
    static let shared = TaskCaptureController()
    private var panel: NSPanel?

    func show() {
        if let panel, panel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "New Task"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: QuickTaskCapture { [weak panel] in panel?.close() })
        self.panel = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

struct QuickTaskCapture: View {
    @ObservedObject private var store = TaskStore.shared
    @State private var title = ""
    @State private var source = TaskSource.appleReminders
    @State private var containerID = ""
    @State private var hasDue = false
    @State private var due = Date()
    @State private var saving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("What needs doing?", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onSubmit { save() }
            if store.captureSources.isEmpty {
                Text("Enable Reminders or connect Todoist in Settings → Calendar to capture tasks.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Settings") { SettingsWindowController.shared.showWindow() }
            } else {
                HStack {
                    Picker("Service", selection: $source) {
                        ForEach(store.captureSources, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("Destination", selection: $containerID) {
                        ForEach(store.captureContainers(for: source)) { Text($0.name).tag($0.id) }
                    }
                }
                .labelsHidden()
                Toggle("Due date", isOn: $hasDue)
                if hasDue {
                    DatePicker("Due", selection: $due, displayedComponents: .date)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction).disabled(saving)
                Button("Add Task", action: save).keyboardShortcut(.defaultAction)
                    .disabled(saving || store.isMutating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || containerID.isEmpty)
            }
        }
        .padding(20).frame(width: 400)
        .disabled(saving)
        .task {
            titleFocused = true
            store.start()
            await store.refresh(force: false)
            selectDestination()
        }
        .onChange(of: source) { _, _ in selectDestination() }
        .onChange(of: store.captureSources) { _, _ in selectDestination() }
        .onChange(of: store.captureContainers(for: source)) { _, _ in selectDestination() }
    }

    private func selectDestination() {
        if !store.captureSources.contains(source), let first = store.captureSources.first { source = first }
        let containers = store.captureContainers(for: source)
        if !containers.contains(where: { $0.id == containerID }) { containerID = containers.first?.id ?? "" }
    }

    private func save() {
        guard !saving, !store.isMutating, !containerID.isEmpty,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saving = true
        error = nil
        Task { @MainActor in
            do {
                try await store.create(TaskDraft(title: title, containerID: containerID, due: hasDue ? due : nil), source: source)
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
