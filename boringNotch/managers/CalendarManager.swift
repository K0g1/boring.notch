import Defaults
import EventKit
import SwiftUI

/// Shared calendar metadata and selection. Each agenda owns its own day and results.
@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published private(set) var eventCalendars: [CalendarModel] = []
    @Published private(set) var calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var revision = 0
    private let calendarService: any CalendarServiceProviding
    private var eventStoreChangedObserver: NSObjectProtocol?
    private var reloadTask: Task<Void, Never>?

    var selectedCalendarIDs: [String] {
        eventCalendars.filter(getCalendarSelected).map(\.id)
    }

    init(calendarService: any CalendarServiceProviding = CalendarService.shared, observeChanges: Bool = true) {
        self.calendarService = calendarService
        if observeChanges {
            eventStoreChangedObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleReload() }
            }
            scheduleReload()
        }
    }

    deinit {
        reloadTask?.cancel()
        if let eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(eventStoreChangedObserver)
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            await self?.reloadCalendarAndReminderLists()
        }
    }

    func reloadCalendarAndReminderLists() async {
        let calendars = await calendarService.calendars()
        guard !Task.isCancelled else { return }
        calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if eventCalendars != calendars { eventCalendars = calendars }
        // An event can change without its calendar changing. Visible agendas must reload too.
        revision &+= 1
    }

    func checkCalendarAuthorization() async {
        calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if calendarAuthorizationStatus == .notDetermined {
            _ = try? await calendarService.requestAccess(to: .event)
        }
        await reloadCalendarAndReminderLists()
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        switch Defaults[.calendarSelectionState] {
        case .all: return true
        case .selected(let identifiers): return identifiers.contains(calendar.id)
        }
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var identifiers = Set(selectedCalendarIDs)
        if isSelected { identifiers.insert(calendar.id) } else { identifiers.remove(calendar.id) }
        Defaults[.calendarSelectionState] = identifiers == Set(eventCalendars.map(\.id))
            ? .all : .selected(identifiers)
        revision &+= 1
    }
}

struct CalendarAgendaRequest: Hashable {
    let day: Date
    let revision: Int
}

/// Owned by a visible agenda, not the singleton: different displays may show different days.
@MainActor
final class CalendarAgendaModel: ObservableObject {
    @Published private(set) var events: [EventModel] = []
    private let service: any CalendarServiceProviding
    private var generation = 0
    private var displayedDay: Date?

    init(service: any CalendarServiceProviding = CalendarService.shared) {
        self.service = service
    }

    func load(day: Date, calendarIDs: [String]) async {
        guard !Task.isCancelled else { return }
        generation &+= 1
        let requestGeneration = generation
        let day = Calendar.current.startOfDay(for: day)
        if displayedDay != day || calendarIDs.isEmpty {
            if !events.isEmpty { events = [] }
            displayedDay = day
        }
        guard !calendarIDs.isEmpty else { return }
        // The view's task is cancelled on date/selection changes and on disappearance.
        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        guard requestGeneration == generation, !Task.isCancelled,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return }
        let result = await service.events(from: day, to: end, calendars: calendarIDs)
        guard requestGeneration == generation, !Task.isCancelled else { return }
        if events != result { events = result }
    }
}
