import SwiftUI

struct ScheduleEditor: View {
    private struct RangeDraft: Identifiable {
        var id = UUID()
        var start: Int
        var end: Int
        var allowed: Set<Int> = []
    }
    private struct FocusDraft: Identifiable {
        var id = UUID()
        var label: String
        var weight: Double
        var original: Int?
    }
    private struct SlotEdit {
        let day: Int
        var range: RangeDraft
        var start: String
        var end: String
    }

    @ObservedObject var store: WorkspaceStore
    let palette: DaymarkPalette
    let setup: Bool
    let close: (Bool) -> Void
    @State private var step = 1
    @State private var work: [[RangeDraft]]
    @State private var blocks: [FocusDraft]
    @State private var editing: SlotEdit?
    @State private var removing: UUID?
    @State private var error: String?
    @FocusState private var focusedSlot: Bool

    init(store: WorkspaceStore, palette: DaymarkPalette, setup: Bool, close: @escaping (Bool) -> Void) {
        self.store = store; self.palette = palette; self.setup = setup; self.close = close
        let settings = store.workspace.settings
        _work = State(initialValue: settings.work.map {
            $0.map { RangeDraft(start: $0.start, end: $0.end, allowed: Set($0.allowed ?? [])) }
        })
        let weights = Schedule.focusShares(settings.labels.count, settings.shares)
        var drafts = settings.labels.enumerated().map {
            FocusDraft(label: $0.element, weight: weights[$0.offset], original: $0.offset)
        }
        if setup && drafts.count < 6 { drafts.append(FocusDraft(label: "", weight: 1, original: nil)) }
        _blocks = State(initialValue: drafts)
    }

