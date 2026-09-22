import AppKit
import Combine
import UserNotifications

/// A single local session. Only transitions are persisted; display ticks never write to disk.
@MainActor
final class FocusSessionStore: ObservableObject {
    static let shared = FocusSessionStore()
    enum Mode: String, Codable, CaseIterable {
        case timer = "Timer", stopwatch = "Stopwatch", focus = "Focus"
    }
    struct Association: Codable, Identifiable, Hashable {
        let id: String
        let title: String
    }
    struct Session: Codable {
        var mode: Mode
        var duration: TimeInterval
        var elapsed: TimeInterval = 0
        var startedAt: Date?
        var completed = false
        var isBreak = false
        var association: Association?
    }
    @Published private(set) var session: Session?
    @Published var showingControls = false
    private var deadlineTimer: Timer?
    private var wakeObserver: AnyCancellable?
    private var notificationTask: Task<Void, Never>?
    private let key = "focusSession.v1"
    private let notificationID = "boringNotch.focusSession"

    var running: Bool { session?.startedAt != nil }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let restored = try? JSONDecoder().decode(Session.self, from: data),
           restored.duration.isFinite, restored.duration >= 0,
           restored.elapsed.isFinite, restored.elapsed >= 0 {
            session = restored
        }
        reconcile()
        scheduleDeadline()
        wakeObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reconcile()
                    self?.scheduleDeadline()
                }
            }
    }

    deinit {
        deadlineTimer?.invalidate()
        notificationTask?.cancel()
    }

    func elapsed(at date: Date) -> TimeInterval {
        guard let session else { return 0 }
        return max(0, session.elapsed + (session.startedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0))
    }

    func displaySeconds(at date: Date) -> TimeInterval {
        guard let session else { return 0 }
        return session.mode == .stopwatch ? elapsed(at: date) : max(0, session.duration - elapsed(at: date))
    }

    func progress(at date: Date) -> Double {
        guard let session, session.duration > 0 else { return 0 }
        return min(1, elapsed(at: date) / session.duration)
    }

    func start(mode: Mode, minutes: Double, association: Association?) {
        guard session == nil, minutes.isFinite else { return }
        session = Session(mode: mode, duration: min(1440, max(1, minutes)) * 60,
                          startedAt: Date(), association: association)
        changed()
    }

    func togglePause() {
        reconcile()
        guard var value = session, !value.completed else { return }
        if value.startedAt != nil {
            value.elapsed = elapsed(at: Date())
            value.startedAt = nil
        } else {
            value.startedAt = Date()
        }
        session = value
        changed()
    }

    func cancel() {
        session = nil
        changed()
    }

    /// Pomodoro phases wait for explicit confirmation, so sleep cannot skip entire cycles.
    func nextPhase() {
        guard let value = session, value.mode == .focus, value.completed else { return }
        session = Session(mode: .focus, duration: value.isBreak ? 25 * 60 : 5 * 60,
                          startedAt: Date(), isBreak: !value.isBreak, association: value.association)
        changed()
    }

    private func reconcile() {
        guard var value = session, value.startedAt != nil, value.mode != .stopwatch,
              elapsed(at: Date()) >= value.duration else { return }
        value.elapsed = value.duration
        value.startedAt = nil
        value.completed = true
        session = value
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        persist()
    }

    private func changed() {
        persist()
        scheduleDeadline()
        scheduleNotification()
    }

    private func persist() {
        if let session, let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func scheduleDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard running, let session, session.mode != .stopwatch else { return }
        let timer = Timer(timeInterval: max(0.1, displaySeconds(at: Date())), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile(); self?.scheduleDeadline() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    private func scheduleNotification() {
        notificationTask?.cancel()
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        guard running, let session, session.mode != .stopwatch else { return }
        let deadline = Date().addingTimeInterval(displaySeconds(at: Date()))
        let identifier = notificationID
        notificationTask = Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted, !Task.isCancelled, deadline > Date() else { return }
            let content = UNMutableNotificationContent()
            content.title = session.mode == .focus ? (session.isBreak ? "Break complete" : "Focus complete") : "Timer complete"
            content.body = session.association?.title ?? "Your session has finished."
            content.sound = .default
            let request = UNNotificationRequest(identifier: identifier, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, deadline.timeIntervalSinceNow), repeats: false))
            // Enqueue synchronously after the cancellation check. A later pause/cancel
            // can then reliably remove this request without racing an async add.
            center.add(request, withCompletionHandler: nil)
        }
    }
}
