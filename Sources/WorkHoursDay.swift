import SwiftUI
import AppKit

struct RangeDraft: Identifiable, Equatable {
    var id = UUID()
    var start: Int
    var end: Int
    var allowed: Set<Int> = []

    var minimumResizeDuration: Int { min(15, end - start) }
}

struct WorkHoursRuler: View {
    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 36)
            HStack(spacing: 0) {
                ForEach(0...6, id: \.self) { tick in
                    if tick > 0 { Spacer(minLength: 0) }
                    Text(String(format: "%02d", tick * 4))
                }
            }
            .padding(.horizontal, 2)
        }
        .font(.system(size: 16)).monospacedDigit()
        .frame(height: 26).accessibilityHidden(true)
    }
}

private struct WorkHoursNudgeKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

private extension EnvironmentValues {
    var workHoursNudgeDay: Int? {
        get { self[WorkHoursNudgeKey.self] }
        set { self[WorkHoursNudgeKey.self] = newValue }
    }
}

struct WorkHoursNudges: ViewModifier {
    let enabled: Bool
    let days: [Int]
    @State private var chosen: Int?
    @State private var active = false

    func body(content: Content) -> some View {
        content
            .environment(\.workHoursNudgeDay, enabled && active ? chosen : nil)
            .onAppear { active = NSApp.isActive && NSApp.keyWindow?.isVisible == true }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                active = NSApp.isActive
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                active = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                active = NSApp.keyWindow?.isVisible == true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                active = false
            }
            .task(id: enabled && active && !days.isEmpty) {
                chosen = nil
                guard enabled, active, !days.isEmpty else { return }
                var previous: Int?
                do {
                    while !_Concurrency.Task.isCancelled {
                        chosen = (days.count == 1 ? days : days.filter { $0 != previous }).randomElement()
                        previous = chosen
                        try await _Concurrency.Task.sleep(for: .milliseconds(1500))
                        chosen = nil
                        try await _Concurrency.Task.sleep(for: .seconds(Int.random(in: 4...9)))
                    }
                } catch {}
            }
    }
}

struct WorkHoursDay: View {
    private static let defaultDuration = 30
    let day: Int
    @Binding var ranges: [RangeDraft]
    let labels: [String]
    let palette: DaymarkPalette
    let setup: Bool
    var focusTrackRequest = 0
    @Environment(\.workHoursNudgeDay) private var hintedDay
    private var nudge: Bool { day == hintedDay }
    var onNudgeEnd: () -> Void = {}

    private enum Operation: Equatable {
        case draw, move, start, end
    }

    private struct Drag {
        let operation: Operation
        let original: RangeDraft
        let lower: Int
        let upper: Int
        let anchor: Int
        var moved = false
        var preview: RangeDraft
        var drawsSlot: Bool {
            operation == .draw && (moved || upper - lower >= WorkHoursDay.defaultDuration)
        }
        var removesSlot: Bool {
            (operation == .start || operation == .end)
                && preview.end - preview.start <= 15 && original.end - original.start > 15
        }
    }

    private enum Focus: Hashable {
        case track, slot(UUID), endpoint(UUID, Bool), rangeCategory(UUID, Int)
    }

