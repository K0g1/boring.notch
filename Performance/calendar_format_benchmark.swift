// Run with: swift -O Performance/calendar_format_benchmark.swift
// A focused comparison of the two date-label paths, not an application CPU benchmark.
import Foundation

let calendar = Calendar.current
let today = calendar.startOfDay(for: Date())
let dates = (-7...14).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
let renders = 100

func legacyLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "E"
    return formatter.string(from: date)
}

func currentLabel(_ date: Date) -> String {
    date.formatted(.dateTime.weekday(.abbreviated))
}

func measure(_ label: (Date) -> String) -> (milliseconds: Double, characters: Int) {
    let start = ContinuousClock.now
    var characters = 0
    for _ in 0..<renders {
        for date in dates {
            characters += autoreleasepool { label(date).count }
        }
    }
    let duration = start.duration(to: .now).components
    return (Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15, characters)
}

// Warm Foundation's locale data for both paths.
for date in dates {
    precondition(legacyLabel(date) == currentLabel(date))
}
let before = measure(legacyLabel)
let after = measure(currentLabel)
precondition(before.characters == after.characters)
let result: [String: Any] = [
    "labels": dates.count * renders,
    "legacyMilliseconds": before.milliseconds,
    "currentMilliseconds": after.milliseconds,
    "speedup": before.milliseconds / after.milliseconds,
    "notes": "Warm locale, same date labels, 100 date-wheel renders. Not whole-app CPU."
]
let output = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: output, as: UTF8.self))
