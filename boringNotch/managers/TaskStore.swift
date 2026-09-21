//
//  TaskStore.swift
//  boringNotch
//

import AppKit
import Defaults
import EventKit
import Foundation

@MainActor
final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var reminderLists: [TaskContainer] = []
    @Published private(set) var todoistProjects: [TaskContainer] = []
    @Published private(set) var reminderAuthorizationStatus: EKAuthorizationStatus =
        EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var isTodoistConnected = false
    @Published private(set) var lastTodoistSync: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    private let appleProvider: AppleRemindersProvider
    private let todoistProvider: TodoistProvider
    private var refreshTask: Task<Void, Never>?
    private var appActivityTask: Task<Void, Never>?
    private var visibleRefreshTask: Task<Void, Never>?
    private var eventStoreObserver: NSObjectProtocol?
    private var visibleConsumerCount = 0
    private var hasStarted = false

    init(
        appleProvider: AppleRemindersProvider = AppleRemindersProvider(),
        todoistProvider: TodoistProvider = TodoistProvider()
    ) {
        self.appleProvider = appleProvider
        self.todoistProvider = todoistProvider
    }

    deinit {
        refreshTask?.cancel()
        appActivityTask?.cancel()
        visibleRefreshTask?.cancel()
        if let eventStoreObserver {
            NotificationCenter.default.removeObserver(eventStoreObserver)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        reminderAuthorizationStatus = appleProvider.authorizationStatus()

        eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh(force: true)
            }
        }

        appActivityTask = Task { @MainActor [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification
            )
            for await _ in notifications {
                guard !Task.isCancelled else { break }
                await self?.refresh(force: false)
            }
        }

        Task { @MainActor [weak self] in
            await self?.reloadConnectionState()
            await self?.refresh(force: false)
        }
    }

    func beginVisibleRefresh() {
        start()
        visibleConsumerCount += 1
        guard visibleRefreshTask == nil else { return }

        visibleRefreshTask = Task { @MainActor [weak self] in
            await self?.refresh(force: false)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    break
                }
                await self?.refresh(force: false)
            }
        }
    }

    func endVisibleRefresh() {
        visibleConsumerCount = max(0, visibleConsumerCount - 1)
        guard visibleConsumerCount == 0 else { return }
        visibleRefreshTask?.cancel()
        visibleRefreshTask = nil
    }

    func refresh(force: Bool) async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh(force: force)
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    func requestReminderAccess() async {
        do {
            _ = try await appleProvider.requestAccess()
            reminderAuthorizationStatus = appleProvider.authorizationStatus()
            await refresh(force: true)
        } catch {
            reminderAuthorizationStatus = appleProvider.authorizationStatus()
            lastError = error.localizedDescription
        }
    }

    func connectTodoist(token: String) async {
        isRefreshing = true
        lastError = nil
        do {
            try await todoistProvider.connect(token: token)
            isTodoistConnected = true
            await reloadSnapshots()
        } catch {
            lastError = error.localizedDescription
            await reloadConnectionState()
        }
        isRefreshing = false
    }

    func disconnectTodoist() async {
        do {
            try await todoistProvider.disconnect()
            isTodoistConnected = false
            lastTodoistSync = nil
            Defaults[.selectedTodoistProjectIDs] = nil
            await reloadSnapshots()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setCompleted(taskID: String, completed: Bool) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let original = tasks[index]
        tasks[index].isCompleted = completed
        tasks[index].mutationState = .pending
        lastError = nil

        do {
            switch original.source {
            case .appleReminders:
                try await appleProvider.setCompleted(
                    taskID: original.providerID,
                    completed: completed
                )
            case .todoist:
                try await todoistProvider.setCompleted(
                    taskID: original.providerID,
                    completed: completed
                )
            }
            await reloadSnapshots()
        } catch {
            guard let rollbackIndex = tasks.firstIndex(where: { $0.id == taskID }) else {
                return
            }
            tasks[rollbackIndex] = original
            tasks[rollbackIndex].mutationState = .failed
            lastError = error.localizedDescription
        }
    }

    func tasks(on date: Date) -> [TaskItem] {
        guard let interval = Calendar.current.dateInterval(of: .day, for: date) else {
            return []
        }
        return tasks
            .filter { task in
                guard let due = task.due else { return false }
                return interval.contains(due)
            }
            .sorted(by: Self.taskSort)
    }

    var undatedTodoistTasks: [TaskItem] {
        tasks
            .filter { $0.source == .todoist && $0.due == nil }
            .sorted(by: Self.taskSort)
    }

    func isReminderListSelected(_ container: TaskContainer) -> Bool {
        switch Defaults[.reminderSelectionState] {
        case .all:
            return true
        case .selected(let identifiers):
            return identifiers.contains(container.id)
        }
    }

    func setReminderListSelected(_ container: TaskContainer, selected: Bool) {
        var selectedIDs: Set<String>
        switch Defaults[.reminderSelectionState] {
        case .all:
            selectedIDs = Set(reminderLists.map(\.id))
        case .selected(let identifiers):
            selectedIDs = identifiers
        }
        if selected {
            selectedIDs.insert(container.id)
        } else {
            selectedIDs.remove(container.id)
        }
        Defaults[.reminderSelectionState] =
            selectedIDs.count == reminderLists.count ? .all : .selected(selectedIDs)
        rebuildVisibleTasks()
    }

    func isTodoistProjectSelected(_ container: TaskContainer) -> Bool {
        guard let selected = Defaults[.selectedTodoistProjectIDs] else { return true }
        return selected.contains(container.id)
    }

    func setTodoistProjectSelected(_ container: TaskContainer, selected: Bool) {
        var selectedIDs = Defaults[.selectedTodoistProjectIDs]
            ?? todoistProjects.map(\.id)
        if selected {
            if !selectedIDs.contains(container.id) {
                selectedIDs.append(container.id)
            }
        } else {
            selectedIDs.removeAll { $0 == container.id }
        }
        Defaults[.selectedTodoistProjectIDs] = selectedIDs
        rebuildVisibleTasks()
    }

    private func performRefresh(force: Bool) async {
        isRefreshing = true
        lastError = nil
        reminderAuthorizationStatus = appleProvider.authorizationStatus()
        isTodoistConnected = await todoistProvider.isConnected()

        if reminderAuthorizationStatus == .fullAccess {
            do {
                try await appleProvider.refresh(force: force)
            } catch {
                lastError = error.localizedDescription
            }
        }

        if isTodoistConnected {
            do {
                try await todoistProvider.refresh(force: force)
            } catch {
                // Cached tasks remain published while the service is offline.
                lastError = error.localizedDescription
            }
        }
        await reloadSnapshots()
        isRefreshing = false
    }

    private func reloadConnectionState() async {
        isTodoistConnected = await todoistProvider.isConnected()
        lastTodoistSync = await todoistProvider.lastSuccessfulSync()
    }

    private func reloadSnapshots() async {
        async let appleTasks = appleProvider.cachedTasks()
        async let todoistTasks = todoistProvider.cachedTasks()
        async let appleContainers = appleProvider.containers()
        async let todoistContainers = todoistProvider.containers()
        let snapshots = await (
            appleTasks,
            todoistTasks,
            appleContainers,
            todoistContainers
        )

        reminderLists = snapshots.2
        todoistProjects = snapshots.3
        if let selectedProjectIDs = Defaults[.selectedTodoistProjectIDs] {
            let availableIDs = Set(todoistProjects.map(\.id))
            let validSelection = selectedProjectIDs.filter(availableIDs.contains)
            if validSelection != selectedProjectIDs {
                Defaults[.selectedTodoistProjectIDs] = validSelection
            }
        }
        lastTodoistSync = await todoistProvider.lastSuccessfulSync()
        sourceTasks = snapshots.0 + snapshots.1
        rebuildVisibleTasks()
    }

    private var sourceTasks: [TaskItem] = []

    private func rebuildVisibleTasks() {
        tasks = sourceTasks.filter { task in
            guard let containerID = task.containerID else { return true }
            switch task.source {
            case .appleReminders:
                switch Defaults[.reminderSelectionState] {
                case .all:
                    return true
                case .selected(let identifiers):
                    return identifiers.contains(containerID)
                }
            case .todoist:
                guard let selected = Defaults[.selectedTodoistProjectIDs] else {
                    return true
                }
                return selected.contains(containerID)
            }
        }
    }

    private static func taskSort(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        switch (lhs.due, rhs.due) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs < rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.priority != rhs.priority {
                return (lhs.priority ?? .normal) > (rhs.priority ?? .normal)
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}