    private var named: [FocusDraft] { blocks.filter { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    private var weeksHours: Double {
        Double(work.flatMap { $0 }.reduce(0) { $0 + $1.end - $1.start }) / 60
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if setup {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(step == 1 ? "Select the hours you normally work" : "What do you want to make time for?")
                                .font(.system(size: 16, weight: .medium))
                            Spacer()
                            Text("Step \(step) of 2").font(.system(size: 12)).foregroundStyle(palette.muted)
                        }
                        Text(step == 1 ? "Daymark splits these hours between your focus blocks." : "Add your projects or activities. Daymark shares your weekly hours into focus blocks for each.")
                            .font(.system(size: 13)).foregroundStyle(palette.muted)
                    }.padding(.top, 16).padding(.bottom, 20)
                }
                if setup && step == 2 { onboardingLabels }
                if !setup { settingsLabels }
                if !setup || step == 1 { tracks }
                if let error = store.error ?? error { Text(error).font(.caption).foregroundStyle(palette.muted) }
                HStack(spacing: 8) {
                    Spacer()
                    if setup && step == 2 {
                        Button("Back") { error = nil; step = 1 }.buttonStyle(.plain)
                    } else {
                        Button("Cancel") { close(false) }.buttonStyle(.plain)
                    }
                    Button {
                        submit()
                    } label: {
                        HStack(spacing: 8) {
                            Text(setup ? (step == 1 ? "Next" : "Finish setup") : "Save schedule")
                            if setup && step == 1 { Image(systemName: "arrow.right") }
                        }
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16).frame(height: 40)
                        .foregroundStyle(palette.page)
                        .background(palette.text, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(editing != nil || (setup && step == 2 && named.isEmpty))
                    .opacity(editing != nil || (setup && step == 2 && named.isEmpty) ? 0.45 : 1)
                }.padding(.vertical, 16)
            }
            .padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading)
        }.id(step)
        .onExitCommand {
            if editing != nil { editing = nil } else { close(false) }
        }
    }

    private var onboardingLabels: some View {
        VStack(spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, item in
                let weight = Schedule.focusShares(named.count, named.map(\.weight))
                HStack(spacing: 8) {
                    Circle().fill(palette.block(index)).frame(width: 8, height: 8)
                    TextField("e.g. " + Schedule.defaults[index], text: Binding(get: {
                        blocks.first { $0.id == item.id }?.label ?? ""
                    }, set: { renameSetup(item.id, to: $0) }))
                    .textFieldStyle(.plain)
                    .accessibilityLabel(Schedule.defaults[index] + " label")
                    if let at = named.firstIndex(where: { $0.id == item.id }) {
                        Text(hours(weeksHours * weight[at] / 100) + "h/week")
                            .foregroundStyle(palette.muted)
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12).frame(height: 48)
                .background(palette.page, in: Capsule())
            }
        }
    }

    private var settingsLabels: some View {
        let weights = Schedule.focusShares(blocks.count, blocks.map(\.weight))
        let items = Schedule.buildWeek(modelWork, count: blocks.count, shares: weights)
        return HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 8) {
                            Circle().fill(palette.block(index)).frame(width: 8, height: 8)
                            if removing == item.id { Text("Sure?").frame(maxWidth: .infinity, alignment: .leading) }
                            else {
                                TextField(Schedule.defaults[index], text: $blocks[index].label)
                                    .textFieldStyle(.plain)
                                    .accessibilityLabel("Focus block \(index + 1)")
                                let h = Double(items.filter { $0.colour == index }.reduce(0) { $0 + $1.end - $1.start }) / 60
                                Text(hours(weights[index]) + "%").foregroundStyle(palette.muted)
                                    .help("Scheduled \(hours(h)) hours per week")
                            }
                            if blocks.count > 1 {
                                Button {
                                    if removing == item.id { removeBlock(index) }
                                    else { removing = item.id }
                                } label: {
                                    Text(removing == item.id ? "✓" : "×").foregroundStyle(palette.muted)
                                }.buttonStyle(.plain)
                                    .accessibilityLabel((removing == item.id ? "Confirm remove " : "Remove ") + item.label)
                            }
                        }
                        .padding(.horizontal, 12).frame(width: max(128, weights[index] * 4), height: 48)
                        .background(palette.page, in: Capsule())
                    }
                }
            }.scrollIndicators(.hidden)
            if blocks.count < 6 {
                Button {
                    let oldCount = blocks.count
                    for index in blocks.indices { blocks[index].weight = weights[index] * Double(oldCount) / Double(oldCount + 1) }
                    let used = Set(blocks.map { $0.label.lowercased() })
                    let label = Schedule.defaults.first { !used.contains($0.lowercased()) } ?? "New block"
                    blocks.append(FocusDraft(label: label, weight: 100 / Double(oldCount + 1), original: nil))
                } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                        .background(palette.page, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Add block label")
            }
        }.font(.system(size: 13))
    }

    private var tracks: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 36, height: 12)
                HStack {
                    ForEach(0..<7, id: \.self) { index in
                        if index > 0 { Spacer(minLength: 0) }
                        Text(String(format: "%02d", index * 4))
                    }
                }.font(.system(size: 12)).monospacedDigit().padding(.horizontal, 2)
            }
            ForEach(0..<7, id: \.self) { day in
                HStack(spacing: 8) {
                    Text(Schedule.weekdays[day].prefix(3).uppercased()).font(.system(size: 12))
                        .frame(width: 36, alignment: .leading)
                        .accessibilityLabel(Schedule.weekdays[day])
                    GeometryReader { geo in
                        let width = max(0, geo.size.width - 4)
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.page)
                                .contentShape(Rectangle())
                                .onTapGesture(coordinateSpace: .local) { point in
                                    guard editing == nil, width > 0 else { return }
                                    insert(day, minute: Int(((point.x - 2) / width * 96).rounded()) * 15)
                                }
                            ForEach(work[day]) { range in
                                let slotWidth = width * CGFloat(range.end - range.start) / 1440
                                ZStack {
                                    Button { openEditor(day, range) } label: {
                                        Capsule().fill(palette.text.opacity(0.12)).frame(width: slotWidth, height: 32)
                                    }.buttonStyle(.plain)
                                        .accessibilityLabel("\(Schedule.weekdays[day]) \(Schedule.clock(range.start)) to \(Schedule.clock(range.end))")
                                        .help("\(Schedule.clock(range.start))–\(Schedule.clock(range.end))")
                                    if !setup && slotWidth >= CGFloat(blocks.count * 16 + 14) { dots(day, range, expanded: false) }
                                }.offset(x: 2 + width * CGFloat(range.start) / 1440)
                            }
                        }
                    }.frame(height: 36)
                    .accessibilityAction(named: Text("Add hours on \(Schedule.weekdays[day])")) {
                        insert(day, minute: 540)
                    }
                }.frame(height: 48)
                if editing?.day == day { exactEditor.padding(.leading, 44) }
            }
        }
    }

    private var exactEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let edit = editing {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Start")
                        TextField("HH:MM", text: slotBinding(start: true))
                            .focused($focusedSlot)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("End")
                        TextField("HH:MM", text: slotBinding(start: false))
                    }
                    Button("Done", action: finishSlot).disabled(parsed(edit) == nil)
                    Button("Remove", role: .destructive) {
                        work[edit.day].removeAll { $0.id == edit.range.id }
                        editing = nil
                    }
                }.textFieldStyle(.roundedBorder)
                if !setup { dots(edit.day, edit.range, expanded: true) }
                if parsed(edit) == nil { Text("Choose a free range in 15-minute steps.").foregroundStyle(palette.muted) }
            }
        }.font(.system(size: 12)).padding(.bottom, 8)
            .onSubmit(finishSlot)
    }

    private func dots(_ day: Int, _ range: RangeDraft, expanded: Bool) -> some View {
        let set = range.allowed.isEmpty ? Set(blocks.indices) : range.allowed
        return HStack(spacing: expanded ? 8 : 0) {
            ForEach(blocks.indices, id: \.self) { index in
                let selected = set.contains(index)
                Button {
                    var updated = set
                    if selected { updated.remove(index) } else { updated.insert(index) }
                    if expanded { editing?.range.allowed = updated }
                    else if let slot = work[day].firstIndex(where: { $0.id == range.id }) {
                        work[day][slot].allowed = updated
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(palette.block(index)).frame(width: 8, height: 8)
                            .scaleEffect(selected ? 1 : 0.5).opacity(selected ? 1 : 0.35)
                        if expanded { Text(blocks[index].label) }
                    }.frame(minWidth: 16, minHeight: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(selected && set.count == 1)
                    .accessibilityLabel(blocks[index].label)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func slotBinding(start: Bool) -> Binding<String> {
        Binding(get: { (start ? editing?.start : editing?.end) ?? "" }, set: {
            if start { editing?.start = $0 } else { editing?.end = $0 }
        })
    }

    private func openEditor(_ day: Int, _ range: RangeDraft) {
        editing = SlotEdit(day: day, range: range, start: Schedule.clock(range.start), end: Schedule.clock(range.end))
        focusedSlot = true
    }

    private func insert(_ day: Int, minute: Int) {
        let minute = min(1425, max(0, minute))
        if work[day].contains(where: { $0.start <= minute && minute < $0.end }) { return }
        let low = work[day].filter { $0.end <= minute }.map(\.end).max() ?? 0
        let high = work[day].filter { $0.start > minute }.map(\.start).min() ?? 1440
        guard high - low >= 15 else { return }
        let start = max(low, min(minute, high - 60))
        work[day].append(RangeDraft(start: start, end: min(high, start + 60)))
        work[day].sort { $0.start < $1.start }
    }

    private func parsed(_ edit: SlotEdit) -> RangeDraft? {
        guard let start = Schedule.minute(edit.start), var end = Schedule.minute(edit.end) else { return nil }
        if end == 0 { end = 1440 }
        guard start < end, start % 15 == 0, end % 15 == 0,
              !work[edit.day].contains(where: { $0.id != edit.range.id && $0.start < end && start < $0.end }) else { return nil }
        var range = edit.range
        range.start = start; range.end = end
        return range
    }

    private func finishSlot() {
        guard let edit = editing, let range = parsed(edit),
              let index = work[edit.day].firstIndex(where: { $0.id == range.id }) else { return }
        if range.end - range.start == 15 && edit.range.end - edit.range.start > 15 {
            work[edit.day].remove(at: index)
        } else {
            work[edit.day][index] = range
            work[edit.day].sort { $0.start < $1.start }
        }
        editing = nil
    }

    private func renameSetup(_ id: UUID, to value: String) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        let wasNamed = !blocks[index].label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        blocks[index].label = String(value.prefix(48))
        let isNamed = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if wasNamed != isNamed { for at in blocks.indices { blocks[at].weight = 1 } }
        blocks.removeAll { $0.id != id && $0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if blocks.count < 6 && blocks.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            blocks.append(FocusDraft(label: "", weight: 1, original: nil))
        }
    }

    private func removeBlock(_ index: Int) {
        removing = nil
        blocks.remove(at: index)
        for day in work.indices {
            for slot in work[day].indices {
                work[day][slot].allowed = Set(work[day][slot].allowed.compactMap { $0 == index ? nil : ($0 > index ? $0 - 1 : $0) })
            }
        }
    }

    private var modelWork: [[WorkWindow]] {
        work.map { $0.map { WorkWindow(start: $0.start, end: $0.end,
            allowed: setup || $0.allowed.isEmpty ? nil : $0.allowed.sorted()) } }
    }

    private func hours(_ value: Double) -> String { String(format: value.rounded() == value ? "%.0f" : "%.1f", value) }

    private func submit() {
        guard editing == nil, let normalized = Schedule.valid(modelWork, count: max(1, setup ? named.count : blocks.count)) else {
            error = "Work hours must end after they start and must not overlap."; return
        }
        if setup && step == 1 { error = nil; step = 2; return }
        let result = setup ? named : blocks
        guard !result.isEmpty else { return }
        let labels = result.enumerated().map { index, item in
            let label = String(item.label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
            return label.isEmpty ? Schedule.defaults[index] : label
        }
        let next = Settings(labels: labels, shares: Schedule.focusShares(result.count, result.map(\.weight)), work: normalized, onboardingComplete: true)
        if store.save(next, coloursFrom: result.map(\.original)) { close(true) }
    }
}
