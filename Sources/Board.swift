import SwiftUI
import AppKit

struct DaymarkPalette {
    var dark: Bool
    private func rgb(_ value: UInt32) -> Color {
        Color(red: Double(value >> 16) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    var page: Color { rgb(dark ? 0x0A0A0A : 0xFFFFFF) }
    var raised: Color { rgb(dark ? 0x111111 : 0xF2F2F2) }
    var text: Color { rgb(dark ? 0xFFFFFF : 0x000000) }
    var muted: Color { rgb(dark ? 0x969CA8 : 0x686868) }
    var border: Color { rgb(dark ? 0x333333 : 0xD7D7D7) }
    var focusRing: Color { rgb(dark ? 0x909090 : 0x707070) }
    var toolbarSelected: Color { rgb(dark ? 0x242424 : 0xD2D2D2) }
    var nowTask: Color { rgb(dark ? 0x202020 : 0xD8D8D8) }
    var taskCheckboxBorder: Color { rgb(dark ? 0x252525 : 0xD6D6D6) }
    var blockText: Color { rgb(dark ? 0x15151B : 0xFFFFFF) }
    func block(_ index: Int, monochrome: Bool = false) -> Color {
        let colors: [UInt32] = dark
            ? [0xFF636B, 0xFFD34E, 0x75A7FF, 0x4DE09B, 0xBF94FF, 0xFF9B57]
            : [0xD7193F, 0xA46500, 0x2459E0, 0x00854A, 0x7939D2, 0xC24B00]
        let color = colors[min(max(index, 0), colors.count - 1)]
        if monochrome {
            let luminance = Double(color >> 16) * 0.2126 + Double((color >> 8) & 255) * 0.7152 + Double(color & 255) * 0.0722
            let grey = UInt32(luminance.rounded())
            return rgb(grey * 0x010101)
        }
        return rgb(color)
    }
}

extension View {
    func daymarkFocusRing<S: InsettableShape>(_ focused: Bool, in shape: S, palette: DaymarkPalette) -> some View {
        focusEffectDisabled()
            .overlay {
                if focused {
                    shape.strokeBorder(palette.focusRing, lineWidth: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

struct BoardPanel<Content: View, Controls: View>: View {
    let palette: DaymarkPalette
    @ViewBuilder let content: () -> Content
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(spacing: 20) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.raised, in: RoundedRectangle(cornerRadius: 24))
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .accessibilityElement(children: .contain)
            controls().frame(height: 48)
        }
    }
}

struct Board: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: WorkspaceStore
    @Environment(\.colorScheme) private var scheme
    @FocusState private var boardFocus: Bool
    @State private var hasOpenedBoard = false
    @FocusState private var composerFocus: Bool
    @FocusState private var settingsFocus: Bool
    @State private var selected: Date?
    @State private var hoveredDate: Date?
    @State private var tabPlacement: DateTabPlacement?
    @State private var requestedTab: DateTabPlacement?
    @State private var hoveredHour: Int?
    @FocusState private var focusedDate: Date?
    @FocusState private var focusedLaneBlock: Int?
    @State private var pinned: Int?
    @State private var preview: Int?
    @State private var all = false
    @State private var settingsOpen: Bool
    @State private var setupMode: Bool
    @State private var editorExitDuration = 0
    private enum BoardNavigation: Equatable {
        case open, close(focusComposer: Bool), day(Date?), taskView(Bool), category(Int)

        var tasksOnly: Bool {
            if case .category = self { return true }
            return false
        }
    }
    @State private var navigation: BoardNavigation?
    @State private var displayedColour: Int?
    @State private var motion = BoardMotion()
    @State private var draft = ""
    @State private var taskColour: Int?
    @State private var taskStage: Stage?
    @State private var keyboardMove: KeyboardTaskMove?
    @FocusState private var focusedTask: UUID?
    @FocusState private var focusedCheckbox: UUID?
    @State private var feedback: String?
    @State private var editingID: UUID?
    @State private var deleteTask: Task?
    @State private var pointerMove: TaskPointerMove?
    @State private var cancelledPointerMove = false
    @State private var boardFrames: [BoardElement: CGRect] = [:]
    private var taskViewport: CGRect { boardFrames[.viewport] ?? .zero }
    @State private var settleFrames: [BoardElement: CGRect] = [:]
    @State private var settling = false
    @State private var settleGeneration = 0
    @State private var headerPositions: [String: CGFloat] = [:]
    @State private var scrollOffset: CGFloat = 0
    @State private var savedScrollOffset: CGFloat = 0
    @State private var scrollHost = WeakBoardScrollView()
    var palette: DaymarkPalette { DaymarkPalette(dark: scheme == .dark) }

    private let onDismiss: () -> Void

    init(store: WorkspaceStore, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        self.store = store
        let setup = store.workspace.needsSetup
        _settingsOpen = State(initialValue: setup)
        _setupMode = State(initialValue: setup)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            taskDragSurface(content(at: tick.date))
        }
        .background(palette.page)
        .foregroundStyle(palette.text)
        .font(.system(size: 16))
        .task(id: navigation) {
            guard let destination = navigation else { return }
            if !reduceMotion {
                let units = BoardMotion.visible(in: boardFrames, tasksOnly: destination.tasksOnly)
                motion = BoardMotion(phase: .exiting, tasksOnly: destination.tasksOnly, units: units)
                let duration = settingsOpen ? editorExitDuration : BoardMotion.exitDuration(count: units.count)
                if duration > 0 {
                    do { try await _Concurrency.Task.sleep(for: .milliseconds(duration)) } catch { return }
                }
            }
            guard !_Concurrency.Task.isCancelled, navigation == destination else { return }
            switch destination {
            case .open:
                settingsOpen = true
            case let .close(focusComposer):
                hasOpenedBoard = true
                displayedColour = nil
                settingsOpen = false
                DispatchQueue.main.async {
                    if focusComposer { composerFocus = true } else { settingsFocus = true }
                }
            case let .day(day):
                selected = day
                all = false
                displayedColour = nil
                settingsOpen = false
                savedScrollOffset = 0
                scrollOffset = 0
                resetTaskFilter()
            case let .taskView(showAll):
                if !settingsOpen { savedScrollOffset = scrollOffset }
                settingsOpen = false
                all = showAll
                displayedColour = nil
                resetTaskFilter()
            case let .category(colour):
                displayedColour = colour
                keyboardMove = nil
                feedback = nil
            }
            navigation = nil
            motion = settingsOpen || reduceMotion ? BoardMotion() : BoardMotion(phase: .preparing, tasksOnly: destination.tasksOnly)
        }
        .task(id: motion.phase) {
            switch motion.phase {
            case .preparing:
                // Read the incoming geometry after SwiftUI has laid out the new cards.
                do { try await _Concurrency.Task.sleep(for: .milliseconds(16)) } catch { return }
                motion.units = BoardMotion.visible(in: boardFrames, tasksOnly: motion.tasksOnly)
                motion.phase = .entering
            case .entering:
                do { try await _Concurrency.Task.sleep(for: .milliseconds(625)) } catch { return }
                motion = BoardMotion()
            default: break
            }
        }
        .confirmationDialog("Delete this task?", isPresented: Binding(get: { deleteTask != nil }, set: {
            if !$0 { deleteTask = nil }
        }), titleVisibility: .visible, presenting: deleteTask) { task in
            Button("Delete Task", role: .destructive) { _ = store.delete(task.id); deleteTask = nil }
        }
    }

    private func content(at now: Date) -> some View {
        let today = Calendar.current.startOfDay(for: now)
        let active = selected ?? today
        let dayBlocks = store.blocks.filter { $0.day == Schedule.day(active) }
        let minute = Schedule.seconds(now) / 60
        let activeColour = dayBlocks.first(where: { $0.end > minute })?.colour ?? 0
        let activeMoment = Schedule.current(store.blocks, at: now)?.block
        let focusKey = "\(Schedule.dateKey(today)):\(Schedule.dateKey(active)):\(activeMoment?.id ?? -1):\(activeColour)"
        let selectedColour = pinned.flatMap { colour in dayBlocks.contains { $0.colour == colour } ? colour : nil }
        let chosen = selectedColour ?? preview ?? activeColour
        let visible = store.visible(on: Schedule.dateKey(active), today: Schedule.dateKey(today), colour: all ? nil : displayedColour ?? chosen)
        return GeometryReader { geometry in
            let width = geometry.size.width
            let gutter: CGFloat = width <= 380 ? 8 : 16
            let fade = min(192, geometry.size.height * 0.24)
            VStack(spacing: 0) {
                if settingsOpen {
                    ScheduleEditor(store: store, palette: palette, setup: setupMode, exiting: navigation != nil, bottomInset: fade,
                                   onExitDurationChange: { editorExitDuration = $0 }) { saved in
                        closeSettings(focusComposer: setupMode && saved)
                    }
                } else {
                    dateStrip(active, today: today, width: max(0, width - 2 * gutter))
                        .opacity(navigation == .open ? 0 : 1)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: navigation == .open)
                        .disabled(navigation == .open)
                    BoardPanel(palette: palette) {
                        dayViewport(blocks: dayBlocks, visible: visible, now: now, active: active, today: today,
                                    wide: width > 760, inset: width <= 640 ? 12 : 16, fade: fade)
                            .environment(\.boardMotion, motion)
                    } controls: {
                        composer(activeColour, compact: width <= 380)
                    }
                }
            }
            .padding(.horizontal, gutter)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .onChange(of: chosen, initial: true) { _, requested in requestCategory(requested) }
        .onChange(of: displayedColour == nil) { _, unselected in
            if unselected { displayedColour = chosen }
        }
        .onChange(of: all) { _, showingAll in
            if !showingAll { requestCategory(chosen) }
        }
        .onChange(of: pinned) { _, colour in
            if let colour {
                let count = store.visible(on: Schedule.dateKey(active), today: Schedule.dateKey(today), colour: colour).count
                AccessibilityNotification.Announcement("\(store.label(colour)), \(count) \(count == 1 ? "task" : "tasks")").post()
            }
        }
        .onChange(of: focusKey) { _, _ in
            all = false
            preview = nil
            keyboardMove = nil
        }
        .onChange(of: focusedTask) { _, focused in
            if let task = store.workspace.tasks.first(where: { $0.id == focused }), pointerMove == nil {
                revealFocusedTask(task)
            }
            if keyboardMove?.id != focused { keyboardMove = nil }
        }
        .onChange(of: focusedCheckbox) { _, id in
            if let task = store.workspace.tasks.first(where: { $0.id == id }) { revealFocusedTask(task) }
        }
        .onChange(of: keyboardMove?.destination) { _, stage in
            if let stage, let id = keyboardMove?.id {
                AccessibilityNotification.Announcement(destinationHint(stage, taskID: id)).post()
            }
        }
        .onChange(of: feedback) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .onChange(of: editingID) { _, id in
            if let task = store.workspace.tasks.first(where: { $0.id == id }) {
                if navigation?.tasksOnly == true { cancelNavigation() }
                preview = nil
                revealFocusedTask(task)
            } else { requestCategory(chosen) }
        }
        .onChange(of: navigation) { _, navigation in
            if navigation != nil && pointerMove != nil { finishPointerMove(commit: false); cancelledPointerMove = true }
        }
        .onExitCommand(perform: settingsOpen ? nil : {
            if navigation == .open { cancelNavigation() }
            else if pointerMove != nil { finishPointerMove(commit: false); cancelledPointerMove = true }
            else if keyboardMove != nil { keyboardMove = nil }
            else if let editingID { self.editingID = nil; focusedTask = editingID }
            else if pinned != nil || preview != nil || focusedLaneBlock != nil {
                pinned = nil; preview = nil; hoveredHour = nil
                if focusedLaneBlock != nil { boardFocus = true }
            }
            else { onDismiss() }
        })
    }

    private func requestCategory(_ colour: Int) {
        guard !settingsOpen, !all, editingID == nil, navigation == nil || navigation?.tasksOnly == true else { return }
        guard let current = displayedColour else { displayedColour = colour; return }
        if current != colour {
            navigation = .category(colour)
        } else if navigation?.tasksOnly == true {
            cancelNavigation()
        }
    }

    private func cancelNavigation() {
        navigation = nil
        if motion.phase == .exiting && !reduceMotion {
            motion.phase = .entering
        } else { motion = BoardMotion() }
    }

    private var groupTitles: [String] { Stage.allCases.map(\.rawValue) + ["Done"] }

    private func headingIsPinned(_ title: String, at top: CGFloat) -> Bool {
        scrollOffset >= 64 && (headerPositions[title] ?? .infinity) < top
    }

    private func dayViewport(blocks: [FocusBlock], visible: [Task], now: Date, active: Date, today: Date,
                             wide: Bool, inset: CGFloat, fade: CGFloat) -> some View {
        let groups = Stage.allCases.map { stage in visible.filter { $0.completedOn == nil && $0.stage == stage } }
            + [visible.filter { $0.completedOn != nil }]
        let progress = focusedLaneBlock == nil ? min(1, max(0, scrollOffset / 64)) : 0
        let timelineTop = max(0, inset - scrollOffset)
        let timelineHeight = 64 - progress * 40
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BoardScrollResolver { view in
                    scrollHost.value = view
                    if savedScrollOffset > 0 {
                        setBoardOffset(savedScrollOffset)
                        savedScrollOffset = 0
                    }
                } scrolled: { offset in
                    scrollOffset = max(0, offset)
                }.frame(height: 0)
                Color.clear.frame(height: 64).accessibilityHidden(true)
                if let feedback = store.error ?? feedback {
                    Text(feedback).foregroundStyle(palette.muted).padding(.vertical, 8)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if !visible.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groupTitles.indices, id: \.self) { index in
                            let title = groupTitles[index]
                            let stage = index < Stage.allCases.count ? Stage.allCases[index] : nil
                            let top = timelineTop + timelineHeight + CGFloat(index) * 48
                            taskGroup(title, stage: stage, tasks: groups[index], now: now, wide: wide,
                                      pinnedHeading: headingIsPinned(title, at: top))
                                .background {
                                    GeometryReader { geo in
                                        Color.clear.preference(key: DaymarkSectionPositions.self,
                                            value: [title: geo.frame(in: .named("daymark-scroll")).minY])
                                    }
                                }
                        }
                    }
                    .padding(.top, 24).padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
            .padding(.top, inset)
            .padding(.bottom, fade)
        }
        .coordinateSpace(name: "daymark-scroll")
        .onPreferenceChange(DaymarkSectionPositions.self) { headerPositions = $0 }
        .id(Schedule.dateKey(active) + String(all))
        .background(alignment: .bottom) {
            LinearGradient(colors: [palette.raised, palette.page], startPoint: .top, endPoint: .bottom)
                .frame(height: fade).allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if !visible.isEmpty {
                ForEach(groupTitles.indices, id: \.self) { index in
                    let title = groupTitles[index]
                    let top = timelineTop + timelineHeight + CGFloat(index) * 48
                    if headingIsPinned(title, at: top) {
                        taskHeading(title, count: groups[index].count, stage: index < Stage.allCases.count ? Stage.allCases[index] : nil)
                        .padding(.horizontal, inset).frame(height: 48)
                        .background(palette.raised)
                        .offset(y: top)
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            lane(all || store.workspace.needsSetup ? [] : blocks, referenceBlocks: blocks, now: now, active: active, today: today,
                 collapse: progress)
                .modifier(BoardMotionUnit(.timeline))
                .padding(.horizontal, inset)
                .frame(height: timelineHeight, alignment: .top)
                .clipped()
                .padding(.top, timelineTop)
                .background(palette.raised)
        }
        .background(BoardFrameReader(key: .viewport))
        .focusable().focusEffectDisabled().focused($boardFocus)
        .onAppear {
            if !hasOpenedBoard {
                hasOpenedBoard = true
                DispatchQueue.main.async { boardFocus = true }
            }
        }
    }

    private func revealFocusedTask(_ task: Task) {
        guard let frame = boardFrames[.task(task.id)], let viewport = boardFrames[.viewport] else { return }
        let group = task.completedOn == nil ? task.stage.rawValue : "Done"
        let pinnedHeight = 24 + CGFloat(1 + (groupTitles.firstIndex(of: group) ?? 0)) * 48
        if frame.minY < viewport.minY + pinnedHeight, scrollOffset > 0 {
            setBoardOffset(scrollOffset + frame.minY - viewport.minY - pinnedHeight)
        } else if frame.maxY > viewport.maxY {
            setBoardOffset(scrollOffset + frame.maxY - viewport.maxY)
        }
    }

    private func jumpToGroup(_ title: String) {
        guard let position = headerPositions[title], let index = groupTitles.firstIndex(of: title) else { return }
        let target = max(0, scrollOffset + position - 24 - CGFloat(index) * 48)
        setBoardOffset(target, animated: !reduceMotion)
    }

    private func setBoardOffset(_ y: CGFloat, animated: Bool = false) {
        guard let scrollView = scrollHost.value, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let target = min(max(0, y), max(0, document.bounds.height - clip.bounds.height))
        let origin = NSPoint(x: clip.bounds.minX, y: target)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    private func openSettings() {
        savedScrollOffset = scrollOffset
        setupMode = store.workspace.needsSetup
        if navigation == .open { cancelNavigation() } else { navigation = .open }
        preview = nil
    }

    private func closeSettings(focusComposer: Bool = false) {
        navigation = .close(focusComposer: focusComposer)
    }

    private func choose(_ day: Date, today: Date) {
        let target = day == today ? nil : day
        if target == selected && !settingsOpen {
            if case .day = navigation { cancelNavigation() }
            return
        }
        navigation = .day(target)
    }

    private func resetTaskFilter() {
        keyboardMove = nil
        pinned = nil
        preview = nil
        hoveredHour = nil
        feedback = nil
    }

    private func dateStrip(_ active: Date, today: Date, width: CGFloat) -> some View {
        let desktopWidth = (scrollHost.value?.window?.screen ?? NSScreen.main)?.visibleFrame.width ?? width
        let fadeAnimation: Animation? = reduceMotion ? nil : .timingCurve(0.25, 1, 0.5, 1, duration: 0.14)
        let placement = requestedTab?.date == active ? requestedTab : tabPlacement
        let anchor: CGFloat
        if let placement, placement.date == active, placement.width == width {
            anchor = placement.center
        } else {
            anchor = width / 2
        }
        let byDay = Dictionary(grouping: store.blocks, by: \.day)
        let maxMinutes = max(1, byDay.values.map { $0.reduce(0) { $0 + $1.end - $1.start } }.max() ?? 0)
        let allocationWidth = max(0, 64 - 2 * CGFloat((byDay.values.map(\.count).max() ?? 1) - 1))
        let radius = Int(ceil(width / 104))
        let dates = (-radius...radius).compactMap { offset -> DateTabPlacement? in
            let x = anchor + CGFloat(offset) * 104
            // A neighbour at the edge may give up its outer padding. Its date and allocation stay fully visible.
            let visibleWidth = min(96, 2 * min(x, width - x))
            guard visibleWidth >= (abs(offset) == 1 ? 64 : 96),
                  let date = Calendar.current.date(byAdding: .day, value: offset, to: active) else { return nil }
            return DateTabPlacement(date: date, center: x, width: width)
        }
        return ZStack(alignment: .topLeading) {
            FusedDateTab()
                .fill(palette.raised)
                .frame(width: 128, height: 86)
                .position(x: anchor, y: 43)
                .animation(reduceMotion ? nil : .timingCurve(0.25, 1, 0.5, 1, duration: 0.4), value: active)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            ForEach(dates) { tab in
                let date = tab.date
                let blocks = byDay[Schedule.day(date)] ?? []
                let hot = date == active || hoveredDate == date || focusedDate == date
                let opacity = tab.restingOpacity(desktopWidth: desktopWidth)
                Button {
                    selectTab(tab, active: active, today: today)
                } label: {
                    VStack(spacing: 4) {
                        Text(date.formatted(.dateTime.day())).font(.system(size: 24))
                            .monospacedDigit().frame(height: 24)
                        Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.system(size: 12)).frame(height: 18)
                        HStack(spacing: 2) {
                            ForEach(blocks) { block in
                                Capsule()
                                    .fill(palette.block(block.colour, monochrome: !hot))
                                    .frame(width: allocationWidth * CGFloat(block.end - block.start) / CGFloat(maxMinutes), height: 4)
                                    .help("\(store.label(block.colour)), \(Schedule.clock(block.start))–\(Schedule.clock(block.end))")
                            }
                        }.frame(width: 64, height: 4)
                    }
                    .frame(width: min(96, 2 * min(tab.center, width - tab.center)), height: 86)
                    .foregroundStyle(hot ? palette.text : palette.muted)
                    .overlay(alignment: .top) {
                        if date != active && date == today {
                            Circle().fill(palette.text).frame(width: 3, height: 3).padding(.top, 4)
                        }
                    }
                    .opacity(hot ? 1 : opacity)
                    .animation(fadeAnimation, value: hot)
                    .animation(fadeAnimation, value: opacity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ScheduleButtonStyle())
                .focusable().focused($focusedDate, equals: date)
                .focusEffectDisabled()
                .onKeyPress(.return) {
                    selectTab(tab, active: active, today: today)
                    return .handled
                }
                .onHover { inside in
                    if inside { hoveredDate = date }
                    else if hoveredDate == date { hoveredDate = nil }
                }
                .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                .accessibilityHint("\(blocks.count) scheduled blocks")
                .accessibilityAddTraits(date == active ? .isSelected : [])
                .position(x: tab.center, y: 43)
            }
        }
        .frame(width: width, height: 86)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar dates")
        .contextMenu {
            Button("Back to today") { choose(today, today: today) }
        }
        .onChange(of: active) {
            tabPlacement = DateTabPlacement(date: active, center: anchor, width: width)
            requestedTab = nil
        }
        .accessibilityScrollAction { edge in
            let step = edge == .leading ? -1 : edge == .trailing ? 1 : 0
            guard step != 0, let date = Calendar.current.date(byAdding: .day, value: step, to: active) else { return }
            selectTab(DateTabPlacement(date: date, center: anchor + CGFloat(step) * 104, width: width),
                      active: active, today: today)
        }
        .onMoveCommand { direction in
            let step = direction == .left ? -1 : direction == .right ? 1 : 0
            let origin = focusedDate ?? active
            guard step != 0, let date = Calendar.current.date(byAdding: .day, value: step, to: origin) else { return }
            selectTab(dates.first { $0.date == date } ?? DateTabPlacement(date: date, center: width / 2, width: width),
                      active: active, today: today)
            focusedDate = date
        }
    }

    private func selectTab(_ tab: DateTabPlacement, active: Date, today: Date) {
        guard tab.date != active else {
            requestedTab = nil
            choose(active, today: today)
            return
        }
        // Keep the tab near the click while leaving a full neighbouring day available at either edge.
        let inset = min(tab.width / 2, 32 + 104)
        requestedTab = DateTabPlacement(date: tab.date, center: min(max(inset, tab.center), tab.width - inset), width: tab.width)
        choose(tab.date, today: today)
    }

    private func lane(_ blocks: [FocusBlock], referenceBlocks: [FocusBlock], now: Date, active: Date, today: Date, collapse: CGFloat = 0) -> some View {
        let second = Schedule.seconds(now)
        let thisDay = active == today
        let start = referenceBlocks.isEmpty ? 0 : min(referenceBlocks[0].start, thisDay ? second / 3600 * 60 : 1440)
        let end = referenceBlocks.isEmpty ? 1440 : max(referenceBlocks.last?.end ?? 1440, thisDay ? (second / 3600 + 1) * 60 : 0)
        let hoverMinute = hoveredHour.map { min(end, max(start, $0)) }
        let minute = hoverMinute ?? second / 60
        let preciseMinute = hoverMinute.map(CGFloat.init) ?? CGFloat(second) / 60
        let marks = blocks
        let blend = focusedLaneBlock != nil ? 0 : min(max(0, collapse), 1)
        let laneHeight = 64 - 40 * blend
        let labelsOpacity = max(0, 1 - blend / 0.6)
        let barHeight = 32 - 28 * blend
        let barY = 10 * blend
        let gapTicks = (0..<24).map { $0 * 60 }.filter { tick in
            tick > start && tick < end && !marks.contains { tick >= $0.start && tick <= $0.end }
        }
        let markerColour = marks.first { $0.start <= minute && minute < $0.end }?.colour
        return GeometryReader { geometry in
            let width = geometry.size.width
            let position: (CGFloat) -> CGFloat = { (CGFloat($0) - CGFloat(start)) / CGFloat(max(1, end - start)) * width }
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                ForEach(gapTicks, id: \.self) { tick in
                    Capsule().fill(palette.border).frame(width: 2, height: 16)
                        .opacity(labelsOpacity).position(x: position(CGFloat(tick)), y: 16)
                }
                ForEach(Array(marks.enumerated()), id: \.element.id) { index, block in
                    let startX = position(CGFloat(block.start))
                    let endX = position(CGFloat(block.end))
                    let leading: CGFloat = index > 0 && marks[index - 1].end == block.start ? 2 : 0
                    let trailing: CGFloat = index + 1 < marks.count && marks[index + 1].start == block.end ? 2 : 0
                    let length = max(1, endX - startX - leading - trailing)
                    let colour = palette.block(block.colour)
                    Button {
                        toggleLaneBlock(block)
                    } label: {
                        ZStack(alignment: .leading) {
                            colour
                            if blend < 0.6 && length > 12 {
                                Text(store.label(block.colour))
                                    .font(.system(size: 16)).lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .foregroundStyle(palette.blockText)
                                    .opacity(labelsOpacity)
                            }
                            if preciseMinute >= CGFloat(block.start) && preciseMinute < CGFloat(block.end) {
                                HStack(spacing: 0) {
                                    LinearGradient(colors: [colour.opacity(0), colour], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                                    colour.frame(width: 2)
                                    LinearGradient(colors: [colour, colour.opacity(0)], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                                }
                                .frame(height: barHeight)
                                .opacity(labelsOpacity).offset(x: position(preciseMinute) - startX - leading - 17)
                                .allowsHitTesting(false)
                            }
                        }
                        .frame(width: length, height: barHeight)
                        .clipShape(Capsule())
                        .overlay {
                            if focusedLaneBlock == block.id || pinned == block.colour {
                                let dashed = focusedLaneBlock == block.id
                                Capsule().inset(by: 3)
                                    .stroke(palette.blockText, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : []))
                                    .opacity(labelsOpacity)
                            }
                        }
                    }
                    .buttonStyle(ScheduleButtonStyle())
                    .focusable().focused($focusedLaneBlock, equals: block.id)
                    .focusEffectDisabled()
                    .onKeyPress(.return) {
                        toggleLaneBlock(block)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        preview = nil
                        pinned = nil
                        hoveredHour = nil
                        return .handled
                    }
                    .offset(x: startX + leading, y: barY)
                    .accessibilityHint("Toggle this block’s tasks")
                    .accessibilityLabel("\(store.label(block.colour)), \(Schedule.clock(block.start)) to \(Schedule.clock(block.end))")
                    .accessibilityAddTraits(pinned == block.colour ? .isSelected : [])
                }
                if minute >= start && minute <= end {
                    let x = position(preciseMinute)
                    let markerHeight = 16 - 14 * blend
                    Capsule().fill(markerColour != nil ? palette.blockText : palette.muted)
                        .frame(width: 2, height: markerHeight)
                        .position(x: x, y: 8 + 3 * blend + markerHeight / 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    let labelWidth: CGFloat = 48
                    Text(Schedule.clock(minute)).font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(palette.muted)
                        .frame(width: labelWidth, alignment: minute == start ? .leading : minute == end ? .trailing : .center)
                        .position(x: minute == start ? x + labelWidth / 2 : minute == end ? x - labelWidth / 2 : x, y: 40)
                        .opacity(labelsOpacity)
                        .allowsHitTesting(false)
                        .accessibilityLabel("\(hoveredHour == nil ? "Current" : "Timeline") time \(Schedule.clock(minute))")
                }
            }
            .frame(width: width, height: laneHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { event in
                switch event {
                case .active(let location):
                    guard width > 0, (0...laneHeight).contains(location.y) else { return }
                    let anchorMinute = CGFloat(start) + location.x / width * CGFloat(end - start)
                    hoveredHour = min(end, max(start, Int((anchorMinute / 60).rounded()) * 60))
                    if editingID == nil, focusedTask == nil, focusedCheckbox == nil, keyboardMove == nil,
                       pointerMove == nil, NSEvent.pressedMouseButtons == 0 {
                        preview = marks.first { anchorMinute >= CGFloat($0.start) && anchorMinute < CGFloat($0.end) }?.colour
                    }
                case .ended:
                    hoveredHour = nil
                    preview = nil
                }
            }
        }
        .frame(height: laneHeight).clipped().contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Schedule.weekdays[Schedule.day(active)]) timeline")
    }

    private func toggleLaneBlock(_ block: FocusBlock) {
        preview = nil
        pinned = pinned == block.colour ? nil : block.colour
    }

    private var dropTarget: Stage? {
        guard let point = pointerMove?.location, taskViewport.contains(point) else { return nil }
        if point.y < taskViewport.minY + max(24, 64 - scrollOffset) { return nil }
        // Sticky headings are rendered over the underlying columns.
        if let heading = groupTitles.last(where: { boardFrames[.heading($0)]?.contains(point) == true }) {
            return Stage(rawValue: heading)
        }
        return Stage.allCases.first { boardFrames[.column($0)]?.contains(point) == true }
    }

    private func taskDragSurface<Content: View>(_ content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if let drag = pointerMove {
                    taskCard(drag.task, now: .now, stretch: true, allowsWrap: drag.task.stage == .now, ghost: true)
                        .frame(width: drag.frame.width, height: drag.frame.height, alignment: .topLeading)
                        .shadow(color: palette.text.opacity(0.12), radius: 16, y: 6)
                        .offset(x: drag.frame.minX, y: drag.frame.minY)
                        .accessibilityHidden(true).allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "task-drag-surface")
            .onPreferenceChange(BoardFrames.self) { boardFrames = $0 }
            .task(id: pointerMove?.task.id) {
                while let pointer = pointerMove?.location, !_Concurrency.Task.isCancelled {
                    let edge = min(48, taskViewport.height / 4)
                    if pointer.y < taskViewport.minY + edge { setBoardOffset(scrollOffset - 10) }
                    else if pointer.y > taskViewport.maxY - edge { setBoardOffset(scrollOffset + 10) }
                    do { try await _Concurrency.Task.sleep(for: .milliseconds(16)) } catch { return }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                if NSEvent.pressedMouseButtons == 0 { cancelledPointerMove = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                if pointerMove != nil { finishPointerMove(commit: false); cancelledPointerMove = NSEvent.pressedMouseButtons != 0 }
                keyboardMove = nil
            }
    }

    private func trackPointer(_ value: DragGesture.Value, task: Task) {
        guard !cancelledPointerMove, task.completedOn == nil else { return }
        NSCursor.closedHand.set()
        if pointerMove == nil, let bounds = boardFrames[.task(task.id)] {
            keyboardMove = nil
            focusedTask = task.id
            pointerMove = TaskPointerMove(task: task, origin: bounds,
                                          start: value.startLocation, location: value.location)
        } else {
            pointerMove?.location = value.location
        }
    }

    private func finishPointerMove(commit: Bool) {
        guard let drag = pointerMove else { return }
        let target = commit ? dropTarget : nil
        NSCursor.arrow.set()
        settle(from: drag) {
            pointerMove = nil
            if let target { move(drag.task.id, to: target, restoreFocus: false) }
        }
    }

    private func settle(from drag: TaskPointerMove? = nil, _ update: () -> Void) {
        guard !reduceMotion else { update(); return }
        settleGeneration += 1
        let generation = settleGeneration
        var frames = boardFrames
        if let drag { frames[.task(drag.task.id)] = drag.frame }
        settleFrames = frames
        settling = true
        update()
        DispatchQueue.main.async {
            guard settleGeneration == generation else { return }
            withAnimation(.timingCurve(0.25, 1, 0.5, 1, duration: 0.4)) { settling = false }
        }
    }

    private func taskGroup(_ title: String, stage: Stage?, tasks: [Task], now: Date, wide: Bool, pinnedHeading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            taskHeading(title, count: tasks.count, stage: stage)
                .accessibilityHidden(pinnedHeading)
                .allowsHitTesting(!pinnedHeading)
            taskList(stage, tasks: tasks, now: now, wide: wide)
                .padding(.top, 12)
                .padding(.bottom, stage == nil ? 0 : 48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let stage { BoardFrameReader(key: .column(stage)) }
        }
    }

    private func taskList(_ stage: Stage?, tasks: [Task], now: Date, wide: Bool) -> some View {
        Group {
            if stage == .now && wide {
                EqualTaskRow(gap: 16) {
                    ForEach(tasks) { task in taskRow(task, now: now, stretch: true, allowsWrap: true) }
                }
            } else {
                VStack(alignment: .leading, spacing: stage == .now ? 16 : 4) {
                    ForEach(tasks) { task in taskRow(task, now: now, stretch: false, allowsWrap: stage == .now) }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
        .background {
            if let stage, dropTarget == stage || keyboardMove?.destination == stage {
                RoundedRectangle(cornerRadius: 24).fill(palette.muted.opacity(0.08))
            }
        }
    }

    private func taskHeading(_ title: String, count: Int, stage: Stage?) -> some View {
        HStack(spacing: 8) {
            Button { jumpToGroup(title) } label: { Text(title).frame(height: 48).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .daymarkFocusRing(in: RoundedRectangle(cornerRadius: 8), palette: palette)
                .padding(.horizontal, -4)
                .accessibilityLabel("Scroll to \(title) tasks")
            Text(count, format: .number).foregroundStyle(palette.muted).monospacedDigit()
            Spacer()
            if let stage, keyboardMove?.destination == stage || dropTarget == stage {
                let id = pointerMove?.task.id ?? keyboardMove?.id
                Text(destinationHint(stage, taskID: id))
                    .foregroundStyle(palette.muted)
            }
        }
        .frame(height: 48)
        .accessibilityAddTraits(.isHeader)
        .modifier(TaskSettle(origin: settling ? settleFrames[.heading(title)] : nil))
        .modifier(BoardMotionUnit(.heading(title)))
    }

    private func destinationHint(_ stage: Stage, taskID: UUID?) -> String {
        if stage == .now && !store.canEnterNow(excluding: taskID) { return "Now is full" }
        let same = store.workspace.tasks.first { $0.id == taskID }?.stage == stage
        return "\(same ? "Keep in" : "Move to") \(stage.rawValue)"
    }

    private func togglePickup(_ task: Task) {
        if let moveState = keyboardMove, moveState.id == task.id {
            keyboardMove = nil
            if moveState.destination != task.stage { settle { move(task.id, to: moveState.destination) } }
        } else {
            keyboardMove = KeyboardTaskMove(id: task.id, destination: task.stage)
        }
    }

    private func handleMoveKey(_ press: KeyPress, task: Task) -> KeyPress.Result {
        guard task.completedOn == nil else { return .ignored }
        switch press.key {
        case .space, .return:
            togglePickup(task)
            return .handled
        case .leftArrow, .upArrow, .rightArrow, .downArrow:
            guard var active = keyboardMove, active.id == task.id else { return .ignored }
            active.destination = active.destination.shifted(press.key == .leftArrow || press.key == .upArrow ? -1 : 1)
            keyboardMove = active
            return .handled
        case .escape:
            guard keyboardMove?.id == task.id else { return .ignored }
            keyboardMove = nil
            return .handled
        default: return .ignored
        }
    }

    private func taskRow(_ task: Task, now: Date, stretch: Bool, allowsWrap: Bool) -> some View {
        taskCard(task, now: now, stretch: stretch, allowsWrap: allowsWrap, ghost: false)
            .modifier(TaskSettle(origin: settling ? settleFrames[.task(task.id)] : nil))
            .modifier(BoardMotionUnit(.task(task.id)))
            .contextMenu {
                Button("Edit Task") { editingID = task.id }
                if task.completedOn == nil {
                    Menu("Move to") {
                        ForEach(Stage.allCases) { stage in
                            Button(stage.rawValue) { move(task.id, to: stage) }
                                .disabled(stage == .now && !store.canEnterNow(excluding: task.id))
                        }
                    }
                }
                Menu("Focus block") {
                    ForEach(store.workspace.settings.labels.indices, id: \.self) { colour in
                        Button(store.label(colour)) { _ = store.edit(task.id, title: task.title, colour: colour) }
                    }
                }
                Button("Delete…", role: .destructive) { deleteTask = task }
            }
    }

    private func taskCard(_ task: Task, now: Date, stretch: Bool, allowsWrap: Bool, ghost: Bool) -> some View {
        let dragging = !ghost && pointerMove?.task.id == task.id
        return HStack(alignment: .top, spacing: 10) {
            if ghost {
                checkboxMark(completed: false).padding(.top, 12)
                TaskTitleLabel(task: task, palette: palette, allowsWrap: allowsWrap)
                    .padding(.vertical, 12).frame(minHeight: 44, alignment: .leading)
            } else {
                Button { toggleTask(task.id, at: now) } label: { checkboxMark(completed: task.completedOn != nil) }
                    .buttonStyle(.plain)
                    .focused($focusedCheckbox, equals: task.id)
                    .accessibilityRepresentation {
                        Toggle("Complete \(task.title)", isOn: Binding(get: { task.completedOn != nil }, set: { checked in
                            if checked != (task.completedOn != nil) { toggleTask(task.id, at: now) }
                        })).toggleStyle(.checkbox).labelsHidden().frame(width: 20, height: 20)
                    }
                    .frame(width: 20, height: 20)
                    .daymarkFocusRing(focusedCheckbox == task.id, in: RoundedRectangle(cornerRadius: 8), palette: palette)
                    .padding(.top, 12)
                InlineTaskTitle(task: task, palette: palette, allowsWrap: allowsWrap,
                                editingID: $editingID, focusedTask: $focusedTask,
                                dragging: keyboardMove?.id == task.id,
                                activate: {
                                    if task.completedOn != nil { editingID = task.id; return }
                                    focusedTask = task.id
                                    togglePickup(task)
                                },
                                dragChanged: { trackPointer($0, task: task) },
                                dragEnded: { value in
                                    if !cancelledPointerMove {
                                        pointerMove?.location = value.location
                                        finishPointerMove(commit: true)
                                    }
                                    cancelledPointerMove = false
                                },
                                keyHandler: { handleMoveKey($0, task: task) }) { title, removeEmpty in
                    if removeEmpty && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = store.delete(task.id)
                    } else {
                        _ = store.edit(task.id, title: title, colour: min(task.colour, store.workspace.settings.labels.count - 1))
                    }
                }
            }
        }
        .opacity(dragging ? 0.2 : 1)
        .padding(.leading, 12)
        .padding(.trailing, all ? 28 : 12)
        .padding(.vertical, allowsWrap ? 8 : 4)
        .frame(maxWidth: stretch ? .infinity : nil, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
        .background(dragging ? Color.clear : (ghost || allowsWrap ? palette.nowTask : palette.page), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            if keyboardMove?.id == task.id {
                RoundedRectangle(cornerRadius: 24).strokeBorder(palette.block(task.colour), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if all {
                Circle().fill(palette.block(task.colour)).frame(width: 6, height: 6)
                    .padding(14).opacity(dragging ? 0.2 : 1).allowsHitTesting(false)
                    .accessibilityLabel(store.label(task.colour))
            }
        }

    }

    private func checkboxMark(completed: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(palette.raised)
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.taskCheckboxBorder) }
            .frame(width: 20, height: 20)
            .overlay {
                if completed { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
            }
    }

    private func toggleTask(_ id: UUID, at now: Date) {
        feedback = store.toggle(id, at: now) ? nil : store.error ?? "Now is full. Move or complete a task first."
    }

    private func move(_ id: UUID, to stage: Stage, restoreFocus: Bool = true) {
        guard let task = store.workspace.tasks.first(where: { $0.id == id }), task.stage != stage else { return }
        guard store.move(id, stage) else {
            feedback = store.error ?? "Now is full. Move or complete a task first."
            return
        }
        feedback = nil
        AccessibilityNotification.Announcement("Moved \(task.title) to \(stage.rawValue).").post()
        if restoreFocus { DispatchQueue.main.async { focusedTask = id } }
    }

    private func composer(_ activeColour: Int, compact: Bool) -> some View {
        let count = store.workspace.settings.labels.count
        let first = store.workspace.settings.onboardingComplete && store.workspace.tasks.isEmpty
        let colour = min(taskColour ?? activeColour, count - 1)
        let stage = taskStage ?? (first ? .now : .later)
        let enabled = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (stage != .now || store.canEnterNow())
        let submit = {
            guard enabled else { return }
            if store.add(draft, colour: colour, stage: stage) {
                draft = ""; taskStage = .later; feedback = nil; composerFocus = true
            }
        }
        let gap: CGFloat = compact ? 4 : 6
        let submitSize: CGFloat = compact ? 32 : 36
        let toolbarSize: CGFloat = compact ? 36 : 44
        return HStack(spacing: 4) {
            HStack(spacing: gap) {
                Menu {
                    Picker("Task block", selection: Binding(get: { colour }, set: { taskColour = $0 })) {
                        ForEach(0..<count, id: \.self) { index in
                            Text(store.label(index)).tag(index)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "circle.fill").symbolRenderingMode(.palette)
                        .foregroundStyle(palette.block(colour)).font(.system(size: 12))
                        .frame(width: compact ? 24 : 32, height: 40)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .menuIndicator(.hidden)
                .daymarkFocusRing(in: Capsule(), palette: palette)
                .help(store.label(colour))
                .accessibilityLabel("Task block, \(store.label(colour))")
                Menu {
                    ForEach(Stage.allCases) { option in
                        Button {
                            taskStage = option
                        } label: {
                            if option == stage { Label(option.rawValue, systemImage: "checkmark") }
                            else { Text(option.rawValue) }
                        }
                        .disabled(option == .now && !store.canEnterNow())
                    }
                } label: {
                    // AppKit's borderless menu normalizes a text-and-image label to a leading icon.
                    // Use a custom button label so the disclosure stays at the trailing edge.
                    HStack(spacing: gap) {
                        Text(stage.rawValue).font(.system(size: 16)).fixedSize()
                        if !compact { Spacer(minLength: 0) }
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                            .accessibilityHidden(true)
                    }
                    .frame(width: compact ? 56 : 68, height: 32).contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 3)
                .daymarkFocusRing(in: RoundedRectangle(cornerRadius: 8), palette: palette)
                .padding(.horizontal, -3)
                .accessibilityLabel("Task stage, \(stage.rawValue)")
                TextField("New task", text: $draft,
                          prompt: Text(first ? "Add your first task…" : "Add a task…")
                            .foregroundStyle(composerFocus ? palette.text.opacity(0.65) : palette.muted))
                    .textFieldStyle(.plain)
                    .focused($composerFocus)
                    .focusEffectDisabled()
                    .onSubmit(submit)
                    .onChange(of: draft) { _, text in
                        if text.count > 240 { draft = String(text.prefix(240)) }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 40, maxHeight: 40)
                    .accessibilityLabel("New task")
                Button(action: submit) {
                    Text("↑").font(.system(size: 14))
                        .frame(width: submitSize, height: submitSize).foregroundStyle(palette.page)
                        .background(palette.text, in: Circle())
                        .opacity(enabled ? 1 : 0.4)
                }
                .buttonStyle(ScheduleButtonStyle())
                .daymarkFocusRing(in: Circle(), palette: palette)
                .disabled(!enabled)
                .accessibilityLabel("Add task")
            }
            .font(.system(size: 16))
            .padding(.horizontal, gap).padding(.vertical, 4)
            .background(composerFocus ? palette.toolbarSelected : palette.raised, in: Capsule())
            toolbarButton(all ? .focus : .list, label: all ? "Return to focus" : "Show all tasks", selected: all, size: toolbarSize) {
                if case .taskView = navigation {
                    cancelNavigation()
                } else {
                    navigation = .taskView(!all)
                }
            }
            .daymarkFocusRing(in: Circle(), palette: palette)
            toolbarButton(.settings, label: "Configure your schedule", size: toolbarSize) {
                openSettings()
            }
            .focusable().focused($settingsFocus)
            .daymarkFocusRing(settingsFocus, in: Circle(), palette: palette)
            .accessibilityLabel("Settings")
            .accessibilityValue("Collapsed")
        }.frame(maxWidth: 760).frame(maxWidth: .infinity)
    }

    private func toolbarButton(_ glyph: DaymarkToolbarGlyph, label: String, selected: Bool = false, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Canvas { context, size in
                    let color = palette.text
                    let sx = size.width / 24
                    let sy = size.height / 24
                    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
                    func line(_ x1: CGFloat, _ y: CGFloat, _ x2: CGFloat) {
                        var stroke = Path()
                        stroke.move(to: pt(x1, y)); stroke.addLine(to: pt(x2, y))
                        context.stroke(stroke, with: .color(color), style: StrokeStyle(lineWidth: 1.5 * sx, lineCap: .round))
                    }
                    func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
                        Path(ellipseIn: CGRect(x: (x-r)*sx, y: (y-r)*sy, width: 2*r*sx, height: 2*r*sy))
                    }
                    switch glyph {
                    case .list:
                        for y in [CGFloat(6), 12, 18] {
                            line(9, y, 20)
                            context.fill(dot(4, y, 0.75), with: .color(color))
                        }
                    case .focus:
                        var corners = Path()
                        for x in [CGFloat(4), 20] {
                            for y in [CGFloat(5), 19] {
                                corners.move(to: pt(x, y + (y == 5 ? 4 : -4)))
                                corners.addLine(to: pt(x, y))
                                corners.addLine(to: pt(x + (x == 4 ? 4 : -4), y))
                            }
                        }
                        context.stroke(corners, with: .color(color), style: StrokeStyle(lineWidth: 1.5 * sx, lineCap: .round, lineJoin: .round))
                        context.fill(dot(12, 12, 1.5), with: .color(color))
                    case .settings:
                        line(4, 7, 20); line(4, 17, 20)
                        for point in [(CGFloat(9), CGFloat(7)), (15, 17)] {
                            let knob = dot(point.0, point.1, 3)
                            context.fill(knob, with: .color(palette.raised))
                            context.stroke(knob, with: .color(color), lineWidth: 1.5 * sx)
                        }
                    }
                }
                .id(glyph)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: glyph)
            .frame(width: 20, height: 20)
            .frame(width: size, height: size)
            .background(palette.raised, in: Circle())
        }
        .buttonStyle(ScheduleButtonStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(label)
    }

}

private enum DaymarkToolbarGlyph { case list, focus, settings }

private struct BoardControlFocusRing<Outline: InsettableShape>: ViewModifier {
    let shape: Outline
    let palette: DaymarkPalette
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.focused($focused)
            .daymarkFocusRing(focused, in: shape, palette: palette)
    }
}

private extension View {
    func daymarkFocusRing(in shape: some InsettableShape, palette: DaymarkPalette) -> some View {
        modifier(BoardControlFocusRing(shape: shape, palette: palette))
    }
}

struct DateTabPlacement: Identifiable {
    let date: Date
    let center: CGFloat
    let width: CGFloat
    var id: Date { date }

    func restingOpacity(desktopWidth: CGFloat) -> CGFloat {
        let halfStrip: CGFloat
        if desktopWidth > 640 {
            // The desktop web strip leaves at least 24 points per side and aligns to a 32-point grid from the centre.
            halfStrip = floor((desktopWidth / 2 - 24) / 32) * 32
        } else {
            halfStrip = desktopWidth / 2 - (desktopWidth <= 380 ? 8 : 16)
        }
        let distance = abs(center - width / 2)
        return max(0.15, 1 - 0.85 * distance / max(1, halfStrip))
    }
}

private struct FusedDateTab: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 16
        let x = rect.width, y = rect.height
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addQuadCurve(to: CGPoint(x: r, y: y - r), control: CGPoint(x: r, y: y))
        path.addLine(to: CGPoint(x: r, y: r))
        path.addQuadCurve(to: CGPoint(x: 2 * r, y: 0), control: CGPoint(x: r, y: 0))
        path.addLine(to: CGPoint(x: x - 2 * r, y: 0))
        path.addQuadCurve(to: CGPoint(x: x - r, y: r), control: CGPoint(x: x - r, y: 0))
        path.addLine(to: CGPoint(x: x - r, y: y - r))
        path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x - r, y: y))
        path.closeSubpath()
        return path
    }
}

private struct EqualTaskRow: Layout {
    let gap: CGFloat
    private func columnWidth(_ width: CGFloat) -> CGFloat { max(0, (width - gap * 2) / 3) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 480
        let column = columnWidth(width)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = columnWidth(bounds.width)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * (column + gap), y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: column, height: bounds.height)
            )
        }
    }
}

private struct InlineTaskTitle: View {
    let task: Task
    let palette: DaymarkPalette
    let allowsWrap: Bool
    @Binding var editingID: UUID?
    var focusedTask: FocusState<UUID?>.Binding
    let dragging: Bool
    let activate: () -> Void
    let dragChanged: (DragGesture.Value) -> Void
    let dragEnded: (DragGesture.Value) -> Void
    let keyHandler: (KeyPress) -> KeyPress.Result
    let commit: (String, Bool) -> Void
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        Group {
            if editingID == task.id {
                TextField("Task title", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...)
                    .focused($editorFocused)
                    .padding(.vertical, 12).frame(minHeight: 44)
                    .padding(.horizontal, 4)
                    .daymarkFocusRing(editorFocused, in: RoundedRectangle(cornerRadius: 8), palette: palette)
                    .padding(.horizontal, -4)
                    .onAppear {
                        draft = task.title
                        DispatchQueue.main.async { if editingID == task.id { editorFocused = true } }
                    }
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
                        if editor?.hasMarkedText() == true { return .ignored }
                        if press.modifiers.contains(.shift), let editor {
                            editor.insertText("\n", replacementRange: editor.selectedRange())
                            return .handled
                        }
                        finish(save: true); return .handled
                    }
                    .onKeyPress(.escape) { finish(save: false); return .handled }
                    .onChange(of: editorFocused) { _, focused in
                        if !focused && editingID == task.id { finish(save: true, restoreFocus: false, removeEmpty: true) }
                    }
                    .accessibilityLabel("Edit task title")
            } else {
                restingTitle
            }
        }
        .font(.system(size: 16))
        .frame(maxWidth: editingID == task.id ? .infinity : nil, alignment: .leading)
    }

    private var restingTitle: some View {
        TaskTitleLabel(task: task, palette: palette, allowsWrap: allowsWrap)
            .padding(.vertical, 12).frame(minHeight: 44, alignment: .leading)
            .background(focusedTask.wrappedValue == task.id && !dragging ? palette.taskCheckboxBorder : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("task-drag-surface"))
                .onChanged(dragChanged).onEnded(dragEnded), including: task.completedOn == nil ? .all : .none)
        .focusable().focusEffectDisabled().focused(focusedTask, equals: task.id)
        .onKeyPress(keys: [.space, .return, .leftArrow, .rightArrow, .upArrow, .downArrow, .escape], phases: .down, action: keyHandler)
        .onTapGesture(count: 2) { editingID = task.id }
        .onKeyPress(.init(Character(UnicodeScalar(0xF705)!))) { editingID = task.id; return .handled }
        .accessibilityLabel("Move \(task.title)")
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(dragging ? "Picked up" : "")
        .accessibilityHint(task.completedOn == nil
            ? "Double-click or press F2 to edit. Press Space to pick up, arrow keys to choose a stage, then Space to drop. Escape cancels."
            : "Double-click or press F2 to edit.")
        .help(task.title)
        .onContinuousHover(perform: showCursor)
        .accessibilityAction { activate() }
        .accessibilityAction(named: Text("Edit task")) { editingID = task.id }
    }

    private func showCursor(_ phase: HoverPhase) {
        guard task.completedOn == nil, NSEvent.pressedMouseButtons == 0 else { return }
        switch phase {
        case .active: NSCursor.openHand.set()
        case .ended: NSCursor.arrow.set()
        }
    }

    private func finish(save: Bool, restoreFocus: Bool = true, removeEmpty: Bool = false) {
        if save && (removeEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { commit(draft, removeEmpty) }
        editingID = nil
        if restoreFocus { DispatchQueue.main.async { focusedTask.wrappedValue = task.id } }
    }
}

private struct DaymarkSectionPositions: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct BoardScrollResolver: NSViewRepresentable {
    var resolved: ((NSScrollView) -> Void)?
    var scrolled: ((CGFloat) -> Void)?

    final class Locator: NSView {
        var resolve: ((NSScrollView) -> Void)?
        var onScroll: ((CGFloat) -> Void)?
        var listener: NSObjectProtocol?
        private var wheelMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor); self.wheelMonitor = nil }
            guard window != nil else { return }
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Trackpad gestures can begin or end with a phase change and no movement.
                let phaseOnly = event.scrollingDeltaX == 0 && event.scrollingDeltaY == 0
                    && (!event.phase.isEmpty || !event.momentumPhase.isEmpty)
                guard let self, let window = self.window, event.window === window,
                      event.modifierFlags.intersection([.control, .shift]).isEmpty,
                      phaseOnly || abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                      let scroll = self.enclosingScrollView, let content = window.contentView
                else { return event }
                // Pinned headings overlap the scroll view but live outside its responder chain.
                let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                if let hit = content.hitTest(point), hit === scroll || hit.isDescendant(of: scroll) {
                    return event
                }
                scroll.scrollWheel(with: event)
                return nil
            }
        }

        deinit {
            if let listener { NotificationCenter.default.removeObserver(listener) }
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.enclosingScrollView else { return }
                self.resolve?(scrollView)
                guard self.onScroll != nil else { return }
                let clip = scrollView.contentView
                if let listener { NotificationCenter.default.removeObserver(listener) }
                clip.postsBoundsChangedNotifications = true
                self.listener = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak clip] _ in
                    guard let clip else { return }
                    self?.onScroll?(clip.bounds.minY)
                }
                self.onScroll?(clip.bounds.minY)
            }
        }
    }
    func makeNSView(context: Context) -> Locator {
        let view = Locator()
        view.resolve = resolved
        view.onScroll = scrolled
        return view
    }
    func updateNSView(_ nsView: Locator, context: Context) {
        nsView.resolve = resolved
        nsView.onScroll = scrolled
    }
}

private final class WeakBoardScrollView { weak var value: NSScrollView? }