    @FocusState private var focus: Focus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var pressed = false
    @State private var drag: Drag?
    @State private var cancelled = false
    @State private var hoverX: CGFloat?
    @State private var pulseSide: Edge = .leading
    @State private var pulse: CGFloat = 0
    @State private var handleOpacity = 0.0
    private var feedback: Animation? {
        reduceMotion ? nil : .timingCurve(0.25, 1, 0.5, 1, duration: 0.14)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(Schedule.weekdays[day].prefix(3).uppercased())
                .font(.system(size: 16))
                .lineLimit(1).minimumScaleFactor(0.9)
                .frame(width: 36, alignment: .leading)
                .accessibilityLabel(Schedule.weekdays[day])
            GeometryReader { geo in
                lane(width: max(1, geo.size.width - 4))
                    .padding(.horizontal, 2)
            }
            .frame(height: 36)
        }
        .frame(height: 48)
        .zIndex(hoverX != nil || drag != nil || focus != nil ? 1 : 0)
        .onChange(of: pressed) { _, down in
            if !down { drag = nil; cancelled = false }
        }
        .onChange(of: focusTrackRequest) { _, _ in focus = .track }
        .onChange(of: focus) { _, target in
            if target != nil { onNudgeEnd() }
        }
        .task(id: nudge) {
            guard nudge else { pulse = 0; handleOpacity = 0; return }
            do {
                try await _Concurrency.Task.sleep(for: .milliseconds(500))
                for side in [Edge.leading, .trailing] {
                    pulseSide = side
                    for (value, opacity, ms) in [(1.0, 0.65, 100), (0.0, 0.2, 125), (0.5, 0.5, 100), (0.0, 0.0, 175)] {
                        withAnimation(.timingCurve(0.25, 1, 0.5, 1, duration: Double(ms) / 1000)) {
                            pulse = value
                            handleOpacity = opacity
                        }
                        try await _Concurrency.Task.sleep(for: .milliseconds(ms))
                    }
                }
            } catch { pulse = 0; handleOpacity = 0 }
        }
    }

    private func lane(width: CGFloat) -> some View {
        let creation = hoverX.flatMap { x -> Int? in
            guard drag == nil, let gap = gap(at: x, width: width) else { return nil }
            return Self.defaultStart(in: gap, near: snapped(x, width))
        }
        return ZStack(alignment: .leading) {
            Button(action: addByKeyboard) {
                Capsule().fill(palette.page).padding(.horizontal, -2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($focus, equals: .track)
            .daymarkFocusRing(focus == .track, in: Capsule(), palette: palette)
            .onKeyPress(keys: [.space, .return]) { _ in addByKeyboard(); return .handled }
            .accessibilityLabel("Add hours on \(Schedule.weekdays[day])")
            .overlay {
                Color.clear.contentShape(Rectangle())
                    .gesture(gesture(for: nil, width: width))
                    .accessibilityHidden(true)
            }
            ForEach(Array(ranges.enumerated()), id: \.element.id) { index, range in
                let visible = drag?.original.id == range.id ? (drag?.preview ?? range) : range
                slot(visible, original: range, number: index + 1, width: width)
            }
            if let drag, drag.drawsSlot {
                Capsule().fill(palette.text.opacity(0.09))
                    .frame(width: pixels(drag.preview.end - drag.preview.start, width), height: 32)
                    .offset(x: pixels(drag.preview.start, width))
                    .allowsHitTesting(false)
            }
            if creation != nil, let hoverX {
                Image(systemName: "plus").font(.system(size: 16))
                    .foregroundStyle(palette.muted)
                    .frame(width: 32, height: 32)
                    .background(palette.raised, in: Circle())
                    .offset(x: min(max(0, hoverX - 16), max(0, width - 32)))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .frame(width: width, height: 36)
        .coordinateSpace(name: day)
        .onContinuousHover { phase in
            switch phase {
            case let .active(point): hoverX = point.x
            case .ended: hoverX = nil
            }
        }
        .overlay(alignment: .topLeading) {
            hint(width: width, creation: creation)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .background(LaneCursors(ranges: ranges, width: width, count: setup ? 0 : labels.count,
                                moving: drag?.operation == .move))
        .onKeyPress(.escape) {
            guard drag != nil else { return .ignored }
            drag = nil; cancelled = true; return .handled
        }
    }

    private func slot(_ visible: RangeDraft, original: RangeDraft, number: Int, width: CGFloat) -> some View {
        let length = max(1, pixels(visible.end - visible.start, width))
        let showHandles = hoverX != nil || drag != nil || focus == .slot(original.id)
        let cue = nudge && number == 1
        let n = cue ? pulse : 0
        return ZStack {
            Capsule().fill(palette.text.opacity(0.12))
                .scaleEffect(x: 1 + (reduceMotion ? 0 : 4 * n / length), y: 1,
                             anchor: pulseSide == .leading ? .trailing : .leading)
            if length >= 12 {
                HStack(spacing: 0) {
                    grip(active: showHandles, pulse: n, cue: cue && pulseSide == .leading, sign: -1)
                    Spacer(minLength: 0)
                    grip(active: showHandles, pulse: n, cue: cue && pulseSide == .trailing, sign: 1)
                }.padding(.horizontal, 5)
            }
            Rectangle().fill(.clear).contentShape(Rectangle())
                .gesture(gesture(for: original, width: width))
                .focusable().focused($focus, equals: .slot(original.id))
                .daymarkFocusRing(focus == .slot(original.id), in: Capsule(), palette: palette)
                .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
                    onNudgeEnd()
                    let delta = (press.key == .leftArrow ? -1 : 1) * (press.modifiers.contains(.shift) ? 60 : 15)
                    moveWithKeyboard(original, delta)
                    return .handled
                }
                .onKeyPress(keys: [.space, .return]) { _ in
                    focus = .endpoint(original.id, true)
                    return .handled
                }
                .accessibilityRepresentation {
                    let lower = min(original.start, shifted(original, by: -1440).start)
                    let upper = max(original.start, shifted(original, by: 1440).start)
                    timeSlider("Move \(Schedule.weekdays[day]) range \(number)",
                               minute: original.start, bounds: lower...upper, description: rangeLabel(visible)) {
                        moveWithKeyboard(original, $0)
                    }
                    .accessibilityAction { focus = .endpoint(original.id, true) }
                    .accessibilityAction(.delete) { remove(original.id) }
                }
            if !setup, !labels.isEmpty {
                let cell = max(0, min(16, (length - (length <= 38 ? 6 : 16)) / CGFloat(labels.count)))
                HStack(spacing: 0) {
                    ForEach(labels.indices, id: \.self) { i in
                        choice(i, range: original, cell: cell, width: width)
                    }
                }.allowsHitTesting(length > 38)
                .accessibilityHidden(length <= 38)
            }
        }
        .frame(width: length, height: 32)
        .overlay(alignment: .leading) {
            endpoint(original, number: number, start: true, width: width, hitWidth: min(8, length / 3))
        }
        .overlay(alignment: .trailing) {
            endpoint(original, number: number, start: false, width: width, hitWidth: min(8, length / 3))
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in remove(original.id); return .handled }
        .contextMenu {
            if !setup, !labels.isEmpty {
                Section("Focus blocks") {
                    ForEach(labels.indices, id: \.self) { index in
                        let included = original.allowed.isEmpty || original.allowed.contains(index)
                        Toggle(labels[index], isOn: Binding(get: { included }, set: { checked in
                            if checked != included { toggleCategory(index, in: original.id) }
                        }))
                        .disabled(labels.count == 1 || original.allowed == [index])
                    }
                }
            }
            Button("Remove range", role: .destructive) { remove(original.id) }
        }
        .offset(x: pixels(visible.start, width))
    }

    private func endpoint(_ range: RangeDraft, number: Int, start: Bool, width: CGFloat, hitWidth: CGFloat) -> some View {
        let key = Focus.endpoint(range.id, start)
        let edit = { (delta: Int) in adjustEndpoint(range, start: start, by: delta) }
        let minute = start ? range.start : range.end
        let available = availableBounds(around: range)
        let bounds = start ? available.lowerBound...(range.end - range.minimumResizeDuration)
            : (range.start + range.minimumResizeDuration)...available.upperBound
        return Rectangle().fill(.clear)
            .frame(width: hitWidth, height: 44)
            .contentShape(Rectangle())
            .gesture(gesture(for: range, width: width, endpoint: start ? .start : .end))
            .focusable().focusEffectDisabled().focused($focus, equals: key)
            .overlay {
                if focus == key {
                    Capsule().fill(palette.text).frame(width: 2, height: 10)
                }
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
                edit((press.key == .leftArrow || press.key == .downArrow ? -1 : 1)
                    * (press.modifiers.contains(.shift) ? 60 : 15))
                return .handled
            }
            .accessibilityRepresentation {
                timeSlider("\(Schedule.weekdays[day]) \(start ? "start" : "end") \(number)",
                           minute: minute, bounds: bounds, description: Schedule.clock(minute), adjust: edit)
            }
    }

    private func timeSlider(_ label: String, minute: Int, bounds: ClosedRange<Int>, description: String,
                            adjust: @escaping (Int) -> Void) -> some View {
        let value = Binding<Double>(get: { Double(minute) }, set: {
            let steps = Int((($0 - Double(minute)) / 15).rounded())
            let target = min(bounds.upperBound, max(bounds.lowerBound, minute + steps * 15))
            adjust(target - minute)
        })
        return Slider(value: value, in: Double(bounds.lowerBound)...Double(bounds.upperBound)) { Text(label) }
            .labelsHidden()
            .accessibilityValue(description)
            .accessibilityAdjustableAction { direction in adjust(direction == .increment ? 15 : -15) }
    }

    private func availableBounds(around range: RangeDraft) -> ClosedRange<Int> {
        let before = ranges.last { $0.id != range.id && $0.end <= range.start }
        let after = ranges.first { $0.id != range.id && $0.start >= range.end }
        return (before?.end ?? 0)...(after?.start ?? 1440)
    }

    private func adjustEndpoint(_ range: RangeDraft, start: Bool, by delta: Int) {
        guard let index = ranges.firstIndex(where: { $0.id == range.id }) else { return }
        hoverX = nil
        onNudgeEnd()
        let available = availableBounds(around: range)
        var changed = range
        if start { changed.start = min(range.end - range.minimumResizeDuration, max(available.lowerBound, range.start + delta)) }
        else { changed.end = max(range.start + range.minimumResizeDuration, min(available.upperBound, range.end + delta)) }
        if changed.end - changed.start == 15 && range.end - range.start > 15 {
            remove(range.id)
        } else {
            ranges[index] = changed
        }
    }

    private func grip(active: Bool, pulse: CGFloat, cue: Bool, sign: CGFloat) -> some View {
        Capsule().fill(palette.text).frame(width: 2, height: 8)
            .opacity(cue ? handleOpacity : active ? 0.6 : 0)
            .offset(x: reduceMotion || !cue ? 0 : 4 * sign * pulse)
            .allowsHitTesting(false)
    }

    private func choice(_ index: Int, range: RangeDraft, cell: CGFloat, width: CGFloat) -> some View {
        let included = range.allowed.isEmpty || range.allowed.contains(index)
        let size = min(8, cell / 2)
        let key = Focus.rangeCategory(range.id, index)
        return Circle().fill(palette.block(index)).frame(width: size, height: size)
            .scaleEffect(included ? 1 : 0.5).opacity(included ? 1 : 0.35)
            .animation(feedback, value: included)
            .frame(width: cell, height: 32).contentShape(Rectangle())
            .gesture(gesture(for: range, width: width, category: index))
            .focusable().focused($focus, equals: key)
            .daymarkFocusRing(focus == key, in: Capsule(), palette: palette)
            .onKeyPress(keys: [.space, .return]) { _ in
                toggleCategory(index, in: range.id)
                return .handled
            }
            .accessibilityLabel(labels[index])
            .accessibilityAddTraits(included ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { toggleCategory(index, in: range.id) }
            .help(labels[index])
    }

    private func toggleCategory(_ category: Int, in id: UUID) {
        guard let index = ranges.firstIndex(where: { $0.id == id }) else { return }
        var choices = ranges[index].allowed
        if choices.isEmpty { choices = Set(labels.indices) }
        if choices.contains(category) {
            guard choices.count > 1 else { return }
            choices.remove(category)
        } else {
            choices.insert(category)
        }
        ranges[index].allowed = choices.count == labels.count ? [] : choices
    }

    private func remove(_ id: UUID) {
        ranges.removeAll { $0.id == id }
        focus = .track
        onNudgeEnd()
    }

    private func gesture(for range: RangeDraft?, width: CGFloat, endpoint: Operation? = nil,
                         category: Int? = nil) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(day))
            .updating($pressed) { _, state, _ in state = true }
            .onChanged { value in
                guard !cancelled else { return }
                if drag == nil {
                    onNudgeEnd()
                    drag = begin(range, x: value.startLocation.x, width: width, endpoint: endpoint)
                    if let range {
                        focus = endpoint.map { .endpoint(range.id, $0 == .start) } ?? .slot(range.id)
                    } else {
                        focus = .track
                    }
                }
                if let current = drag { drag = updated(current, value: value, width: width) }
            }
            .onEnded { value in
                guard !cancelled, let current = drag else { return }
                let result = updated(current, value: value, width: width)
                drag = nil
                if result.operation == .draw {
                    if result.drawsSlot { insert(result.preview) }
                } else if result.moved {
                    if result.removesSlot {
                        remove(result.original.id)
                    } else if let i = ranges.firstIndex(where: { $0.id == result.original.id }) {
                        ranges[i] = result.preview
                    }
                } else if let category, result.operation == .move {
                    toggleCategory(category, in: result.original.id)
                }
            }
    }

    private func begin(_ range: RangeDraft?, x: CGFloat, width: CGFloat, endpoint: Operation?) -> Drag? {
        let minute = snapped(x, width)
        if let range {
            let left = pixels(range.start, width), right = pixels(range.end, width)
            let handle = min(8, (right - left) / 3)
            let operation: Operation = endpoint ?? (x < left + handle ? .start : (x > right - handle ? .end : .move))
            let available = availableBounds(around: range)
            return Drag(operation: operation, original: range, lower: available.lowerBound,
                        upper: available.upperBound, anchor: minute, preview: range)
        }
        guard let gap = gap(at: x, width: width) else { return nil }
        let anchor = min(gap.upperBound, max(gap.lowerBound, minute))
        let start = Self.defaultStart(in: gap, near: anchor) ?? gap.lowerBound
        let created = RangeDraft(start: start, end: min(gap.upperBound, start + Self.defaultDuration))
        return Drag(operation: .draw, original: created, lower: gap.lowerBound, upper: gap.upperBound,
                    anchor: anchor, preview: created)
    }

    private func updated(_ drag: Drag, value: DragGesture.Value, width: CGFloat) -> Drag {
        var next = drag
        let delta = value.translation.width
        let threshold: CGFloat = drag.operation == .move ? 4 : 2
        guard drag.moved || abs(delta) > threshold else { return next }
        next.moved = true
        let minute = min(drag.upper, max(drag.lower, snapped(value.location.x, width)))
        let offset = Int((delta / width * 96).rounded()) * 15
        switch drag.operation {
        case .draw:
            next.preview.start = min(drag.upper - 15, min(drag.anchor, minute))
            next.preview.end = max(next.preview.start + 15, max(drag.anchor, minute))
        case .move:
            next.preview = shifted(drag.original, by: offset)
        case .start:
            next.preview.start = min(drag.original.end - drag.original.minimumResizeDuration,
                                     max(drag.lower, drag.original.start + offset))
        case .end:
            next.preview.end = max(drag.original.start + drag.original.minimumResizeDuration,
                                   min(drag.upper, drag.original.end + offset))
        }
        return next
    }

    private func shifted(_ range: RangeDraft, by offset: Int) -> RangeDraft {
        let minStart = ranges.last { $0.id != range.id && $0.end <= range.start }.map { $0.end + 15 } ?? 0
        let maxEnd = ranges.first { $0.id != range.id && $0.start >= range.end }.map { $0.start - 15 } ?? 1440
        let length = range.end - range.start
        guard maxEnd - length >= minStart else { return range }
        var moved = range
        moved.start = max(minStart, min(range.start + offset, maxEnd - length))
        moved.end = moved.start + length
        return moved
    }

    private func moveWithKeyboard(_ range: RangeDraft, _ delta: Int) {
        guard let i = ranges.firstIndex(where: { $0.id == range.id }) else { return }
        hoverX = nil
        ranges[i] = shifted(range, by: delta)
    }

    private var freeGaps: [Range<Int>] {
        zip([0] + ranges.map(\.end), ranges.map(\.start) + [1440]).compactMap { lower, upper in
            upper - lower >= 15 ? lower..<upper : nil
        }
    }

    private func gap(at x: CGFloat, width: CGFloat) -> Range<Int>? {
        let minute = min(1439, max(0, Int(x / width * 1440)))
        return freeGaps.first { $0.contains(minute) }
    }

    static func defaultStart(in gap: Range<Int>, near minute: Int) -> Int? {
        guard gap.count >= defaultDuration else { return nil }
        return min(max(minute, gap.lowerBound), gap.upperBound - defaultDuration)
    }

    private func insert(_ range: RangeDraft) {
        ranges = (ranges + [range]).sorted { $0.start < $1.start }
        focus = .slot(range.id)
    }

    private func addByKeyboard() {
        let gaps = freeGaps
        let preferred = 9 * 60
        let gap = gaps.first { $0.contains(preferred) && Self.defaultStart(in: $0, near: preferred) != nil }
            ?? gaps.first { $0.count >= Self.defaultDuration }
        guard let gap, let start = Self.defaultStart(in: gap, near: gap.contains(preferred) ? preferred : gap.lowerBound) else { return }
        onNudgeEnd()
        hoverX = nil
        insert(RangeDraft(start: start, end: start + Self.defaultDuration))
    }

    private func snapped(_ x: CGFloat, _ width: CGFloat) -> Int {
        Int((min(width, max(0, x)) / width * 96).rounded()) * 15
    }

    private func pixels(_ minute: Int, _ width: CGFloat) -> CGFloat { CGFloat(minute) / 1440 * width }

    private func rangeAt(_ x: CGFloat, _ width: CGFloat) -> RangeDraft? {
        ranges.first { pixels($0.start, width) <= x && x <= pixels($0.end, width) }
    }

    private func rangeLabel(_ range: RangeDraft) -> String {
        "\(Schedule.clock(range.start))–\(Schedule.clock(range.end))"
    }

    @ViewBuilder private func hint(width: CGFloat, creation: Int?) -> some View {
        let underPointer = hoverX.flatMap { rangeAt($0, width) }
        let focused: RangeDraft? = switch focus {
        case let .slot(id), let .endpoint(id, _), let .rangeCategory(id, _): ranges.first { $0.id == id }
        default: nil
        }
        let preview = drag.flatMap { $0.operation == .draw && !$0.drawsSlot ? nil : $0.preview }
        let range = preview ?? underPointer ?? (hoverX == nil ? focused : nil)
        let text = drag?.removesSlot == true ? "Remove slot" : (range.map(rangeLabel) ?? creation.map(Schedule.clock))
        let start = range.map { pixels($0.start, width) } ?? (hoverX ?? 0)
        let length = range.map { pixels($0.end - $0.start, width) } ?? 0
        Group {
            if let text {
                if let range, length >= 132, drag?.removesSlot != true {
                    HStack(spacing: 0) {
                        hintLabel(Schedule.clock(range.start))
                        Spacer(minLength: 0)
                        hintLabel(Schedule.clock(range.end))
                    }.frame(width: length).offset(x: start)
                } else {
                    let bubble: CGFloat = range != nil ? 102 : 58
                    hintLabel(text).frame(width: bubble)
                        .offset(x: min(max(0, start + length / 2 - bubble / 2), max(0, width - bubble)))
                }
            }
        }
        .offset(y: -25)
        .transition(reduceMotion ? .opacity : .offset(y: 4).combined(with: .opacity))
        .animation(feedback, value: text == nil)
    }

    private func hintLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 8).frame(height: 23).foregroundStyle(palette.page)
            .background(palette.text, in: Capsule())
    }
}

