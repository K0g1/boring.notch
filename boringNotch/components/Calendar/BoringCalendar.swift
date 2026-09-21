//
//  BoringCalendar.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import SwiftUI

struct Config: Equatable {
    //    var count: Int = 10  // 3 days past + today + 7 days future
    var past: Int = 7
    var future: Int = 14
    var steps: Int = 1  // Each step is one day
    var spacing: CGFloat = 0
    var showsText: Bool = true
    var offset: Int = 2  // Number of dates to the left of the selected date
}

struct WheelPicker: View {
    @EnvironmentObject var vm: BoringViewModel
    @Binding var selectedDate: Date
    @State private var scrollPosition: Int?
    @State private var haptics: Bool = false
    @State private var byClick: Bool = false
    let config: Config

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: config.spacing) {
                let spacerNum = config.offset
                let dateCount = totalDateItems()
                let totalItems = dateCount + 2 * spacerNum
                ForEach(0..<totalItems, id: \.self) { index in
                    if index < spacerNum || index >= spacerNum + dateCount {
                        // Leading/trailing spacers sized to match a date cell
                        Spacer()
                            .frame(width: 24, height: 24)
                            .id(index)
                    } else {
                        let date = dateForItemIndex(index: index, spacerNum: spacerNum)
                        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                        dateButton(date: date, isSelected: isSelected, id: index) {
                            selectedDate = date
                            byClick = true
                            withAnimation {
                                scrollPosition = index
                            }
                            if Defaults[.enableHaptics] {
                                haptics.toggle()
                            }
                        }
                    }
                }
            }
            .frame(height: 50)
            .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .scrollPosition(id: $scrollPosition, anchor: .center)
        .scrollTargetBehavior(.viewAligned)  // Ensures scroll view snaps the centered view
        .safeAreaPadding(.horizontal)
        .sensoryFeedback(.alignment, trigger: haptics)
        .onChange(of: scrollPosition) { oldValue, newValue in
            if !byClick {
                handleScrollChange(newValue: newValue, config: config)
            } else {
                byClick = false
            }
        }
        .onAppear {
            scrollToToday(config: config)
        }
        // When parent updates the bound selectedDate (e.g., view reopen), center the wheel on it
        .onChange(of: selectedDate) { _, newValue in
            let targetIndex = indexForDate(newValue)
            if scrollPosition != targetIndex {
                byClick = true
                withAnimation {
                    scrollPosition = targetIndex
                }
            }
        }
    }

    private func dateButton(
        date: Date, isSelected: Bool, id: Int, onClick: @escaping () -> Void
    ) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        return Button(action: onClick) {
            VStack(spacing: 8) {
                dayText(date: dateToString(for: date), isToday: isToday, isSelected: isSelected)
                dateCircle(date: date, isToday: isToday, isSelected: isSelected)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(isSelected ? Color.effectiveAccentBackground : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
        .id(id)
    }

    private func dayText(date: String, isToday: Bool, isSelected: Bool) -> some View {
        Text(date)
            .font(.caption)
            .foregroundColor(isSelected ? .white : Color(white: 0.65))
    }

    private func dateCircle(date: Date, isToday: Bool, isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isToday ? Color.effectiveAccent : .clear)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 0)
                )
            Text("\(date.date)")
                .font(.body)
                .fontWeight(.medium)
                .foregroundColor(isSelected ? .white : Color(white: isToday ? 0.9 : 0.65))
        }
    }

    func handleScrollChange(newValue: Int?, config: Config) {
        guard let newIndex = newValue else { return }
        let spacerNum = config.offset
        let dateCount = totalDateItems()
        guard (spacerNum..<(spacerNum + dateCount)).contains(newIndex) else { return }
        let date = dateForItemIndex(index: newIndex, spacerNum: spacerNum)
        if !Calendar.current.isDate(date, inSameDayAs: selectedDate) {
            selectedDate = date
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }

    private func scrollToToday(config: Config) {
        let today = Date()
        byClick = true
        scrollPosition = indexForDate(today)
        selectedDate = today
    }

    // MARK: - Index/Date mapping with steps and spacers
    private func indexForDate(_ date: Date) -> Int {
        let spacerNum = config.offset
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.startOfDay(for: cal.date(byAdding: .day, value: -config.past, to: today) ?? today)
        let target = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: startDate, to: target).day ?? 0
        let stepIndex = max(0, min(days / max(config.steps, 1), totalDateItems() - 1))
        return spacerNum + stepIndex
    }

    private func dateForItemIndex(index: Int, spacerNum: Int) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.date(byAdding: .day, value: -config.past, to: today) ?? today
        let stepIndex = index - spacerNum
        return cal.date(byAdding: .day, value: stepIndex * max(config.steps, 1), to: startDate) ?? today
    }

    private func totalDateItems() -> Int {
        let range = config.past + config.future
        let step = max(config.steps, 1)
        return Int(ceil(Double(range) / Double(step))) + 1
    }

    private func dateToString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }
}

