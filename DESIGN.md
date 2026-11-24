# Daymark design

A long task list makes it hard to choose what to do during a focus block. Daymark narrows the board to the work that fits the current part of the day. The menu-bar countdown answers “how long do I have?” while the board answers “what can I work on?”

## Menu-bar presentation

During a focus block, the menu bar pairs a solid dot in the block’s category colour with the remaining time rounded up to whole minutes. The tooltip gives the full block name and end time. Before setup and outside scheduled blocks, a hollow neutral dot keeps the board within reach.

A single click on the dot opens a native macOS popover anchored to the status item. It fits the visible screen and contains the full board, including task entry and schedule editing. Clicking elsewhere returns the user to their work. A secondary click on the dot opens the app menu.

## Reading the board

The date strip, timeline and task groups form a single reading order. Each date carries a miniature timeline. Segment lengths reflect minutes of work on a common scale across the week, so a short working day looks shorter. When a date is selected, the tab slides to it and joins the raised board surface. Adjacent dates stay reachable at the edges of the popover. The fade uses the width of the desktop, giving neighbouring dates the same brightness as on the full-width web board. Hover or keyboard focus brings them into full colour.

The timeline gives the selected day more detail. Its marker locates the current time on today’s schedule. Hovering a block previews a category, selecting it pins the filter, and the all-tasks control opens the view across categories. The timeline contracts as the task list scrolls. The composer stays visible as the timeline collapses and the section headings stack beneath it. Scrolling over the date strip, timeline or a pinned heading scrolls the board. Clicking a heading jumps to its section.

The Mac composer keeps the category, stage, title and submit button on one row, including during first-task entry. On narrow screens the surrounding controls take less space so the title field remains usable. The date strip’s context menu includes **Back to today**.

**Now, Next, Later and Done** appear in that order. Now has three places across the entire workspace. The compact board stacks Now cards vertically. On a Now card, the muted description follows the title on the same line and wraps when the card runs out of room. Next and Later use compact rows. Done groups tasks by their completion date. Looking back at yesterday should show yesterday’s completions even if today’s queue has changed.

## Visual language

| Element | Treatment and purpose |
| --- | --- |
| Board and task surfaces | Neutral page and raised surfaces group the day’s contents. Now cards have a distinct fill. Large rounded corners belong to the board and task cards, capsules to time spans and the composer. |
| Focus categories | Six indexed colours connect the date strip, timeline, task indicators and schedule editor. A category keeps its meaning across those surfaces. A task’s stage is conveyed by its group heading. |
| Keyboard focus | The task input’s capsule lightens in dark mode and darkens in light mode while its text field has focus. Individual buttons, menus and schedule fields use a two-point neutral outline. |
| Type and numbers | Use the system typeface. Dates are larger than weekday labels. Muted text carries counts and secondary information. Monospaced digits keep changing numbers aligned. |
| Appearance | Use the semantic roles in DaymarkPalette, including blockText for text on a category fill. Light and dark appearances have separate category colours and foregrounds. |

The palette and layout are defined in [Board.swift](Sources/Board.swift). The editor uses the same palette in [ScheduleEditor.swift](Sources/ScheduleEditor.swift).

## Editing and feedback

Setup asks about working hours first, then activities. This order gives each activity a concrete weekly hours estimate as the user names it. Later edits take place inside the board. The plus adds a 30-minute window wherever it fits. Drag across a gap to draw a window, use its middle to move it and its edges to resize it. Time labels above the bar show its start and end as it changes. The category strip uses draggable dividers and alternates between target percentages and scheduled weekly hours. Category changes take effect immediately. Work-hour and restriction edits take effect on Save schedule.

A date or all-tasks change takes the visible headings and cards out in reverse reading order, then brings the incoming content in from the top. Timeline previews run the same transition on the tasks alone. A quick change of direction interrupts the transition. Reduce Motion swaps the content immediately.

Dragging lifts a copy of the task at the pointer. The source dims and the target section shows where the task will land. Dragging near the viewport edge scrolls the board. On a drop, affected cards and headings settle into place. Keyboard moves retain focus on the task.

Onboarding and settings start at the popover’s top inset. The date strip returns with the board when the editor closes. Cancel and Next stay within reach while working hours scroll. The naming step offers Back and Finish setup, and schedule settings offers Cancel and Save schedule. The editor brings in its visible fields in reading order. Direct manipulation follows the pointer in 15-minute increments. With Reduce Motion enabled the editor skips its staggered entrance and exit.

Task titles are editable in place. Drag, keyboard movement and the context menu lead to the same stage change. Keep the destination visible during a move and explain a full Now group at the point of action. Give icon controls an accessible name and pair category colours with labels wherever the user chooses a category.

## Checking a board change

Open the board beneath the menu-bar dot and check that the timeline, task list and composer fit on the smallest display you support. Use a long task title and fill Now across two categories, then filter to one of them. Check that the visible count makes sense and the fourth task still receives capacity feedback. In both appearances, inspect the selected date, a pinned block and a completed row. Use the keyboard to move a task and cancel a second move, checking where focus lands each time.
