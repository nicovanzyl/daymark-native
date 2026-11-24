import AppKit
import SwiftUI

struct FocusDraft: Identifiable, Equatable {
    var id = UUID()
    var label: String
    var weight: Double
    var original: Int?
}

struct FocusAllocation: View {
    @Binding var blocks: [FocusDraft]
    let work: [[WorkWindow]]
    let palette: DaymarkPalette
    let removeBlock: (Int) -> Void

    private enum Control: Hashable {
        case label(UUID), remove(UUID), divider(UUID), add
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @FocusState private var focus: Control?
    @State private var pendingFocus: UUID?
    @State private var hoveredPill: UUID?
    @State private var hoveredDivider: UUID?
    @State private var hovering = false
    @State private var confirming: UUID?
    private struct Drag {
        let ids: [UUID]
        let initial: [Double]
        let width: CGFloat
        var preview: [Double]
    }

    @State private var drag: Drag?
    @State private var showHours = false

    private var weights: [Double] { Schedule.focusShares(blocks.count, blocks.map(\.weight)) }

    private func scheduledHours(_ weights: [Double]) -> [Double] {
        let windows = work.flatMap { $0 }
        if windows.allSatisfy({ $0.allowed?.isEmpty != false }) {
            let minutes = windows.reduce(0) { $0 + $1.end - $1.start }
            return weights.map { Double(minutes) / 60 * $0 / 100 }
        }
        var hours = Array(repeating: 0.0, count: weights.count)
        for block in Schedule.buildWeek(work, count: weights.count, shares: weights) {
            hours[block.colour] += Double(block.end - block.start) / 60
        }
        return hours
    }