struct CalendarView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var taskStore = TaskStore.shared
    @State private var selectedDate = Date()
    @State private var taskRefreshActive = false
    @State private var showsUndatedTodoistTasks = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading) {
                    Text(
                        showsUndatedTodoistTasks
                            ? "Tasks"
                            : selectedDate.formatted(.dateTime.month(.abbreviated))
                    )
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    Text(
                        showsUndatedTodoistTasks
                            ? "Undated"
                            : selectedDate.formatted(.dateTime.year())
                    )
                        .font(.title3)
                        .fontWeight(.light)
                        .foregroundColor(Color(white: 0.65))
                }

                ZStack(alignment: .top) {
                    if showsUndatedTodoistTasks {
                        HStack {
                            Text("Todoist tasks without a due date")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(height: 50)
                    } else {
                        WheelPicker(selectedDate: $selectedDate, config: Config())
                        HStack(alignment: .top) {
                            LinearGradient(
                                colors: [Color.black, .clear], startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: 20)
                            Spacer()
                            LinearGradient(
                                colors: [.clear, Color.black], startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: 20)
                        }
                    }
                }

                if !taskStore.undatedTodoistTasks.isEmpty {
                    Button {
                        showsUndatedTodoistTasks.toggle()
                    } label: {
                        Image(
                            systemName: showsUndatedTodoistTasks
                                ? "calendar"
                                : "checklist"
                        )
                    }
                    .buttonStyle(.plain)
                    .help(showsUndatedTodoistTasks ? "Show calendar" : "Show undated Todoist tasks")
                }
            }

            let dayTasks = showsUndatedTodoistTasks
                ? taskStore.undatedTodoistTasks
                : taskStore.tasks(on: selectedDate)
            if EventListView.filteredEvents(events: calendarManager.events).isEmpty
                && EventListView.filteredTasks(tasks: dayTasks).isEmpty {
                if showsUndatedTodoistTasks {
                    Text("No undated Todoist tasks")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    EmptyEventsView(selectedDate: selectedDate)
                }
                Spacer(minLength: 0)
            } else {
                EventListView(
                    events: showsUndatedTodoistTasks ? [] : calendarManager.events,
                    tasks: dayTasks
                )
            }
        }
        .listRowBackground(Color.clear)
        .frame(height: 120)
        .onChange(of: selectedDate) {
            Task {
                await calendarManager.updateCurrentDate(selectedDate)
            }
        }
        .onChange(of: vm.notchState) { _, newState in
            updateTaskRefresh(for: newState)
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
        }
        .onAppear {
            updateTaskRefresh(for: vm.notchState)
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
        }
        .onDisappear {
            if taskRefreshActive {
                taskStore.endVisibleRefresh()
                taskRefreshActive = false
            }
        }
        .overlay(alignment: .topTrailing) {
            if taskStore.lastError != nil {
                Image(systemName: "exclamationmark.icloud")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Tasks may be out of date. Cached tasks are still available.")
            }
        }
    }

    private func updateTaskRefresh(for state: NotchState) {
        if state == .open, !taskRefreshActive {
            taskStore.beginVisibleRefresh()
            taskRefreshActive = true
        } else if state == .closed, taskRefreshActive {
            taskStore.endVisibleRefresh()
            taskRefreshActive = false
        }
    }
}

struct EmptyEventsView: View {
    let selectedDate: Date
    
    var body: some View {
        VStack {
            Image(systemName: "calendar.badge.checkmark")
                .font(.title)
                .foregroundColor(Color(white: 0.65))
            Text(Calendar.current.isDateInToday(selectedDate) ? "No events today" : "No events")
                .font(.subheadline)
                .foregroundColor(.white)
            Text("Enjoy your free time!")
                .font(.caption)
                .foregroundColor(Color(white: 0.65))
        }
    }
}

private enum AgendaItem: Identifiable, Equatable {
    case event(EventModel)
    case task(TaskItem)

    var id: String {
        switch self {
        case .event(let event): return "event:\(event.id)"
        case .task(let task): return task.id
        }
    }

    var start: Date {
        switch self {
        case .event(let event): return event.start
        case .task(let task): return task.due ?? .distantFuture
        }
    }

    var isAllDay: Bool {
        switch self {
        case .event(let event): return event.isAllDay
        case .task(let task): return task.isAllDay
        }
    }
}

