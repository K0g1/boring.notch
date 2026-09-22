//
//  CalendarManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import EventKit
import SwiftUI

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    private var selectedCalendars: [CalendarModel] = []
    private let calendarService = CalendarService()

    private var eventStoreChangedObserver: NSObjectProtocol?
    private var eventRequestTask: Task<[EventModel], Never>?
    private var eventRequestGeneration = 0

    private init() {
        self.currentWeekStartDate = CalendarManager.startOfDay(Date())
        setupEventStoreChangedObserver()
        Task {
            await reloadCalendarAndReminderLists()
        }
    }

    deinit {
        eventRequestTask?.cancel()
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.reloadCalendarAndReminderLists()
            }
        }
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        let all = await calendarService.calendars()
        self.eventCalendars = all
        self.allCalendars = all
        updateSelectedCalendars()
    }

    func checkCalendarAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        DispatchQueue.main.async {
            print("📅 Current calendar authorization status: \(status)")
            self.calendarAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .event) else {
                self.calendarAuthorizationStatus = .notDetermined
                return
            }
            self.calendarAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
                await updateEvents()
            }
        case .restricted, .denied:
            NSLog("Calendar access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
            await updateEvents()
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
    
    func updateSelectedCalendars() {
        selectedCalendars = allCalendars.filter { getCalendarSelected($0) }
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        switch Defaults[.calendarSelectionState] {
        case .all:
            return true
        case .selected(let identifiers):
            return identifiers.contains(calendar.id)
        }
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }

        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            selectionState =
                identifiers.isEmpty
                ? .all : identifiers.count == allCalendars.count ? .all : .selected(identifiers)  // if empty, select all
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        await updateEvents()
    }

    static func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    func updateCurrentDate(_ date: Date) async {
        let day = Calendar.current.startOfDay(for: date)
        currentWeekStartDate = day

        // A trackpad can report several settled positions while the wheel is coming to rest.
        // Cancel the previous request and only publish the result for the newest day. This keeps
        // EventKit work from racing back onto the main actor with stale data.
        eventRequestGeneration &+= 1
        let generation = eventRequestGeneration
        eventRequestTask?.cancel()

        // Let the wheel settle before touching EventKit. This collapses a fast swipe into one
        // request without delaying ordinary button/keyboard date changes in a noticeable way.
        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            return
        }
        guard generation == eventRequestGeneration else { return }

        let calendarIDs = selectedCalendars.map { $0.id }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        let request = Task { [calendarService] in
            await calendarService.events(from: day, to: end, calendars: calendarIDs)
        }
        eventRequestTask = request

        let eventsResult = await request.value
        guard !request.isCancelled, generation == eventRequestGeneration else { return }
        events = eventsResult
    }

    private func updateEvents() async {
        await updateCurrentDate(currentWeekStartDate)
    }
    
}
