import AppKit
import Defaults
import EventKit
import XCTest
@testable import boringNotch

final class CalendarRegressionTests: XCTestCase {
    @MainActor
    func testRapidDateChangesFetchOnlyTheSettledDay() async {
        let service = ControlledCalendarService()
        let model = CalendarAgendaModel(service: service)
        let today = Calendar.current.startOfDay(for: Date())
        var requests: [Task<Void, Never>] = []
        for offset in 0..<100 {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: today)!
            requests.append(Task { await model.load(day: date, calendarIDs: ["test"]) })
        }
        for request in requests { await request.value }
        let fetched = await service.requestedDays
        XCTAssertEqual(fetched, [Calendar.current.date(byAdding: .day, value: 99, to: today)!])
        XCTAssertEqual(model.events.first?.start, fetched.first)
    }

    @MainActor
    func testCancelledAgendaDoesNotFetchOrPublish() async {
        let service = ControlledCalendarService()
        let model = CalendarAgendaModel(service: service)
        let request = Task { await model.load(day: Date(), calendarIDs: ["test"]) }
        request.cancel()
        await request.value
        let fetched = await service.requestedDays
        XCTAssertTrue(fetched.isEmpty)
        XCTAssertTrue(model.events.isEmpty)
    }

    @MainActor
    func testOutOfOrderResultsCannotReplaceTheNewDay() async {
        let started = expectation(description: "Old day request started")
        let service = ControlledCalendarService(blockFirst: true, started: started)
        let model = CalendarAgendaModel(service: service)
        let firstDay = Calendar.current.startOfDay(for: Date())
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: firstDay)!
        let old = Task { await model.load(day: firstDay, calendarIDs: ["test"]) }
        await fulfillment(of: [started], timeout: 2)
        await model.load(day: nextDay, calendarIDs: ["test"])
        await service.releaseFirst()
        await old.value
        XCTAssertEqual(model.events.first?.start, nextDay)
    }

    @MainActor
    func testCancellationDuringEventKitWorkDiscardsItsResult() async {
        let started = expectation(description: "Request started")
        let service = ControlledCalendarService(blockFirst: true, started: started)
        let model = CalendarAgendaModel(service: service)
        let request = Task { await model.load(day: Date(), calendarIDs: ["test"]) }
        await fulfillment(of: [started], timeout: 2)
        request.cancel()
        await service.releaseFirst()
        await request.value
        XCTAssertTrue(model.events.isEmpty)
    }

    @MainActor
    func testDisplaysKeepIndependentDaysAndEmptySelectionClearsResults() async {
        let service = ControlledCalendarService()
        let left = CalendarAgendaModel(service: service)
        let right = CalendarAgendaModel(service: service)
        let day = Calendar.current.startOfDay(for: Date())
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        await left.load(day: day, calendarIDs: ["test"])
        await right.load(day: next, calendarIDs: ["test"])
        XCTAssertEqual(left.events.first?.start, day)
        XCTAssertEqual(right.events.first?.start, next)
        await left.load(day: day, calendarIDs: [])
        XCTAssertTrue(left.events.isEmpty)
        XCTAssertEqual(right.events.first?.start, next)
        let fetched = await service.requestedDays
        XCTAssertEqual(fetched.count, 2)
    }

    @MainActor
    func testLastCalendarCanBeDeselectedAndEventChangesInvalidateAgenda() async {
        let previousSelection = Defaults[.calendarSelectionState]
        defer { Defaults[.calendarSelectionState] = previousSelection }
        Defaults[.calendarSelectionState] = .all
        let manager = CalendarManager(calendarService: ControlledCalendarService(), observeChanges: false)
        await manager.reloadCalendarAndReminderLists()
        let calendar = manager.eventCalendars[0]
        await manager.setCalendarSelected(calendar, isSelected: false)
        XCTAssertTrue(manager.selectedCalendarIDs.isEmpty)
        XCTAssertFalse(manager.getCalendarSelected(calendar))
        let revision = manager.revision
        await manager.reloadCalendarAndReminderLists()
        XCTAssertGreaterThan(manager.revision, revision, "Events may change without any calendar metadata changing")
        XCTAssertTrue(manager.selectedCalendarIDs.isEmpty)
    }

    func testRecurringOccurrencesHaveDistinctStableRowIdentities() {
        let first = calendarEvent(day: Date(timeIntervalSinceReferenceDate: 100))
        let next = calendarEvent(day: Date(timeIntervalSinceReferenceDate: 200))
        XCTAssertEqual(first.id, next.id)
        XCTAssertNotEqual(AgendaItem.event(first).id, AgendaItem.event(next).id)
        XCTAssertEqual(AgendaItem.event(first).id, AgendaItem.event(first).id)
    }

    @MainActor
    func testEventStoreNotificationBurstCoalescesMetadataReloads() async throws {
        let service = ControlledCalendarService()
        let manager = CalendarManager(calendarService: service)
        for _ in 0..<100 {
            NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        }
        try await Task.sleep(for: .milliseconds(500))
        let requests = await service.calendarRequestCount
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(manager.revision, 1)
    }
}

private let testCalendar = CalendarModel(
    id: "test", account: "Test", title: "Test", color: .blue,
    isSubscribed: false, isReminder: false
)

private func calendarEvent(day: Date) -> EventModel {
    EventModel(id: "recurring-event", start: day, end: day.addingTimeInterval(60),
               title: "Fixture", location: nil, notes: nil, url: nil, isAllDay: false,
               type: .event(.accepted), calendar: testCalendar, participants: [],
               timeZone: nil, hasRecurrenceRules: true, priority: nil)
}

private actor ControlledCalendarService: CalendarServiceProviding {
    private(set) var requestedDays: [Date] = []
    private(set) var calendarRequestCount = 0
    private let blockFirst: Bool
    private let started: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?

    init(blockFirst: Bool = false, started: XCTestExpectation? = nil) {
        self.blockFirst = blockFirst
        self.started = started
    }

    func requestAccess(to type: EKEntityType) async throws -> Bool { true }
    func calendars() async -> [CalendarModel] {
        calendarRequestCount += 1
        return [testCalendar]
    }
    func events(from start: Date, to end: Date, calendars: [String]) async -> [EventModel] {
        requestedDays.append(start)
        if blockFirst && requestedDays.count == 1 {
            await withCheckedContinuation {
                continuation = $0
                started?.fulfill()
            }
        }
        return [calendarEvent(day: start)]
    }

    func releaseFirst() {
        continuation?.resume()
        continuation = nil
    }
}
