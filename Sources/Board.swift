import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

struct Board: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.colorScheme) private var scheme
    @FocusState private var composerFocus: Bool
    @FocusState private var settingsFocus: Bool
    @State private var selected: Date?
    @State private var dateAnchor: CGFloat?
    @State private var hoveredDate: Date?
    @State private var hoveredHour: Int?
    @FocusState private var focusedDate: Date?
    @FocusState private var focusedLaneBlock: Int?
    @State private var pinned: Int?
    @State private var preview: Int?
    @State private var all = false
    @State private var settingsOpen: Bool
    @State private var settingsIdentity = UUID()
    @State private var draft = ""
    @State private var taskColour: Int?
    @State private var taskStage: Stage?
    @State private var composerMenu: ComposerMenu?
    @State private var keyboardMove: KeyboardTaskMove?
    @FocusState private var focusedTask: UUID?
    @State private var feedback: String?
    @State private var editingID: UUID?
    @State private var deleteTask: Task?
    @State private var dropTarget: Stage?
    @State private var headerPositions: [String: CGFloat] = [:]
    @State private var scrollOffset: CGFloat = 0
    @State private var savedScrollOffset: CGFloat = 0
    @State private var scrollHost = WeakBoardScrollView()
    private var needsSetup: Bool { store.workspace.tasks.isEmpty && !store.workspace.settings.onboardingComplete }
    var palette: DaymarkPalette { DaymarkPalette(dark: scheme == .dark) }

    init(store: WorkspaceStore) {
        self.store = store
        _settingsOpen = State(initialValue: store.workspace.tasks.isEmpty && !store.workspace.settings.onboardingComplete)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            content(at: tick.date)
        }
        .background(palette.page)
        .foregroundStyle(palette.text)
        .font(.system(size: 16))
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
        let activeColour = (dayBlocks.first { $0.start <= minute && $0.end > minute }
                            ?? dayBlocks.first { $0.start > minute })?.colour ?? 0
        let activeMoment = Schedule.current(store.blocks, at: now)?.block
        let focusKey = "\(Schedule.dateKey(today)):\(Schedule.dateKey(active)):\(activeMoment?.id ?? -1):\(activeColour)"
        let selectedColour = pinned.flatMap { colour in dayBlocks.contains { $0.colour == colour } ? colour : nil }
        let chosen = selectedColour ?? preview ?? activeColour
        let visible = store.visible(on: Schedule.dateKey(active), today: Schedule.dateKey(today), colour: all ? nil : chosen)
        return GeometryReader { geometry in
            let width = geometry.size.width
            let gutter = width <= 380 ? 8 : 24 + max(0, width / 2 - 24).truncatingRemainder(dividingBy: 32)
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    dateStrip(active, today: today, width: max(0, width - 2 * gutter))
                        .opacity(settingsOpen ? 0 : 1)
                        .disabled(settingsOpen)
                        .accessibilityHidden(settingsOpen)
                    Group {
                        if settingsOpen {
                            let setup = needsSetup
                            ScheduleEditor(store: store, palette: palette, setup: setup) { saved in
                                closeSettings(focusComposer: setup && saved)
                            }
                            .id(settingsIdentity)
                        } else {
                            dayViewport(
                                blocks: dayBlocks, visible: visible, now: now, active: active, today: today,
                                wide: width > 760, inset: width <= 640 ? 12 : 16,
                                fade: min(192, geometry.size.height * 0.24))
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .background(palette.raised, in: RoundedRectangle(cornerRadius: 24))
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .accessibilityElement(children: .contain)
                }
                .padding(.horizontal, gutter)
                composer(activeColour)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
            }
            .padding(.vertical, 24)
        }
        .onChange(of: focusKey) { _, _ in all = false; preview = nil; keyboardMove = nil }
        .onChange(of: focusedTask) { _, focused in
            if keyboardMove?.id != focused { keyboardMove = nil }
        }
        .onChange(of: editingID) { _, id in if id != nil { preview = nil } }
        .onExitCommand {
            if settingsOpen { closeSettings() }
            else if keyboardMove != nil { keyboardMove = nil }
            else if editingID == nil { pinned = nil; preview = nil; hoveredHour = nil }
        }
    }

    private var groupTitles: [String] { Stage.allCases.map(\.rawValue) + ["Done"] }

    private func dayViewport(blocks: [FocusBlock], visible: [Task], now: Date, active: Date, today: Date,
                             wide: Bool, inset: CGFloat, fade: CGFloat) -> some View {
        let groups = Stage.allCases.map { stage in visible.filter { $0.completedOn == nil && $0.stage == stage } }
            + [visible.filter { $0.completedOn != nil }]
        let progress = min(1, max(0, scrollOffset / 64))
        let timelineTop = max(0, inset - scrollOffset)
        let timelineHeight = 64 - progress * 40
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BoardScrollResolver { view in
                    scrollHost.value = view
                    if savedScrollOffset > 0 { setBoardOffset(savedScrollOffset) }
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
                            taskGroup(title, stage: stage, tasks: groups[index], now: now, wide: wide)
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
                    if (headerPositions[title] ?? .infinity) < top && scrollOffset >= 64 {
                        HStack(spacing: 8) {
                            Button(title) { jumpToGroup(title) }.buttonStyle(.plain)
                            Text(groups[index].count, format: .number).foregroundStyle(palette.muted).monospacedDigit()
                            Spacer()
                        }
                        .padding(.horizontal, inset).frame(height: 48)
                        .background(palette.raised)
                        .offset(y: top)
                        .accessibilityHidden(true)
                    }
                }
            }
            lane(all || needsSetup ? [] : blocks, referenceBlocks: blocks, now: now, active: active, today: today,
                 collapse: progress)
                .padding(.horizontal, inset)
                .frame(height: timelineHeight, alignment: .top)
                .clipped()
                .background(palette.raised)
                .offset(y: timelineTop)
        }
        .accessibilityLabel("Tasks")
    }

    private func jumpToGroup(_ title: String) {
        guard let position = headerPositions[title], let index = groupTitles.firstIndex(of: title) else { return }
        let target = max(0, scrollOffset + position - 24 - CGFloat(index) * 48)
        setBoardOffset(target)
    }

    private func setBoardOffset(_ y: CGFloat) {
        guard let scrollView = scrollHost.value, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let target = min(max(0, y), max(0, document.bounds.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    private func openSettings() {
        savedScrollOffset = scrollOffset
        settingsIdentity = UUID()
        settingsOpen = true
        preview = nil
    }

    private func closeSettings(focusComposer: Bool = false) {
        settingsOpen = false
        DispatchQueue.main.async {
            if focusComposer { composerFocus = true }
            else { settingsFocus = true }
        }
    }

    private func choose(_ day: Date, today: Date) {
        if selected != (day == today ? nil : day) { savedScrollOffset = 0; scrollOffset = 0 }
        selected = day == today ? nil : day
        pinned = nil
        preview = nil
        hoveredHour = nil
        feedback = nil
    }

    private func dateStrip(_ active: Date, today: Date, width: CGFloat) -> some View {
        let anchor = min(max(64, dateAnchor ?? width / 2), max(64, width - 64))
        let maxMinutes = max(1, (0..<7).map { day in store.blocks.filter { $0.day == day }.reduce(0) { $0 + $1.end - $1.start } }.max() ?? 1)
        let maxSegments = max(1, (0..<7).map { day in store.blocks.filter { $0.day == day }.count }.max() ?? 1)
        return ZStack(alignment: .topLeading) {
            ForEach(-12...12, id: \.self) { offset in
                let x = anchor + CGFloat(offset) * 104
                if x >= 48, x <= width - 48,
                   let date = Calendar.current.date(byAdding: .day, value: offset, to: active) {
                    let blocks = store.blocks.filter { $0.day == Schedule.day(date) }
                    let hot = offset == 0 || hoveredDate == date || focusedDate == date
                    let opacity = max(0.15, 1 - abs(x - width / 2) / max(1, width / 2) * 0.85)
                    Button {
                        guard offset != 0 else { return }
                        dateAnchor = x
                        choose(date, today: today)
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
                                        .frame(width: CGFloat(max(1, 64 - 2 * (maxSegments - 1))) * CGFloat(block.end - block.start) / CGFloat(maxMinutes), height: 4)
                                }
                            }.frame(height: 4)
                        }
                        .frame(width: 96, height: 86)
                        .foregroundStyle(hot ? palette.text : palette.muted)
                        .overlay(alignment: .top) {
                            if offset != 0 && date == today { Circle().fill(palette.text).frame(width: 3, height: 3).padding(.top, 4) }
                        }
                        .opacity(hot ? 1 : opacity)
                        .background(alignment: .bottom) {
                            if offset == 0 {
                                FusedDateTab().fill(palette.raised)
                                    .padding(.horizontal, -16).allowsHitTesting(false)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedDate, equals: date)
                    .onHover { inside in
                        if inside { hoveredDate = date }
                        else if hoveredDate == date { hoveredDate = nil }
                    }
                    .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                    .accessibilityHint("\(blocks.count) scheduled blocks")
                    .accessibilityAddTraits(offset == 0 ? .isSelected : [])
                    .id(date)
                    .position(x: x, y: 43)
                }
            }
        }
        .frame(width: width, height: 86)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar dates")
        .accessibilityScrollAction { edge in
            let step = edge == .leading ? -1 : edge == .trailing ? 1 : 0
            guard step != 0, let date = Calendar.current.date(byAdding: .day, value: step, to: active) else { return }
            dateAnchor = width / 2
            choose(date, today: today)
        }
        .onMoveCommand { direction in
            let step = direction == .left ? -1 : direction == .right ? 1 : 0
            guard step != 0, let date = Calendar.current.date(byAdding: .day, value: step, to: active) else { return }
            dateAnchor = width / 2
            choose(date, today: today)
            focusedDate = date
        }
        .onChange(of: width) { _, _ in dateAnchor = nil }
    }

    private func lane(_ blocks: [FocusBlock], referenceBlocks: [FocusBlock], now: Date, active: Date, today: Date, collapse: CGFloat = 0) -> some View {
        let second = Schedule.seconds(now)
        let minute = hoveredHour ?? (second / 60)
        let preciseMinute = hoveredHour.map(CGFloat.init) ?? CGFloat(second) / 60
        let thisDay = active == today
        let start = referenceBlocks.isEmpty ? 0 : min(referenceBlocks[0].start, thisDay ? second / 3600 * 60 : 1440)
        let end = referenceBlocks.isEmpty ? 1440 : max(referenceBlocks.last?.end ?? 1440, thisDay ? (second / 3600 + 1) * 60 : 0)
        let marks = all ? [] : blocks
        let blend = focusedLaneBlock != nil ? 0 : min(max(0, collapse), 1)
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
                        preview = nil
                        pinned = pinned == block.colour ? nil : block.colour
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
                            if pinned == block.colour && blend < 0.6 {
                                Capsule().strokeBorder(palette.blockText, lineWidth: 2).padding(4)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .focused($focusedLaneBlock, equals: block.id)
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
            .frame(width: width, height: 64)
            .contentShape(Rectangle())
            .onContinuousHover { event in
                switch event {
                case .active(let location):
                    guard width > 0, (0...64).contains(location.y) else { return }
                    let anchorMinute = CGFloat(start) + location.x / width * CGFloat(end - start)
                    hoveredHour = min(end, max(start, Int((anchorMinute / 60).rounded()) * 60))
                    if editingID == nil && NSEvent.pressedMouseButtons == 0 {
                        preview = marks.first { anchorMinute >= CGFloat($0.start) && anchorMinute < CGFloat($0.end) }?.colour
                    }
                case .ended:
                    hoveredHour = nil
                    preview = nil
                }
            }
        }.frame(height: 64).clipped()
    }


    private func taskGroup(_ title: String, stage: Stage?, tasks: [Task], now: Date, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            taskHeading(title, count: tasks.count, stage: stage)
            taskList(stage, tasks: tasks, now: now, wide: wide)
                .padding(.top, 12)
                .padding(.bottom, stage == nil ? 0 : 48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func taskList(_ stage: Stage?, tasks: [Task], now: Date, wide: Bool) -> some View {
        let list = Group {
            if stage == .now && wide {
                EqualTaskRow(gap: 16) {
                    ForEach(tasks) { task in taskRow(task, now: now, stretch: true, allowsWrap: true) }
                }
            } else {
                VStack(alignment: .leading, spacing: stage == .now ? 16 : 4) {
                    ForEach(tasks) { task in taskRow(task, now: now, stretch: false, allowsWrap: stage == .now) }
                }
            }
        }.frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
        if let stage {
            list
                .background {
                    if dropTarget == stage || keyboardMove?.destination == stage {
                        RoundedRectangle(cornerRadius: 24).fill(palette.muted.opacity(0.08))
                    }
                }
                .onDrop(of: [.daymarkTask], isTargeted: Binding(get: { dropTarget == stage }, set: {
                    if $0 { dropTarget = stage }
                    else if dropTarget == stage { dropTarget = nil }
                })) { providers in
                    guard let provider = providers.first else { return false }
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.daymarkTask.identifier) { data, _ in
                        guard let data, let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value) else { return }
                        DispatchQueue.main.async { move(id, to: stage) }
                    }
                    return true
                }
        } else { list }
    }

    private func taskHeading(_ title: String, count: Int, stage: Stage?) -> some View {
        HStack(spacing: 8) {
            Button(title) { jumpToGroup(title) }.buttonStyle(.plain)
                .accessibilityLabel("Scroll to \(title) tasks")
            Text(count, format: .number).foregroundStyle(palette.muted).monospacedDigit()
            Spacer()
            if let stage, keyboardMove?.destination == stage || dropTarget == stage {
                let blocked = stage == .now && !store.canEnterNow(excluding: keyboardMove?.id)
                Text(blocked ? "Now is full" : "Move to \(title)")
                    .font(.system(size: 12)).foregroundStyle(palette.muted)
            }
        }
        .frame(height: 48)
        .accessibilityAddTraits(.isHeader)
    }

    private func handleMoveKey(_ press: KeyPress, task: Task) -> KeyPress.Result {
        guard task.completedOn == nil else { return .ignored }
        switch press.key {
        case .space, .return:
            if let moveState = keyboardMove, moveState.id == task.id {
                keyboardMove = nil
                if moveState.destination != task.stage { move(task.id, to: moveState.destination) }
            } else {
                keyboardMove = KeyboardTaskMove(id: task.id, destination: task.stage)
            }
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
        return HStack(alignment: .top, spacing: 10) {
            Button {
                feedback = store.toggle(task.id, at: now) ? nil : "Now is full. Move or complete a task first."
            } label: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(palette.raised)
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.taskCheckboxBorder) }
                    .frame(width: 20, height: 20)
                    .overlay {
                        if task.completedOn != nil { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                    }
            }
            .accessibilityLabel(task.completedOn == nil ? "Complete \(task.title)" : "Reopen \(task.title)")
            .buttonStyle(.plain)
            .padding(.top, 12)
            InlineTaskTitle(task: task, palette: palette, allowsWrap: allowsWrap,
                            editingID: $editingID, focusedTask: $focusedTask,
                            keyHandler: { handleMoveKey($0, task: task) }) { title, removeEmpty in
                if removeEmpty && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { _ = store.delete(task.id) }
                else { _ = store.edit(task.id, title: title, colour: min(task.colour, store.workspace.settings.labels.count - 1)) }
            }
            .padding(.vertical, 12)
            .frame(minHeight: 44)
        }
        .padding(.leading, 12)
        .padding(.trailing, all ? 28 : 12)
        .padding(.vertical, allowsWrap ? 8 : 4)
        .frame(maxWidth: stretch ? .infinity : nil, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
        .background(allowsWrap ? palette.nowTask : palette.page, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            if keyboardMove?.id == task.id {
                RoundedRectangle(cornerRadius: 24).strokeBorder(palette.block(task.colour), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if all {
                Circle().fill(palette.block(task.colour)).frame(width: 6, height: 6)
                    .padding(14).allowsHitTesting(false)
                    .accessibilityLabel(store.label(task.colour))
            }
        }
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

    private func move(_ id: UUID, to stage: Stage) {
        let changed = store.move(id, stage)
        feedback = changed ? nil : "Now is full. Move or complete a task first."
        if changed { DispatchQueue.main.async { focusedTask = id } }
    }

    private func composer(_ activeColour: Int) -> some View {
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
        return HStack(spacing: 8) {
            Button {
                dateAnchor = nil
                choose(Calendar.current.startOfDay(for: .now), today: Calendar.current.startOfDay(for: .now))
                if settingsOpen { closeSettings() }
            } label: {
                DaymarkToolbarBrand().fill(palette.text)
                    .frame(width: 40, height: 40)
                    .frame(width: 44, height: 44)
                    .background(palette.raised, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Back to today")
            .accessibilityLabel("Back to today")
            HStack(spacing: 6) {
                Button {
                    composerMenu = .block
                } label: {
                    Circle().fill(palette.block(colour)).frame(width: 12, height: 12)
                        .frame(width: 32, height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(store.label(colour))
                .accessibilityLabel("Task block, \(store.label(colour))")
                .popover(isPresented: Binding(get: { composerMenu == .block }, set: { if !$0 { composerMenu = nil } })) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<count, id: \.self) { index in
                            Button {
                                taskColour = index; composerMenu = nil
                            } label: {
                                HStack {
                                    Circle().fill(palette.block(index)).frame(width: 8, height: 8)
                                    Text(store.label(index))
                                    Spacer()
                                    if index == colour { Image(systemName: "checkmark") }
                                }.padding(5).frame(minWidth: 125)
                            }.buttonStyle(.plain)
                        }
                    }.padding(8)
                }
                Button {
                    composerMenu = .stage
                } label: {
                    HStack(spacing: 6) {
                        Text(stage.rawValue)
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }.frame(width: 72, height: 40, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Task stage, \(stage.rawValue)")
                .popover(isPresented: Binding(get: { composerMenu == .stage }, set: { if !$0 { composerMenu = nil } })) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Stage.allCases) { option in
                            Button {
                                taskStage = option; composerMenu = nil
                            } label: {
                                HStack {
                                    Text(option.rawValue); Spacer()
                                    if option == stage { Image(systemName: "checkmark") }
                                }.padding(5).frame(minWidth: 80)
                            }.buttonStyle(.plain)
                            .disabled(option == .now && !store.canEnterNow())
                        }
                    }.padding(8)
                }
                TextField("New task", text: $draft,
                          prompt: Text(first ? "Add your first task…" : "Add a task…").foregroundStyle(palette.muted))
                    .textFieldStyle(.plain)
                    .focused($composerFocus)
                    .onSubmit(submit)
                    .onChange(of: draft) { _, text in
                        if text.count > 240 { draft = String(text.prefix(240)) }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 40, maxHeight: 40)
                    .accessibilityLabel("New task")
                Button(action: submit) {
                    Text("↑").font(.system(size: 14))
                        .frame(width: 36, height: 36).foregroundStyle(palette.page)
                        .background(palette.text, in: Circle())
                        .opacity(enabled ? 1 : 0.4)
                }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel("Add task")
            }
            .font(.system(size: 16))
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(palette.raised, in: Capsule())
            toolbarButton(.list, label: all ? "Return to focus" : "Show all tasks", selected: all) {
                if settingsOpen { closeSettings() }
                savedScrollOffset = 0
                all.toggle(); pinned = nil; preview = nil
            }
            toolbarButton(.settings, label: "Configure your schedule") {
                if settingsOpen { closeSettings() }
                else { openSettings() }
            }
            .focusable().focused($settingsFocus)
            .accessibilityLabel("Settings")
            .accessibilityValue(settingsOpen ? "Expanded" : "Collapsed")
        }.frame(maxWidth: 760).frame(maxWidth: .infinity)
    }

    private func toolbarButton(_ glyph: DaymarkToolbarGlyph, label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Canvas { context, size in
                let color = glyph == .settings || selected ? palette.text : palette.muted
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
                case .settings:
                    line(4, 7, 20); line(4, 17, 20)
                    for point in [(CGFloat(9), CGFloat(7)), (15, 17)] {
                        let knob = dot(point.0, point.1, 3)
                        context.fill(knob, with: .color(palette.raised))
                        context.stroke(knob, with: .color(color), lineWidth: 1.5 * sx)
                    }
                }
            }
            .frame(width: 20, height: 20)
            .frame(width: 44, height: 44)
            .background(selected ? palette.toolbarSelected : palette.raised, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(label)
    }

    private func icon(_ symbol: String, _ label: String, selected: Bool = false, smaller: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: smaller ? 11 : 16))
                .frame(width: smaller ? 24 : 44, height: smaller ? 30 : 44)
                .foregroundStyle(selected ? palette.text : palette.muted)
                .background(smaller ? .clear : selected ? palette.border : palette.raised, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}


private enum DaymarkToolbarGlyph { case list, settings }

private struct DaymarkToolbarBrand: View {
    var tint: Color = .primary
    func fill(_ color: Color) -> Self { Self(tint: color) }
    var body: some View {
        Canvas { original, size in
            let scale = size.height * 1.033 / 320
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func mapped(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: center.x + (x - 120) * scale, y: center.y + (y - 160) * scale)
            }
            func circle(_ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: center.x - radius * scale, y: center.y - radius * scale,
                                       width: 2 * radius * scale, height: 2 * radius * scale))
            }
            var clipped = original
            clipped.clip(to: circle(102))
            let parts: [[(CGFloat, CGFloat)]] = [
            [(113, 33), (127, 33), (127, 287), (113, 287)],
            [(247, 167), (247, 153), (132, 153), (132, 167), (240, 167)],
            [(0, 153), (-7, 153), (-7, 167), (108, 167), (108, 153)],
            [(243.13, 169.391), (249.391, 156.87), (132, 98.1738), (132, 113.826), (236.87, 166.261)],
            [(43.1305, 53.739), (36.8695, 50.6085), (30.6085, 63.1305), (83.3993, 89.5259), (87.8904, 76.119)],
            [(108, 101.826), (108, 97.9422), (106.886, 101.269)],
            [(203.13, 269.391), (209.391, 256.87), (156.601, 230.474), (152.11, 243.881), (196.87, 266.261)],
            [(132, 218.174), (132, 222.058), (133.114, 218.731)],
            [(3.13049, 153.739), (-3.13049, 150.609), (-9.39149, 163.13), (108, 221.826), (108, 206.174)],
            [(115.861, 55.5861), (102.586, 51.139), (70.1377, 148), (84.9023, 148), (113.637, 62.2235)],
            [(33.3625, 257.776), (31.139, 264.414), (44.4139, 268.861), (76.8623, 172), (62.0977, 172)],
            [(208.861, 55.5861), (195.586, 51.139), (163.138, 148), (177.902, 148), (206.637, 62.2235)],
            [(126.363, 257.776), (124.139, 264.414), (137.414, 268.861), (169.862, 172), (155.098, 172)],
            ]
            for part in parts {
                guard let first = part.first else { continue }
                var path = Path()
                path.move(to: mapped(first.0, first.1))
                for p in part.dropFirst() { path.addLine(to: mapped(p.0, p.1)) }
                path.closeSubpath()
                clipped.fill(path, with: .color(tint))
            }
            original.stroke(circle(108), with: .color(tint), lineWidth: 16 * scale)
        }
        .accessibilityHidden(true)
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
                    .onAppear { draft = task.title; editorFocused = true }
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        finish(save: true); return .handled
                    }
                    .onKeyPress(.escape) { finish(save: false); return .handled }
                    .onChange(of: editorFocused) { _, focused in
                        if !focused && editingID == task.id { finish(save: true, restoreFocus: false, removeEmpty: true) }
                    }
                    .accessibilityLabel("Edit task title")
            } else {
                let split = task.completedOn == nil ? task.title.firstIndex(of: ".") : nil
                let title = split.map { String(task.title.prefix(through: $0)) } ?? task.title
                let description = split.map { String(task.title.suffix(from: task.title.index(after: $0))) } ?? ""
                let label = (Text(title).foregroundColor(task.completedOn == nil ? palette.text : palette.muted)
                    + Text(description).foregroundColor(palette.muted))
                    .lineLimit(allowsWrap ? nil : 1).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: allowsWrap)
                Group {
                    if task.completedOn == nil {
                        label.onDrag {
                            let provider = NSItemProvider()
                            provider.registerDataRepresentation(forTypeIdentifier: UTType.daymarkTask.identifier, visibility: .ownProcess) { completion in
                                completion(Data(task.id.uuidString.utf8), nil)
                                return nil
                            }
                            return provider
                        }
                    } else { label.strikethrough() }
                }
                .focusable().focused(focusedTask, equals: task.id)
                .onKeyPress(keys: [.space, .return, .leftArrow, .rightArrow, .upArrow, .downArrow, .escape], phases: .down, action: keyHandler)
                .onTapGesture(count: 2) { editingID = task.id }
                .onKeyPress(.init(Character(UnicodeScalar(0xF705)!))) { editingID = task.id; return .handled }
                .accessibilityLabel(task.title)
                .accessibilityAction(named: Text("Edit task")) { editingID = task.id }
            }
        }
        .font(.system(size: 16))
        .frame(maxWidth: editingID == task.id ? .infinity : nil, alignment: .leading)
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

private struct BoardScrollResolver: NSViewRepresentable {
    let resolved: (NSScrollView) -> Void
    let scrolled: (CGFloat) -> Void

    final class Locator: NSView {
        var resolve: ((NSScrollView) -> Void)?
        var onScroll: ((CGFloat) -> Void)?
        weak var clip: NSClipView?
        var listener: NSObjectProtocol?
        deinit { if let listener { NotificationCenter.default.removeObserver(listener) } }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.enclosingScrollView else { return }
                let clip = scrollView.contentView
                if let listener { NotificationCenter.default.removeObserver(listener) }
                self.clip = clip
                clip.postsBoundsChangedNotifications = true
                self.listener = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak clip] _ in
                    guard let clip else { return }
                    self?.onScroll?(clip.bounds.minY)
                }
                self.resolve?(scrollView)
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
private enum ComposerMenu { case block, stage }

private extension UTType {
    static let daymarkTask = UTType(exportedAs: "com.nicovanzyl.daymark.task")
}
