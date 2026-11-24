# Working on Daymark Native

Build and verify Swift changes with `./build.sh` from the repository root. It compiles every Swift file in Sources with warnings as errors. Edit the source and root Info.plist. The app bundle is generated output.

## Where to make a change

| When changing | Start here |
| --- | --- |
| Launch, popover lifecycle, menu-bar indicator or countdown | [Daymark.swift](Sources/Daymark.swift) owns the AppKit delegate and hosts the SwiftUI board. |
| Dates, filtering controls, task interactions or the composer | [Board.swift](Sources/Board.swift) owns presentation and transient interaction state. [BoardMotion.swift](Sources/BoardMotion.swift) measures visible elements for transitions. [TaskBoardInteraction.swift](Sources/TaskBoardInteraction.swift) handles task title layout and drag visuals. Read [DESIGN.md](DESIGN.md) for the behaviour across views. |
| Schedule editing | [ScheduleEditor.swift](Sources/ScheduleEditor.swift) coordinates setup, category persistence and draft work hours. [WorkHoursDay.swift](Sources/WorkHoursDay.swift) handles creating, moving and resizing work windows on the tracks. [FocusAllocation.swift](Sources/FocusAllocation.swift) handles category controls and share dividers. |
| Allocation, time boundaries or schedule validation | [Schedule.swift](Sources/Schedule.swift) owns the calculation shared by the board and status item. See the [fixture workflow](README.md#development) when the web algorithm changes. |
| Task rules, saved settings or file format | [Workspace.swift](Sources/Workspace.swift) owns mutations, filtered task queries and persistence. Preserve readability of existing workspaces when changing Codable models. |

## Verification by change

- For scheduler changes, compare against the committed fixtures. Investigate a mismatch before regenerating expectations. The expected blocks come from the web implementation.
- For task or storage changes, exercise the affected rule in [SelfTest.swift](Sources/SelfTest.swift) using a temporary store URL. The store publishes a mutation after its atomic write succeeds. A decode failure must preserve the original bytes.
- For UI changes, open the built app and exercise the affected path. The headless test covers model behaviour. Check focus and selection after the action, particularly when returning from settings or moving a filtered task.
- For onboarding changes, use a fresh temporary workspace. Shorten Monday by one hour, enter two names with Tab, and check that each shows 19.5h/week. Go Back to verify the hours, then finish and press Return in the focused composer to save the first Now task. Relaunch against the same temporary workspace and verify the task and schedule.
- For menu-bar changes, check the category colour, rounded-up minutes and tooltip during a block, then check the hollow dot in a gap. Click the dot to open and close the popover, dismiss it by clicking another app, then reopen it and type in the composer. Right-click the dot and verify that the quit menu opens.

When asked to commit, use a concise subject and a body explaining what changed and why.
