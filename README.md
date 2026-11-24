# Daymark for macOS

Daymark is a menu-bar planner for people who divide their week between projects or activities. Give each one a share of your working hours. Daymark lays out focus blocks across the week and shows the tasks for the block you’re in. The menu bar shows a dot in the current block’s colour and the time left, such as `5h 15m` or `8m`. Hover for the block name and end time. Before setup and between blocks, look for a hollow dot. Click the dot to open your board.

## Build and open

From a fresh checkout on a Mac with macOS 14 or later and the Xcode Swift compiler and macOS SDK available through `xcrun`, run the following from the repository root.

```sh
./build.sh
open ./Daymark.app
```

The script compiles for the current Mac’s architecture, bundles the scheduler fixtures, signs the app locally and runs the self-test. The resulting app is ad hoc signed for local use. You can also double-click **Daymark.app** in Finder.

## Plan your first day

1. On first launch, Daymark opens setup beneath its menu-bar dot. Click the plus on an empty stretch to add 30 minutes, or drag across it to draw the hours you want. A day can have several work windows, so you can leave a gap for lunch or add an evening session.
2. Name your focus categories, such as Client work or Research. As you type, a new field appears and the weekly hours beside each name update. **Back** lets you revisit your hours and keeps the names you entered.
3. Choose **Finish setup** to save the schedule. The cursor moves to **Add your first task…**. Type a title and press Return to add it to **Now**. The composer then defaults to **Later**. Use **Next** for work you want to pick up soon. Now holds up to three open tasks across all categories.
4. Hover over a timeline block to preview its tasks. Click to pin the category, press Escape to clear it, or turn on the all-tasks view to see across categories. Complete a task with its checkbox. Choose an earlier date to review what you finished that day.

Drag a work window to move it or drag either edge to resize it in 15-minute increments. With the keyboard, Tab to the window or one of its ends and use the arrow keys. To remove a window, focus it and press Delete.

In schedule settings, click a window’s category dots or right-click the window to choose which categories can run there. Drag a divider between categories to adjust their shares. Category edits apply as you make them. **Save schedule** commits work hours and their category restrictions. **Cancel** discards pending hour and restriction edits.

Double-click a task title or focus it and press F2 to edit. Return saves the edit, Shift-Return adds a line, and Escape cancels. To move a task, drag it to another stage or use its **Move to** context menu. With an open task title focused, press Space or Return, choose a stage with the arrow keys, then press Space or Return to confirm. Escape cancels the move.

Click the dot again or click elsewhere to dismiss the board. To quit the app, right-click the dot and choose **Quit Daymark**.

## Local data

Tasks and schedule settings are saved together in `~/Library/Application Support/Daymark Native/workspace.json`. This file is separate from the app bundle, so rebuilding the app preserves your board. If Daymark cannot read the file it disables changes to protect the original.

The [web edition](https://nicovanzyl.com/daymark/) has its own browser storage. The native app runs offline and keeps its own workspace. The board follows the web edition’s date navigation, filtering and task movement, with macOS text editing, menus and Reduce Motion support. Browser import, cloud sync, agent intake and dictation integration are outside the native feature set.

## Development

Run the bundled self-test again after building with the following command.

```sh
./Daymark.app/Contents/MacOS/Daymark --self-test
```

It compares the Swift allocator with 88 saved examples from the web scheduler. It also exercises countdown boundaries, stage moves and capacity, title edits, historical dates, category changes, the order of visible items in animated transitions, persistence and damaged-file handling. Store tests use a temporary workspace.

To refresh expected allocations after an intentional scheduler change, run the generator with Node 24 and a checkout of the web scheduler, then rebuild. Ordinary builds use the committed fixtures and need only the native checkout.

```sh
node make-fixtures.mjs /path/to/web/src/nnl-blocks/schedule.ts
./build.sh
```

For the board layout, colour roles and interaction states, see [DESIGN.md](DESIGN.md). For source ownership and change-specific verification, see [AGENTS.md](AGENTS.md).
