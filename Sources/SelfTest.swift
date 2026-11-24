import Foundation

enum SelfTest {
    private struct Fixture: Codable {
        let name: String
        let work: [[WorkWindow]]
        let count: Int
        let shares: [Double]?
        let expected: [FocusBlock]
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor static func run() throws {
        func check(_ success: Bool, _ message: String) throws {
            if !success { throw Failure(description: message) }
        }
        guard let fixturePath = Bundle.main.url(forResource: "schedule-fixtures", withExtension: "json") else {
            throw Failure(description: "Missing bundled schedule fixtures.")
        }
        try check(Stage.now.shifted(-1) == .now && Stage.now.shifted(1) == .next
                  && Stage.next.shifted(1) == .later && Stage.later.shifted(1) == .later,
                  "Keyboard movement must use the board order and clamp at its ends.")
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixturePath))
        for fixture in fixtures {
            let actual = Schedule.buildWeek(fixture.work, count: fixture.count, shares: fixture.shares)
            try check(actual == fixture.expected, "Scheduler differs from web source on \(fixture.name).")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7200)!
        let boundary = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))!
        let adjacent = [FocusBlock(day: 0, start: 540, end: 720, colour: 0), FocusBlock(day: 0, start: 720, end: 750, colour: 1)]
        try check(Schedule.current(adjacent, at: boundary.addingTimeInterval(-1), calendar: calendar)?.seconds == 1, "Countdown before cutoff.")
        try check(Schedule.current(adjacent, at: boundary, calendar: calendar)?.block.colour == 1, "Exact boundary must switch focus block.")
        try check(Schedule.current(adjacent, at: boundary.addingTimeInterval(1800), calendar: calendar) == nil, "Gap must be off the clock.")

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appendingPathComponent("workspace.json")
        let store = WorkspaceStore(url: url)
        try check(store.add("A", colour: 0, stage: .now), "First Now task.")
        try check(store.add("B", colour: 0, stage: .now), "Second Now task.")
        try check(store.add("C", colour: 1, stage: .now), "Third Now task.")
        try check(!store.add("Fourth", colour: 1, stage: .now), "Now capacity must be global across categories.")
        let first = store.workspace.tasks[0].id
        try check(store.toggle(first, at: boundary), "Completing a Now task.")
        try check(store.add("D", colour: 2, stage: .now), "Completion must free a Now slot.")
        try check(!store.toggle(first, at: boundary), "Reopening cannot bypass the Now cap.")
        let key = Schedule.dateKey(boundary)
        try check(store.visible(on: key, today: key, colour: 0).count == 2, "Selected block must show its done tasks on completion date.")
        let nextKey = Schedule.dateKey(boundary.addingTimeInterval(86400))
        try check(store.visible(on: nextKey, today: key, colour: nil).count == 3, "Completed tasks must not carry forward.")
        try check(store.visible(on: key, today: nextKey, colour: nil).map(\.id) == [first], "Historical day must show only its completions.")
        let later = store.workspace.tasks.first(where: { $0.title == "D" })!.id
        try check(store.edit(later, title: " Updated title.\nKeep the second line. ", colour: 2),
                  "Multiline inline-edit state must be accepted.")
        try check(!store.edit(later, title: "   ", colour: 2), "A blank edit must leave the task intact.")
        try check(store.workspace.tasks.first(where: { $0.id == later })?.title == "Updated title.\nKeep the second line.",
                  "Editing trims margins, preserving content and line breaks.")
        try check(store.move(later, .next), "Move a task out of the full Now group.")
        try check(store.toggle(first, at: boundary), "After moving one task, reopening can use the free Now slot.")
        try check(!store.move(later, .now), "Moving back cannot bypass the Now cap.")
        let reloaded = WorkspaceStore(url: url)
        try check(reloaded.workspace == store.workspace, "Workspace values must survive relaunch.")
        var settings = reloaded.workspace.settings
        settings.labels.remove(at: 1)
        settings.shares = [1, 1]
        try check(reloaded.save(settings, coloursFrom: [0, 2]), "Saving changed labels/onboarding.")
        try check(reloaded.workspace.tasks.first(where: { $0.id == later })?.colour == 1, "Task colour must follow its surviving label.")
        let bad = Data("not valid".utf8)
        try bad.write(to: url)
        let unreadable = WorkspaceStore(url: url)
        try check(!unreadable.add("Do not overwrite", colour: 0, stage: .later), "Corrupt storage must reject writes.")
        try check(try Data(contentsOf: url) == bad, "Corrupt source must be preserved.")
        print("Compared \(fixtures.count) scheduler fixtures with the live web scheduler and exercised native countdown, task cap, dates, and persistence.")
    }
}
