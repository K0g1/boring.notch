//
//  TaskItem.swift
//  boringNotch
//

import AppKit
import Foundation

enum TaskSource: String, Codable, Sendable {
    case appleReminders
    case todoist
}

enum TaskPriority: Int, Codable, Comparable, Sendable {
    case low = 1
    case normal = 2
    case high = 3
    case urgent = 4

    static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum TaskMutationState: String, Codable, Sendable {
    case confirmed
    case pending
    case failed
}

struct TaskColor: Codable, Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        let color = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(
            red: Double(red),
            green: Double(green),
            blue: Double(blue),
            alpha: Double(alpha)
        )
    }

    static let reminderBlue = TaskColor(red: 0.18, green: 0.52, blue: 0.95)
    static let todoistRed = TaskColor(red: 0.86, green: 0.18, blue: 0.18)
}

struct TaskContainer: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let source: TaskSource
    var name: String
    var color: TaskColor
}

struct TaskItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let providerID: String
    let source: TaskSource
    var title: String
    var notes: String?
    var due: Date?
    var isAllDay: Bool
    var isCompleted: Bool
    var priority: TaskPriority?
    var containerID: String?
    var containerName: String?
    var color: TaskColor
    var deepLink: URL?
    var isRecurring: Bool
    var mutationState: TaskMutationState

    init(
        providerID: String,
        source: TaskSource,
        title: String,
        notes: String? = nil,
        due: Date? = nil,
        isAllDay: Bool = false,
        isCompleted: Bool = false,
        priority: TaskPriority? = nil,
        containerID: String? = nil,
        containerName: String? = nil,
        color: TaskColor,
        deepLink: URL? = nil,
        isRecurring: Bool = false,
        mutationState: TaskMutationState = .confirmed
    ) {
        self.id = "\(source.rawValue):\(providerID)"
        self.providerID = providerID
        self.source = source
        self.title = title
        self.notes = notes
        self.due = due
        self.isAllDay = isAllDay
        self.isCompleted = isCompleted
        self.priority = priority
        self.containerID = containerID
        self.containerName = containerName
        self.color = color
        self.deepLink = deepLink
        self.isRecurring = isRecurring
        self.mutationState = mutationState
    }
}

protocol TaskProvider: Sendable {
    func refresh(force: Bool) async throws
    func cachedTasks() async -> [TaskItem]
    func containers() async -> [TaskContainer]
    func setCompleted(taskID: String, completed: Bool) async throws
}

extension TaskProvider {
    func tasks(in interval: DateInterval) async -> [TaskItem] {
        await cachedTasks().filter { task in
            guard let due = task.due else { return false }
            return interval.contains(due)
        }
    }
}
