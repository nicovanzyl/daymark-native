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
        let card = BoardElement.task(UUID())
        for stripWidth: CGFloat in [304, 488] {
            let neighbour = DateTabPlacement(date: .now, center: stripWidth / 2 + 104, width: stripWidth)
            try check(abs(neighbour.restingOpacity(desktopWidth: 1280) - 0.854605) < 0.00001,
                      "Neighbouring dates should match the desktop web fade at either popover width.")
        }
        let visibleFrames: [BoardElement: CGRect] = [
            .viewport: CGRect(x: 0, y: 100, width: 480, height: 200),
            .timeline: CGRect(x: 0, y: 100, width: 480, height: 24),
            .heading("Now"): CGRect(x: 0, y: 140, width: 480, height: 48),
            card: CGRect(x: 0, y: 220, width: 480, height: 90),
            .column(.now): CGRect(x: 0, y: 140, width: 480, height: 200),
            .heading("Next"): CGRect(x: 0, y: 300, width: 480, height: 48)
        ]
        try check(BoardMotion.visible(in: visibleFrames, tasksOnly: false) == [.timeline, .heading("Now"), card],
                  "Day changes animate visible reading units in order, including a partially visible card.")
        try check(BoardMotion.visible(in: visibleFrames, tasksOnly: true) == [.heading("Now"), card],
                  "Hover previews animate the visible task list independently of the timeline.")

        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixturePath))
        for fixture in fixtures {
            let actual = Schedule.buildWeek(fixture.work, count: fixture.count, shares: fixture.shares)
            try check(actual == fixture.expected, "Scheduler differs from web source on \(fixture.name).")
        }

        try check(WorkHoursDay.defaultStart(in: 0..<1440, near: 540) == 540,
                  "A click in free time starts a work window at the clicked quarter hour.")
        try check(WorkHoursDay.defaultStart(in: 0..<1440, near: 1425) == 1410,
                  "A click near midnight must fit a full 30 minutes before the end of the day.")
        try check(WorkHoursDay.defaultStart(in: 600..<630, near: 615) == 600,
                  "Clicking in a half-hour gap must fill it without overlapping its neighbours.")
        try check(WorkHoursDay.defaultStart(in: 600..<615, near: 600) == nil,
                  "Clicking a 15-minute gap must not create a shortened window.")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7200)!
        let boundary = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))!
        let adjacent = [FocusBlock(day: 0, start: 540, end: 720, colour: 0), FocusBlock(day: 0, start: 720, end: 750, colour: 1)]
        try check(Schedule.current(adjacent, at: boundary.addingTimeInterval(-1), calendar: calendar)?.seconds == 1, "Countdown before cutoff.")
        try check(Schedule.current(adjacent, at: boundary, calendar: calendar)?.block.colour == 1, "Exact boundary must switch focus block.")
        try check(Schedule.current(adjacent, at: boundary.addingTimeInterval(1800), calendar: calendar) == nil, "Gap must be off the clock.")
        let english = Locale(identifier: "en_ZA")
        for (seconds, title) in [(1, "1m"), (3540, "59m"), (3599, "1h"), (3600, "1h"), (3601, "1h 1m"), (18900, "5h 15m")] {
            try check(MenuBarStatus.countdown(seconds: seconds, locale: english).title == title,
                      "Expected the menu-bar countdown to show \(title) with \(seconds) seconds remaining.")
        }
        let spoken = MenuBarStatus.countdown(seconds: 3601, locale: english).spoken
        try check(spoken.contains("1 hour") && spoken.contains("1 minute"),
                  "VoiceOver should read the units in full.")

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appendingPathComponent("workspace.json")
        let store = WorkspaceStore(url: url)
        try check(store.workspace.needsSetup && store.workspace.settings.labels.allSatisfy(\.isEmpty)
                  && store.label(0) == "Research",
                  "A fresh workspace shows example categories until the user names a block.")
        try check(store.add("A", colour: 0, stage: .now), "First Now task.")
        try check(!WorkspaceStore(url: url).workspace.needsSetup,
                  "An existing task must bypass setup on relaunch, including after Cancel.")
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
        var restricted = reloaded.workspace.settings
        restricted.work[0] = [WorkWindow(start: 540, end: 690, allowed: [1])]
        try check(reloaded.save(restricted, coloursFrom: [0, 1]), "Set up a saved work window for category editing.")
        try check(reloaded.updateCategories(labels: ["Client", "Design", "Admin"], shares: [45, 35, 20],
                                            coloursFrom: [0, 1, nil]), "Apply a category without saving the hours draft.")
        let savedHours = WorkspaceStore(url: url).workspace.settings.work[0]
        try check(savedHours == restricted.work[0], "Category edits must preserve saved windows and their restrictions.")
        try check(reloaded.updateCategories(labels: ["Design", "Admin"], shares: [60, 40], coloursFrom: [1, 2]),
                  "Remove a category while editing the schedule.")
        let afterRemoval = WorkspaceStore(url: url).workspace
        try check(afterRemoval.settings.work[0] == [WorkWindow(start: 540, end: 690, allowed: [0])]
                  && afterRemoval.tasks.first(where: { $0.id == later })?.colour == 0,
                  "Surviving categories must keep both their tasks and their work windows.")
        let bad = Data("not valid".utf8)
        try bad.write(to: url)
        let unreadable = WorkspaceStore(url: url)
        try check(!unreadable.add("Do not overwrite", colour: 0, stage: .later), "Corrupt storage must reject writes.")
        try check(try Data(contentsOf: url) == bad, "Corrupt source must be preserved.")

        let onboardingURL = scratch.appendingPathComponent("onboarding.json")
        let fresh = WorkspaceStore(url: onboardingURL)
        var plan = fresh.workspace.settings
        plan.work[0] = [WorkWindow(start: 540, end: 960)]
        plan.labels = ["Research", "Marketing"]
        plan.shares = [50, 50]
        try check(fresh.save(plan, coloursFrom: [nil, nil]), "Finish setup with a 39-hour week.")
        let ready = WorkspaceStore(url: onboardingURL)
        try check(!ready.workspace.needsSetup && ready.workspace.tasks.isEmpty
                  && ready.workspace.settings.work == plan.work && ready.workspace.settings.labels == plan.labels,
                  "Finishing setup must persist the schedule before there is a first task.")
        try check(ready.add("Draft the research plan", colour: 0, stage: .now), "Add the first task after setup.")
        let reopened = WorkspaceStore(url: onboardingURL)
        try check(reopened.workspace == ready.workspace && reopened.workspace.tasks.first?.stage == .now,
                  "The first Now task and the completed schedule must survive a relaunch together.")
        print("Matched \(fixtures.count) web scheduler fixtures and checked 30-minute work windows, countdowns, task rules, dates, board transitions, and persistence.")
    }
}
