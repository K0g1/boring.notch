//
//  AppleRemindersProvider.swift
//  boringNotch
//

import Foundation
@preconcurrency import EventKit

enum AppleRemindersError: LocalizedError {
    case accessDenied
    case taskNotFound

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Reminders access is not available."
        case .taskNotFound:
            return "The reminder could not be found."
        }
    }
}

actor AppleRemindersProvider: TaskProvider {
    private let store: EKEventStore
    private var taskCache: [String: TaskItem] = [:]
    private var listCache: [TaskContainer] = []
    private var lastRefresh: Date?
    private let staleAfter: TimeInterval = 60

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    nonisolated func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    func refresh(force: Bool = false) async throws {
        guard hasAccess else {
            taskCache.removeAll()
            listCache.removeAll()
            throw AppleRemindersError.accessDenied
        }
        if !force,
           let lastRefresh,
           Date().timeIntervalSince(lastRefresh) < staleAfter {
            return
        }

        let calendars = store.calendars(for: .reminder)
        let reminders = await fetchReminders(in: calendars)

        listCache = calendars.map {
            TaskContainer(
                id: $0.calendarIdentifier,
                source: .appleReminders,
                name: $0.title,
                color: TaskColor($0.color)
            )
        }
        let containers = Dictionary(uniqueKeysWithValues: listCache.map { ($0.id, $0) })
        taskCache = Dictionary(
            uniqueKeysWithValues: reminders.compactMap { reminder in
                guard let item = Self.taskItem(from: reminder, containers: containers) else {
                    return nil
                }
                return (item.providerID, item)
            }
        )
        lastRefresh = Date()
    }

    func cachedTasks() -> [TaskItem] {
        Array(taskCache.values)
    }

    func containers() -> [TaskContainer] {
        listCache.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func setCompleted(taskID: String, completed: Bool) async throws {
        guard hasAccess else { throw AppleRemindersError.accessDenied }
        guard let reminder = store.calendarItem(withIdentifier: taskID) as? EKReminder else {
            throw AppleRemindersError.taskNotFound
        }

        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
        if var item = taskCache[taskID] {
            item.isCompleted = completed
            item.mutationState = .confirmed
            taskCache[taskID] = item
        }
        lastRefresh = Date()
    }

    private var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    private func fetchReminders(in calendars: [EKCalendar]) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            let predicate = store.predicateForReminders(in: calendars)
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private static func taskItem(
        from reminder: EKReminder,
        containers: [String: TaskContainer]
    ) -> TaskItem? {
        guard let calendar = reminder.calendar else { return nil }
        let container = containers[calendar.calendarIdentifier]
        let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        let isAllDay = reminder.dueDateComponents?.hour == nil
        let encodedID = reminder.calendarItemIdentifier
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        let deepLink = encodedID.flatMap {
            URL(string: "x-apple-reminderkit://remcdreminder/\($0)")
        }

        return TaskItem(
            providerID: reminder.calendarItemIdentifier,
            source: .appleReminders,
            title: reminder.title ?? "",
            notes: reminder.notes,
            due: due,
            isAllDay: isAllDay,
            isCompleted: reminder.isCompleted,
            priority: taskPriority(from: reminder.priority),
            containerID: calendar.calendarIdentifier,
            containerName: calendar.title,
            color: container?.color ?? .reminderBlue,
            deepLink: deepLink,
            isRecurring: reminder.hasRecurrenceRules
        )
    }

    private static func taskPriority(from value: Int) -> TaskPriority? {
        switch value {
        case 1...4: return .high
        case 5: return .normal
        case 6...9: return .low
        default: return nil
        }
    }
}
