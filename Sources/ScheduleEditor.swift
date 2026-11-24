import SwiftUI

struct ScheduleEditor: View {
    @ObservedObject var store: WorkspaceStore
    let palette: DaymarkPalette
    let setup: Bool
    let exiting: Bool
    let bottomInset: CGFloat
    let onExitDurationChange: (Int) -> Void
    let close: (Bool) -> Void
    @State private var step = 1
    @State private var nextStep: Int?
    @AccessibilityFocusState private var headingFocused: Bool
    private static let backTab = KeyEquivalent(Character("\u{19}"))
    private enum Focus: Hashable { case panel, heading, label(UUID), back, submit }
    @FocusState private var focus: Focus?
    @State private var firstTrackFocusRequest = 0
    @State private var appendedLabel: UUID?
    @State private var frames: [Int: CGRect] = [:]
    @State private var pageMotion = SchedulePageMotion(phase: .preparing)
    @State private var viewport: CGSize = .zero
    @State private var work: [[RangeDraft]]
    @State private var blocks: [FocusDraft]
    @State private var nudgeHours = true
    @State private var error: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: WorkspaceStore, palette: DaymarkPalette, setup: Bool, exiting: Bool,
         bottomInset: CGFloat, onExitDurationChange: @escaping (Int) -> Void,
         close: @escaping (Bool) -> Void) {
        self.store = store; self.palette = palette; self.setup = setup; self.close = close; self.exiting = exiting
        self.onExitDurationChange = onExitDurationChange
        self.bottomInset = bottomInset
        let settings = store.workspace.settings
        _work = State(initialValue: settings.work.map { day in
            day.sorted { $0.start < $1.start }.map {
                RangeDraft(start: $0.start, end: $0.end, allowed: Set($0.allowed ?? []))
            }
        })
        let weights = Schedule.focusShares(settings.labels.count, settings.shares)
        var drafts = settings.labels.enumerated().compactMap { index, label -> FocusDraft? in
            if setup && label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return FocusDraft(label: label, weight: weights[index], original: index)
        }
        if setup && drafts.count < 6 { drafts.append(FocusDraft(label: "", weight: 1, original: nil)) }
        _blocks = State(initialValue: drafts)
    }

    private var named: [FocusDraft] { blocks.filter { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    private var weeksHours: Double {
        Double(work.flatMap { $0 }.reduce(0) { $0 + $1.end - $1.start }) / 60
    }

    private var title: String { step == 1 ? "Select the hours you normally work" : "What do you want to make time for?" }
    private var leaving: Bool { exiting || nextStep != nil }
    private var visibleItems: [Int] {
        let bounds = CGRect(origin: .zero, size: viewport)
        return frames.filter { !$0.value.intersection(bounds).isEmpty }.map(\.key).sorted()
    }

    var body: some View {
        BoardPanel(palette: palette) {
            editorContent
                .background(alignment: .bottom) {
                    LinearGradient(colors: [palette.raised, palette.page], startPoint: .top, endPoint: .bottom)
                        .frame(height: bottomInset)
                        .allowsHitTesting(false)
                }
        } controls: {
            actions
                .disabled(leaving)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Schedule actions")
        }
        .onExitCommand { close(false) }
    }

    private var editorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BoardScrollResolver().frame(height: 0).accessibilityHidden(true)
                if setup { header }
                VStack(alignment: .leading, spacing: 8) {
                    if setup && step == 2 {
                        onboardingLabels.padding(.vertical, 8).padding(.bottom, 16)
                    } else {
                        if !setup {
                            FocusAllocation(blocks: Binding(get: { blocks }, set: updateBlocks),
                                            work: modelWork, palette: palette, removeBlock: removeBlock)
                                .padding(.bottom, 8)
                                .modifier(ScheduleItemMotion(order: 0))
                        }
                        tracks
                    }
                }
                .padding(.top, setup ? 8 : 0)
                .padding(.bottom, 8)
                if let error = store.error ?? error { Text(error).font(.caption).foregroundStyle(palette.muted) }
            }
            .padding([.horizontal, .top], 12)
            .padding(.bottom, bottomInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .coordinateSpace(name: "schedule-viewport")
        .background { GeometryReader { geo in
            Color.clear.onChange(of: geo.size, initial: true) { _, size in viewport = size }
        } }
        .focusable(!setup).focusEffectDisabled().focused($focus, equals: .panel)
        .accessibilityLabel(setup ? title : "Your schedule")
        .id(step)
        .environment(\.schedulePageMotion, pageMotion)
        .onPreferenceChange(ScheduleItemFrames.self) { frames = $0 }
        .onChange(of: visibleItems.count, initial: true) { _, count in
            onExitDurationChange(BoardMotion.exitDuration(count: count))
        }
        .allowsHitTesting(!leaving)
        .task(id: step) {
            pageMotion = SchedulePageMotion(phase: .preparing)
            // AppKit removes the previous step's first responder as the new scroll view mounts.
            do { try await _Concurrency.Task.sleep(for: .milliseconds(16)) } catch { return }
            guard !leaving else { return }
            focus = setup ? .heading : .panel
            headingFocused = setup
            pageMotion = reduceMotion ? SchedulePageMotion() : SchedulePageMotion(phase: .entering, units: visibleItems)
        }
        .onChange(of: leaving) { _, leaving in
            pageMotion = SchedulePageMotion(phase: leaving ? .exiting : .entering, units: visibleItems)
        }
        .task(id: nextStep) {
            guard let destination = nextStep else { return }
            if !reduceMotion {
                let duration = BoardMotion.exitDuration(count: visibleItems.count)
                do { try await _Concurrency.Task.sleep(for: .milliseconds(duration)) } catch { return }
            }
            appendedLabel = nil
            nextStep = nil
            step = destination
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { heading.fixedSize(); Spacer(minLength: 0); progress }
                VStack(alignment: .leading, spacing: 0) { heading; progress }
            }
            Text(step == 1 ? "Daymark splits these hours between your focus blocks." : "Add your projects or activities. Daymark shares your weekly hours into focus blocks for each.")
                .font(.system(size: 16)).foregroundStyle(palette.muted)
                .lineSpacing(7).padding(.vertical, 3.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusable().focusEffectDisabled().focused($focus, equals: .heading)
        .onKeyPress(keys: [.tab]) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            if step == 1 { firstTrackFocusRequest += 1 }
            else if let first = blocks.first { focus = .label(first.id) }
            return .handled
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($headingFocused)
        .modifier(ScheduleItemMotion(order: 0))
    }

    private var heading: some View {
        Text(title).font(.system(size: 18)).frame(minHeight: 29, alignment: .leading)
    }

    private var progress: some View {
        Text("Step \(step) of 2").font(.system(size: 16)).foregroundStyle(palette.muted).fixedSize()
    }

    private var actions: some View {
        let back = setup && step == 2
        let disabled = back && named.isEmpty
        let action = setup ? (back ? "Finish setup" : "Next") : "Save schedule"
        return HStack(spacing: 8) {
            if setup { Spacer(minLength: 0) }
            Button { if back { changeStep(1) } else { close(false) } } label: {
                Text(back ? "Back" : "Cancel").padding(.horizontal, 20).frame(height: 46)
            }
            .focusable().focused($focus, equals: .back)
            .daymarkFocusRing(focus == .back, in: Capsule(), palette: palette)
            .onKeyPress(keys: [.tab, Self.backTab]) { press in
                guard back else { return .ignored }
                if (press.key == Self.backTab || press.modifiers.contains(.shift)), let last = blocks.last { focus = .label(last.id) }
                else if !disabled { focus = .submit }
                else { return .ignored }
                return .handled
            }
            if !setup { Spacer(minLength: 0) }
            Button(action: submit) {
                HStack(spacing: 8) {
                    Text(action)
                    if setup && !back { Image(systemName: "arrow.right").frame(width: 16).accessibilityHidden(true) }
                }
                .padding(.horizontal, 20).frame(height: 46)
                .foregroundStyle(disabled ? palette.muted : palette.page)
                .background(disabled ? palette.raised : palette.text, in: Capsule())
            }
            .keyboardShortcut(.defaultAction)
            .disabled(disabled)
            .focusable(!disabled).focused($focus, equals: .submit)
            .daymarkFocusRing(focus == .submit && !disabled, in: Capsule(), palette: palette)
            .onKeyPress(keys: [.tab, Self.backTab]) { press in
                guard back && (press.key == Self.backTab || press.modifiers.contains(.shift)) else { return .ignored }
                focus = .back
                return .handled
            }
        }
        .font(.system(size: 16)).buttonStyle(ScheduleButtonStyle())
    }

    private var onboardingLabels: some View {
        let colours = ["Red", "Amber", "Blue", "Green", "Purple", "Orange"]
        let weights = Schedule.focusShares(named.count, named.map(\.weight))
        return VStack(spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Circle().fill(palette.block(index)).frame(width: 8, height: 8)
                    TextField("Block name", text: Binding(get: {
                        blocks.first { $0.id == item.id }?.label ?? ""
                    }, set: { renameSetup(item.id, to: $0) }),
                              prompt: Text("e.g. " + Schedule.defaults[index]).foregroundStyle(palette.muted))
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .label(item.id))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onSubmit(submit)
                    .onKeyPress(keys: [.tab, Self.backTab]) { press in
                        guard press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
                        let previous = press.key == Self.backTab || press.modifiers.contains(.shift)
                        let next = index + (previous ? -1 : 1)
                        if blocks.indices.contains(next) { focus = .label(blocks[next].id) }
                        else { focus = next < 0 ? .heading : .back }
                        return .handled
                    }
                    .accessibilityLabel(colours[index] + " label")
                    if let at = named.firstIndex(where: { $0.id == item.id }) {
                        Text(hours(weeksHours * weights[at] / 100) + "h/week")
                            .foregroundStyle(palette.muted)
                    }
                }
                .font(.system(size: 16))
                .padding(.horizontal, 12).frame(height: 48)
                .background(palette.page, in: Capsule())
                .daymarkFocusRing(focus == .label(item.id), in: Capsule(), palette: palette)
                .contentShape(Capsule())
                .simultaneousGesture(TapGesture().onEnded { focus = .label(item.id) })
                .modifier(ScheduleItemMotion(order: index + 1, appended: appendedLabel == item.id, focused: focus == .label(item.id)))
            }
        }
    }

    private var tracks: some View {
        VStack(spacing: 0) {
            WorkHoursRuler()
                .padding(.bottom, 8)
                .modifier(ScheduleItemMotion(order: 1))
            ForEach(Schedule.weekdays.indices, id: \.self) { day in
                WorkHoursDay(day: day, ranges: $work[day], labels: displayLabels(blocks),
                             palette: palette, setup: setup,
                             focusTrackRequest: day == 0 ? firstTrackFocusRequest : 0,
                             onNudgeEnd: { nudgeHours = false })
                    .modifier(ScheduleItemMotion(order: day + 2))
            }
        }
        .modifier(WorkHoursNudges(enabled: setup && nudgeHours, days: work.indices.filter { !work[$0].isEmpty }))
    }

    private func changeStep(_ next: Int) {
        error = nil
        nextStep = next
    }

    private func renameSetup(_ id: UUID, to value: String) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        let label = String(value.prefix(48))
        guard blocks[index].label != label else { return }
        let wasNamed = !blocks[index].label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        blocks[index].label = label
        let isNamed = !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if wasNamed != isNamed { for at in blocks.indices { blocks[at].weight = 1 } }
        // Keep the same empty control while the preceding field is typed or loses focus.
        let emptyToKeep = isNamed ? blocks.last?.id : id
        blocks.removeAll { $0.id != emptyToKeep && $0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if blocks.count < 6 && blocks.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            let row = FocusDraft(label: "", weight: 1, original: nil)
            appendedLabel = row.id
            blocks.append(row)
        }
    }

    private func removeBlock(_ index: Int) {
        var remaining = blocks
        remaining.remove(at: index)
        updateBlocks(remaining)
    }

    private func displayLabels(_ values: [FocusDraft]) -> [String] {
        values.enumerated().map { index, item in
            let label = String(item.label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
            return label.isEmpty ? Schedule.defaults[index] : label
        }
    }

    private func updateBlocks(_ next: [FocusDraft]) {
        let previous = next.map { item in blocks.firstIndex { $0.id == item.id } }
        let weights = Schedule.focusShares(next.count, next.map(\.weight))
        guard store.updateCategories(labels: displayLabels(next), shares: weights, coloursFrom: previous) else { return }
        if blocks.count != next.count {
            for day in work.indices {
                for slot in work[day].indices {
                    let allowed = Array(work[day][slot].allowed)
                    work[day][slot].allowed = Set(Schedule.remapped(allowed, coloursFrom: previous) ?? [])
                }
            }
        }
        blocks = next
    }

    private var modelWork: [[WorkWindow]] {
        work.map { $0.map { WorkWindow(start: $0.start, end: $0.end,
            allowed: $0.allowed.isEmpty ? nil : $0.allowed.sorted()) } }
    }

    private func hours(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return String(format: rounded.rounded() == rounded ? "%.0f" : "%.1f", rounded)
    }

    private func submit() {
        guard !leaving else { return }
        let count = setup && step == 2 ? named.count : store.workspace.settings.labels.count
        guard let normalized = Schedule.valid(modelWork, count: max(1, count)) else {
            error = "Work hours must end after they start and must not overlap."; return
        }
        if setup && step == 1 {
            if normalized != modelWork {
                work = normalized.map { day in
                    day.map { RangeDraft(start: $0.start, end: $0.end, allowed: Set($0.allowed ?? [])) }
                }
            }
            changeStep(2)
            return
        }
        let result = setup ? named : blocks
        guard !result.isEmpty else { return }
        let labels = displayLabels(result)
        let next = Settings(labels: labels, shares: Schedule.focusShares(result.count, result.map(\.weight)), work: normalized, onboardingComplete: true)
        let previous = setup ? result.map(\.original) : result.indices.map(Optional.some)
        if store.save(next, coloursFrom: previous) { close(true) }
    }
}


