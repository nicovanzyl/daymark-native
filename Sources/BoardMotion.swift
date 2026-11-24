import SwiftUI

enum BoardElement: Hashable {
    case viewport, timeline, task(UUID), column(Stage), heading(String)
}

struct BoardFrames: PreferenceKey {
    static let defaultValue: [BoardElement: CGRect] = [:]
    static func reduce(value: inout [BoardElement: CGRect], nextValue: () -> [BoardElement: CGRect]) {
        value.merge(nextValue()) { _, overlay in overlay }
    }
}

struct BoardFrameReader: View {
    let key: BoardElement
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: BoardFrames.self,
                                   value: [key: proxy.frame(in: .named("task-drag-surface"))])
        }
    }
}

struct BoardMotion: Equatable {
    enum Phase { case resting, exiting, preparing, entering }
    var phase: Phase = .resting
    var tasksOnly = false
    var units: [BoardElement] = []

    static func visible(in frames: [BoardElement: CGRect], tasksOnly: Bool) -> [BoardElement] {
        guard let viewport = frames[.viewport] else { return [] }
        return frames.filter { id, rect in
            guard !rect.intersection(viewport).isEmpty else { return false }
            switch id {
            case .timeline: return !tasksOnly
            case .task, .heading: return true
            case .viewport, .column: return false
            }
        }.sorted { lhs, rhs in
            if lhs.value.minY == rhs.value.minY { return lhs.value.minX < rhs.value.minX }
            return lhs.value.minY < rhs.value.minY
        }.map(\.key)
    }

    func animation(for index: Int) -> Animation? {
        Self.animation(for: phase, index: index, count: units.count)
    }

    static func exitDuration(count: Int) -> Int {
        count > 0 ? 160 + min(90, (count - 1) * 18) : 0
    }

    static func animation(for phase: Phase, index: Int, count: Int) -> Animation? {
        let gaps = Double(max(1, count - 1))
        switch phase {
        case .exiting:
            let delay = Double(count - index - 1) * min(0.018, 0.09 / gaps)
            return .timingCurve(0.4, 0, 1, 1, duration: 0.16).delay(delay)
        case .entering:
            let delay = Double(index) * min(0.04, 0.225 / gaps)
            return .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.4).delay(delay)
        default: return nil
        }
    }
}

private struct BoardMotionKey: EnvironmentKey {
    static let defaultValue = BoardMotion()
}

extension EnvironmentValues {
    var boardMotion: BoardMotion {
        get { self[BoardMotionKey.self] }
        set { self[BoardMotionKey.self] = newValue }
    }
}

struct BoardMotionUnit: ViewModifier {
    let id: BoardElement
    @Environment(\.boardMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isFocused) private var focused

    init(_ id: BoardElement) { self.id = id }

    func body(content: Content) -> some View {
        let index = motion.units.firstIndex(of: id)
        let participates = !reduceMotion && !(motion.tasksOnly && id == .timeline)
        let hidden = participates && (motion.phase == .preparing || (motion.phase == .exiting && index != nil))
        content
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden ? (motion.phase == .exiting ? -4 : 8) : 0)
            .blur(radius: hidden ? 4 : 0)
            .animation(participates && !(focused && motion.phase == .entering)
                       ? index.flatMap(motion.animation(for:)) : nil, value: motion)
            .background(BoardFrameReader(key: id))
    }
}