struct EventListView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var taskStore = TaskStore.shared
    let events: [EventModel]
    let tasks: [TaskItem]
    @Default(.autoScrollToNextEvent) private var autoScrollToNextEvent
    @Default(.showFullEventTitles) private var showFullEventTitles

    static func filteredEvents(events: [EventModel]) -> [EventModel] {
        events.filter { !($0.isAllDay && Defaults[.hideAllDayEvents]) }
    }

    static func filteredTasks(tasks: [TaskItem]) -> [TaskItem] {
        tasks.filter { task in
            (!task.isCompleted || !Defaults[.hideCompletedReminders])
                && !(task.isAllDay && Defaults[.hideAllDayEvents])
        }
    }

    private var filteredAgenda: [AgendaItem] {
        let items = Self.filteredEvents(events: events).map(AgendaItem.event)
            + Self.filteredTasks(tasks: tasks).map(AgendaItem.task)
        return items.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            return lhs.id < rhs.id
        }
    }

    private func scrollToRelevantEvent(proxy: ScrollViewProxy) {
        guard autoScrollToNextEvent else { return }
        let now = Date()
        let timedUpcoming = filteredAgenda.first { !$0.isAllDay && $0.start >= now }
        let firstAllDay = filteredAgenda.first(where: \.isAllDay)
        guard let target = timedUpcoming ?? firstAllDay ?? filteredAgenda.last else { return }

        Task { @MainActor in
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(target.id, anchor: .top)
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(filteredAgenda) { item in
                    agendaRow(item)
                        .id(item.id)
                        .padding(.leading, -5)
                        .contentShape(Rectangle())
                        .onTapGesture { open(item) }
                        .listRowSeparator(.automatic)
                        .listRowSeparatorTint(.gray.opacity(0.2))
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.never)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .onAppear { scrollToRelevantEvent(proxy: proxy) }
            .onChange(of: filteredAgenda) { _, _ in
                scrollToRelevantEvent(proxy: proxy)
            }
        }
        Spacer(minLength: 0)
    }

    @ViewBuilder
    private func agendaRow(_ item: AgendaItem) -> some View {
        switch item {
        case .event(let event):
            eventRow(event)
        case .task(let task):
            taskRow(task)
        }
    }

    private func eventRow(_ event: EventModel) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Rectangle()
                .fill(Color(event.calendar.color))
                .frame(width: 3)
                .cornerRadius(1.5)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .lineLimit(showFullEventTitles ? nil : 2)
                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.caption)
                        .foregroundColor(Color(white: 0.65))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if event.isAllDay {
                    Text("All-day").fontWeight(.medium)
                } else {
                    Text(event.start, style: .time).foregroundColor(.white)
                    Text(event.end, style: .time).foregroundColor(Color(white: 0.65))
                }
            }
            .font(.caption)
            .frame(minWidth: 44, alignment: .trailing)
        }
        .opacity(
            event.eventStatus == .ended && Calendar.current.isDateInToday(event.start)
                ? 0.6 : 1
        )
    }

    private func taskRow(_ task: TaskItem) -> some View {
        let color = Color(
            red: task.color.red,
            green: task.color.green,
            blue: task.color.blue,
            opacity: task.color.alpha
        )
        return HStack(spacing: 8) {
            ReminderToggle(
                isOn: Binding(
                    get: { task.isCompleted },
                    set: { completed in
                        Task { await taskStore.setCompleted(taskID: task.id, completed: completed) }
                    }
                ),
                color: color
            )
            HStack(spacing: 4) {
                if task.source == .todoist {
                    Image(systemName: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Todoist")
                }
                Text(task.title)
                    .font(.callout)
                    .foregroundColor(.white)
                    .lineLimit(showFullEventTitles ? nil : 1)
                Spacer(minLength: 0)
                if task.mutationState == .pending {
                    ProgressView().controlSize(.mini)
                } else if task.mutationState == .failed {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                if task.due == nil {
                    Text("No date")
                        .foregroundStyle(.secondary)
                } else if task.isAllDay {
                    Text("All-day")
                        .fontWeight(.medium)
                } else if let due = task.due {
                    Text(due, style: .time)
                }
            }
            .font(.caption)
            .opacity(task.isCompleted ? 0.4 : 1)
        }
        .padding(.vertical, 4)
    }

    private func open(_ item: AgendaItem) {
        let url: URL?
        switch item {
        case .event(let event): url = event.calendarAppURL()
        case .task(let task): url = task.deepLink
        }
        if let url { openURL(url) }
    }
}

struct ReminderToggle: View {
    @Binding var isOn: Bool
    var color: Color

    var body: some View {
        Button(action: {
            isOn.toggle()
        }) {
            ZStack {
                // Outer ring
                Circle()
                    .strokeBorder(color, lineWidth: 2)
                    .frame(width: 14, height: 14)
                // Inner fill
                if isOn {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                Circle()
                    .fill(Color.black.opacity(0.001))
                    .frame(width: 14, height: 14)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(0)
        .accessibilityLabel(isOn ? "Mark as incomplete" : "Mark as complete")
    }
}

#Preview {
    CalendarView()
        .frame(width: 215, height: 130)
        .background(.black)
        .environmentObject(BoringViewModel())
}
