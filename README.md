# Daymark for macOS

Double-click **Daymark.app** in Finder. It lives in the macOS menu bar, without a Dock icon. Choose **Open Daymark** from its clock menu. First launch opens the board to set up work hours and focus blocks. During a scheduled block the menu shows its label and rounded-up minutes left. Choose **Quit Daymark** to exit; closing the window leaves the menu item running.

This is a standalone AppKit/SwiftUI app for Apple silicon, built locally on this Mac. The app is ad hoc signed, not distributed or notarized. Its source is independent of the website checkout, with no WebView, network client, or telemetry. The App Support workspace is private to the app, separate from the website’s localStorage. There is no automatic browser import or cloud sync.

## What is ported

- Date strip with proportional category colors, timeline, current-time marker and task filtering.
- Stacked Now, Next, Later and Done sections, with Now as a three-column grid in wide windows.
- Task composer, completion/reopening, context-menu or drag moves, inline title editing and an all-tasks switch.
- Inline onboarding and schedule editing, including split work hours, category restrictions, labels and allocation weights.
- The website’s allocation algorithm ported to Swift, including per-slot restrictions; native UI and status item use the same Swift calculation.

## Differences from the web app

The native app uses system type. The work-hours editor shows the same kind of daily track and opens exact-time fields on selection; the web app’s drag-to-move, resize, and allocation-divider gestures aren’t included. Other differences remain in scroll motion, keyboard handling, and theme choices. Agent intake, website dictation integration, analytics, the website’s home link and multi-device sync aren’t included.

## Build and verification

With Xcode available, run `./build.sh` from this directory. The script builds an app for the current machine, ad hoc signs and verifies it, and runs its headless self-test. The fixture generator takes the path to the web `src/nnl-blocks/schedule.ts` and has no npm dependencies; Node 24 can execute the TypeScript module directly. Fixtures are synthetic. Build does not launch the graphical app.

To rerun the self-test:
```sh
./Daymark.app/Contents/MacOS/Daymark --self-test
```

The tests cover 88 synthetic schedules checked against the web scheduler, consecutive-block boundaries and time outside a block, task movement and limits, inline title edits, archived day filtering, category changes, durable reload, and preserving a damaged workspace file. These tests are not a substitute for manually exercising the actual menu bar and board in a desktop session.

Generated builds, screenshots, backup bundles, and workspace data are intentionally ignored by Git. The scheduler fixtures are committed so building does not require the website checkout.