private struct LaneCursors: NSViewRepresentable {
    let ranges: [RangeDraft]
    let width: CGFloat
    let count: Int
    let moving: Bool
    class CursorView: NSView {
        var regions: [(CGRect, NSCursor)] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() {
            for (rect, cursor) in regions { addCursorRect(rect, cursor: cursor) }
        }
    }
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) {
        var regions: [(CGRect, NSCursor)] = [(CGRect(x: 0, y: 0, width: width, height: 36), .crosshair)]
        for range in ranges {
            let x = width * CGFloat(range.start) / 1440
            let length = width * CGFloat(range.end - range.start) / 1440
            let handle = min(8, length / 3)
            regions.append((CGRect(x: x, y: 2, width: length, height: 32), .openHand))
            for edge in [x, x + length - handle] {
                regions.append((CGRect(x: edge, y: 2, width: handle, height: 32), .resizeLeftRight))
            }
            if length > 38, count > 0 {
                let cells = min(CGFloat(count * 16), length - 16)
                regions.append((CGRect(x: x + (length - cells) / 2, y: 2, width: cells, height: 32), .pointingHand))
            }
        }
        if moving { regions = [(CGRect(x: 0, y: 0, width: width, height: 36), .closedHand)] }
        view.regions = regions
        view.window?.invalidateCursorRects(for: view)
    }
}
