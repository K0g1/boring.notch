import SwiftUI

struct FocusSessionView: View {
    @ObservedObject private var store = FocusSessionStore.shared
    @ObservedObject private var tasks = TaskStore.shared
    @ObservedObject private var calendar = CalendarManager.shared
    @StateObject private var agenda = CalendarAgendaModel()
    @State private var mode: FocusSessionStore.Mode = .focus
    @State private var minutes = 25.0
    @State private var association: FocusSessionStore.Association?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Timer & Focus", systemImage: "timer").font(.headline)
                Spacer()
                Button("Done") { store.showingControls = false }
            }
            if let session = store.session {
                HStack(spacing: 16) {
                    FocusSessionReadout(compact: false)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.mode == .focus ? (session.isBreak ? "Short break" : "Focus session") : session.mode.rawValue)
                        if let association = session.association {
                            Text(association.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        HStack {
                            if session.completed {
                                Text("Complete").foregroundStyle(.green)
                                if session.mode == .focus {
                                    Button(session.isBreak ? "Focus 25 min" : "Break 5 min") { store.nextPhase() }
                                }
                            } else {
                                Button(store.running ? "Pause" : "Resume") { store.togglePause() }
                            }
                            Button(session.completed ? "Dismiss" : "Cancel") { store.cancel() }
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack {
                    Picker("Mode", selection: $mode) {
                        ForEach(FocusSessionStore.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented)
                    if mode == .timer {
                        TextField("Minutes", value: $minutes, format: .number)
                            .frame(width: 55).textFieldStyle(.roundedBorder)
                        Text("min").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Menu {
                        Button("No task or event") { association = nil }
                        Section("Tasks") {
                            ForEach(tasks.tasks.filter { !$0.isCompleted }) { task in
                                Button(task.title) { association = .init(id: task.id, title: task.title) }
                            }
                        }
                        Section("Calendar events") {
                            ForEach(agenda.events.filter { $0.type.isEvent }, id: \.occurrenceID) { event in
                                Button(event.title) { association = .init(id: "event:" + event.id, title: event.title) }
                            }
                        }
                    } label: {
                        Label(association?.title ?? "Link task or event", systemImage: "link").lineLimit(1)
                    }
                    Spacer()
                    Button(mode == .focus ? "Focus 25 min" : "Start") {
                        store.start(mode: mode, minutes: mode == .focus ? 25 : minutes, association: association)
                    }.disabled(!minutes.isFinite || minutes < 1 || minutes > 1440)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: calendar.revision) {
            await agenda.load(day: Date(), calendarIDs: calendar.selectedCalendarIDs)
        }
    }
}

/// One-second UI updates exist only while a running session is actually visible.
struct FocusSessionReadout: View {
    @ObservedObject private var store = FocusSessionStore.shared
    var compact: Bool

    var body: some View {
        if store.running {
            TimelineView(.periodic(from: .now, by: 1)) { context in readout(at: context.date) }
        } else {
            readout(at: Date())
        }
    }

    private func readout(at date: Date) -> some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.3), lineWidth: 2)
                Circle().trim(from: 0, to: store.progress(at: date))
                    .stroke(.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: store.session?.completed == true ? "checkmark" : (store.running ? "timer" : "pause.fill"))
                    .font(.system(size: compact ? 8 : 14))
            }.frame(width: compact ? 19 : 34, height: compact ? 19 : 34)
            Text(formatted(store.displaySeconds(at: date)))
                .font(.system(size: compact ? 10 : 28, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.orange)
        .accessibilityLabel("\(store.session?.mode.rawValue ?? "Timer"), \(formatted(store.displaySeconds(at: date)))")
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        let rounded = seconds.rounded(store.session?.mode == .stopwatch ? .down : .up)
        let value = Int(min(rounded, Double(Int.max / 2)))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}