    var body: some View {
        let shares = drag?.preview ?? weights
        let hours = scheduledHours(shares)
        HStack(spacing: 8) {
            GeometryReader { geometry in
                // Like the web splitter, keep even the smallest panel at least 100 points wide.
                let gaps = CGFloat(max(0, blocks.count - 1)) * 12
                let minimumWidth = max(CGFloat(blocks.count * 132), ceil(10_000 / max(shares.min() ?? 100, 0.1)) + gaps)
                let panelSpace = drag?.width ?? (max(geometry.size.width, minimumWidth) - gaps)
                ScrollViewReader { scroller in
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                                if index > 0 { divider(before: index, width: panelSpace) }
                                pill(index, block, share: shares[index], hours: hours[index])
                                    .frame(width: panelSpace * shares[index] / 100)
                                    .id(block.id)
                            }
                        }
                    }
                    .onChange(of: blocks.map(\.id)) {
                        drag = nil
                        guard let id = pendingFocus else { return }
                        scroller.scrollTo(id, anchor: .center)
                        focus = .label(id)
                        pendingFocus = nil
                    }
                }
            }
            if blocks.count < Schedule.defaults.count {
                Button(action: add) {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                        .background(palette.page, in: Circle())
                }
                .buttonStyle(ScheduleButtonStyle())
                .focused($focus, equals: .add)
                .daymarkFocusRing(focus == .add, in: Circle(), palette: palette)
                .accessibilityLabel("Add block label")
                .help("Add block")
            }
        }
        .frame(height: 48)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Block labels")
        .onHover { hovering = $0 }
        .onChange(of: focus) { _, current in
            if let confirming, current != .remove(confirming) { self.confirming = nil }
        }
        .task(id: hovering || focus != nil || activeState == .inactive) {
            guard !hovering, focus == nil, activeState != .inactive else { return }
            while !_Concurrency.Task.isCancelled {
                do { try await _Concurrency.Task.sleep(for: .seconds(6)) } catch { return }
                showHours.toggle()
            }
        }
    }

    private func pill(_ index: Int, _ block: FocusDraft, share: Double, hours: Double) -> some View {
        let name = block.label.isEmpty ? Schedule.defaults[index] : block.label
        let canRemove = blocks.count > 1 && (hoveredPill == block.id || focus == .label(block.id) || focus == .remove(block.id) || confirming == block.id)
        let format = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US_POSIX"))
        let percentage = share.formatted(format) + "%"
        let scheduled = hours.formatted(format) + "h"
        return HStack(spacing: 0) {
            Circle().fill(palette.block(index)).frame(width: 8, height: 8).padding(.trailing, 8)
            TextField(Schedule.defaults[index], text: Binding(get: { block.label }, set: { value in
                if let at = blocks.firstIndex(where: { $0.id == block.id }) {
                    blocks[at].label = String(value.prefix(48))
                }
            }))
            .textFieldStyle(.plain)
            .focused($focus, equals: .label(block.id))
            .accessibilityLabel("Focus block \(index + 1) label")
            .foregroundStyle(focus == .label(block.id) && confirming != block.id ? palette.text : Color.clear)
            .overlay(alignment: .leading) {
                if confirming == block.id || focus != .label(block.id) {
                    Text(confirming == block.id ? "Sure?" : name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(block.label.isEmpty && confirming != block.id ? palette.muted : palette.text)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.trailing, 4)
            ZStack(alignment: .trailing) {
                value(percentage, visible: !showHours)
                value(scheduled, visible: showHours)
            }
            .animation(reduceMotion ? .linear(duration: 0.16) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.24), value: showHours)
            .fixedSize().clipped()
            .foregroundStyle(palette.muted)
            .opacity(canRemove ? 0 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Target \(percentage), scheduled \(scheduled) per week")
        }
        .padding(.horizontal, 12)
        .lineLimit(1)
        .font(.system(size: 16))
        .frame(height: 48)
        .background(palette.page, in: Capsule())
        .daymarkFocusRing(focus == .label(block.id), in: Capsule(), palette: palette)
        .overlay(alignment: .trailing) {
            if blocks.count > 1 {
                Button {
                    if confirming == block.id {
                        pendingFocus = blocks[index == blocks.count - 1 ? index - 1 : index + 1].id
                        confirming = nil
                        removeBlock(index)
                    } else {
                        confirming = block.id
                        focus = .remove(block.id)
                    }
                } label: {
                    Image(systemName: confirming == block.id ? "checkmark" : "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.muted)
                        .frame(width: 40, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScheduleButtonStyle())
                .focusable()
                .focused($focus, equals: .remove(block.id))
                .daymarkFocusRing(focus == .remove(block.id), in: Circle().inset(by: 4), palette: palette)
                .opacity(canRemove ? 1 : 0)
                .allowsHitTesting(canRemove)
                .accessibilityLabel((confirming == block.id ? "Confirm remove " : "Remove ") + name)
                .onKeyPress(.escape) {
                    guard confirming == block.id else { return .ignored }
                    confirming = nil
                    focus = .label(block.id)
                    return .handled
                }
            }
        }
        .onHover { inside in
            if inside { hoveredPill = block.id }
            else {
                if hoveredPill == block.id { hoveredPill = nil }
                if confirming == block.id { confirming = nil }
            }
        }
    }

    private func value(_ text: String, visible: Bool) -> some View {
        Text(text).monospacedDigit()
            .opacity(visible ? 1 : 0)
            .rotation3DEffect(.degrees(visible || reduceMotion ? 0 : -30), axis: (x: 1, y: 0, z: 0))
            .offset(y: visible || reduceMotion ? 0 : 6)
    }

    private func add() {
        let count = blocks.count
        guard count < Schedule.defaults.count else { return }
        let used = Set(blocks.enumerated().map { ($0.element.label.isEmpty ? Schedule.defaults[$0.offset] : $0.element.label).lowercased() })
        let candidates = [Schedule.defaults[count]] + Schedule.defaults
        let name = candidates.first { !used.contains($0.lowercased()) } ?? Schedule.defaults[count]
        let shares = weights
        var next = blocks
        for index in next.indices { next[index].weight = shares[index] * Double(count) / Double(count + 1) }
        let block = FocusDraft(label: name, weight: 100 / Double(count + 1), original: nil)
        pendingFocus = block.id
        blocks = next + [block]
    }

    private func divider(before index: Int, width: CGFloat) -> some View {
        let id = blocks[index].id
        let active = hoveredDivider == id || focus == .divider(id)
        return Capsule().fill(palette.muted)
            .frame(width: 2, height: 16)
            .opacity(active ? 1 : 0)
            .frame(width: 12, height: 48)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hoveredDivider = id; NSCursor.resizeLeftRight.push() }
                else { if hoveredDivider == id { hoveredDivider = nil }; NSCursor.pop() }
            }
            .focusable()
            .focused($focus, equals: .divider(id))
            .focusEffectDisabled()
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { gesture in
                    let start = drag ?? Drag(ids: blocks.map(\.id), initial: weights, width: width, preview: weights)
                    guard start.ids == blocks.map(\.id) else { drag = nil; return }
                    var updated = start
                    updated.preview = Self.resized(start.initial, before: index,
                        by: gesture.translation.width / start.width * 100, minimum: 10_000 / start.width)
                    drag = updated
                    focus = .divider(id)
                }
                .onEnded { gesture in
                    guard let start = drag else { return }
                    drag = nil
                    if start.ids == blocks.map(\.id) {
                        adjust(index, from: start.initial, by: gesture.translation.width / start.width * 100, width: start.width)
                    }
                })
            .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end], phases: [.down, .repeat]) { key in
                let step = key.modifiers.contains(.shift) ? 10.0 : 1.0
                let delta: Double
                switch key.key {
                case .leftArrow: delta = -step
                case .rightArrow: delta = step
                case .home: delta = -100
                default: delta = 100
                }
                adjust(index, from: weights, by: delta, width: width)
                return .handled
            }
            .accessibilityLabel("Allocation between \(blocks[index - 1].label) and \(blocks[index].label)")
            .accessibilityValue(weights[index - 1].formatted(.number.precision(.fractionLength(0...1))) + "%")
            .accessibilityAdjustableAction { direction in
                adjust(index, from: weights, by: direction == .increment ? 1 : -1, width: width)
            }
    }

    private func adjust(_ index: Int, from shares: [Double], by delta: Double, width: CGFloat) {
        guard shares.count == blocks.count else { return }
        let next = Self.resized(shares, before: index, by: delta, minimum: 10_000 / width)
        if zip(next, weights).contains(where: { abs($0 - $1) > 0.000001 }) {
            var result = blocks
            for at in result.indices { result[at].weight = next[at] }
            blocks = result
        }
    }

    // Once an adjacent panel reaches its minimum, take the remaining space from the next panel.
    static func resized(_ shares: [Double], before index: Int, by delta: Double, minimum: Double) -> [Double] {
        var next = shares
        let growing = delta >= 0 ? index - 1 : index
        var donor = delta >= 0 ? index : index - 1
        var remaining = abs(delta)
        while shares.indices.contains(donor), remaining > 0 {
            let transfer = min(remaining, max(0, next[donor] - minimum))
            next[donor] -= transfer
            next[growing] += transfer
            remaining -= transfer
            donor += delta >= 0 ? 1 : -1
        }
        return next
    }
}