private struct ScheduleItemFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct SchedulePageMotion: Equatable {
    var phase: BoardMotion.Phase = .resting
    var units: [Int] = []
}

private struct ScheduleMotionKey: EnvironmentKey {
    static let defaultValue = SchedulePageMotion()
}

private extension EnvironmentValues {
    var schedulePageMotion: SchedulePageMotion {
        get { self[ScheduleMotionKey.self] }
        set { self[ScheduleMotionKey.self] = newValue }
    }
}

private struct ScheduleItemMotion: ViewModifier {
    let order: Int
    var appended = false
    var focused = false
    @Environment(\.schedulePageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    func body(content: Content) -> some View {
        let index = motion.units.firstIndex(of: order)
        let exiting = motion.phase == .exiting && index != nil
        let hidden = exiting || motion.phase == .preparing || (appended && !revealed)
        let revealImmediately = reduceMotion || (focused && !exiting)
        let pageAnimation = index.flatMap { BoardMotion.animation(for: motion.phase, index: $0, count: motion.units.count) }
        content
            .modifier(ScheduleAppearance(opacity: hidden ? 0 : 1, offset: hidden ? (exiting ? -4 : 8) : 0,
                                         revealImmediately: revealImmediately))
            .animation(revealImmediately ? nil : pageAnimation, value: motion)
            .animation(revealImmediately ? nil : BoardMotion.animation(for: .entering, index: 0, count: 1), value: revealed)
            .background { GeometryReader { geo in
                Color.clear.preference(key: ScheduleItemFrames.self, value: [order: geo.frame(in: .named("schedule-viewport"))])
            } }
            .task(id: appended) {
                guard appended else { return }
                do { try await _Concurrency.Task.sleep(for: .milliseconds(16)) } catch { return }
                revealed = true
            }
    }
}

// Keyboard focus must expose the field even while its entrance is interpolating.
private struct ScheduleAppearance: AnimatableModifier {
    var opacity: Double
    var offset: CGFloat
    let revealImmediately: Bool

    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(opacity, offset) }
        set { opacity = newValue.first; offset = newValue.second }
    }

    func body(content: Content) -> some View {
        content.opacity(revealImmediately ? 1 : opacity)
            .offset(y: revealImmediately ? 0 : offset)
            .blur(radius: revealImmediately ? 0 : 4 * (1 - opacity))
    }
}

struct ScheduleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .timingCurve(0.25, 1, 0.5, 1, duration: 0.12),
                       value: configuration.isPressed)
    }
}
