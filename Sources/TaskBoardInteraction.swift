import SwiftUI

struct TaskPointerMove {
    let task: Task
    let origin: CGRect
    let start: CGPoint
    var location: CGPoint

    var frame: CGRect {
        origin.offsetBy(dx: location.x - start.x, dy: location.y - start.y)
    }
}

struct TaskSettle: ViewModifier {
    let origin: CGRect?
    func body(content: Content) -> some View {
        content.visualEffect { view, proxy in
            let frame = proxy.frame(in: .named("task-drag-surface"))
            return view.offset(x: (origin?.minX ?? frame.minX) - frame.minX,
                               y: (origin?.minY ?? frame.minY) - frame.minY)
        }
    }
}

struct TaskTitleLabel: View {
    let task: Task
    let palette: DaymarkPalette
    let allowsWrap: Bool

    var body: some View {
        let split = task.completedOn == nil ? task.title.firstIndex(of: ".") : nil
        let title = split.map { String(task.title.prefix(through: $0)) } ?? task.title
        let detail = split.map { String(task.title.suffix(from: task.title.index(after: $0))) } ?? ""
        let text = (Text(title).foregroundColor(task.completedOn == nil ? palette.text : palette.muted)
            + Text(detail).foregroundColor(palette.muted))
            .strikethrough(task.completedOn != nil)
            .lineLimit(allowsWrap ? nil : 1).truncationMode(.tail)
            .lineSpacing(7)
            .fixedSize(horizontal: false, vertical: allowsWrap)
        if allowsWrap && detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            BalancedTaskTitle { text }
        } else {
            text
        }
    }
}

// Balance standalone titles without adding a line. An inline description uses the full measure.
private struct BalancedTaskTitle: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let title = subviews.first else { return .zero }
        let ideal = title.sizeThatFits(.unspecified)
        let width = min(ideal.width, proposal.width ?? ideal.width)
        return CGSize(width: width, height: title.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let title = subviews.first else { return }
        var high = bounds.width
        if title.sizeThatFits(.unspecified).width > high {
            var low = high / 2
            while high - low > 1 {
                let width = (low + high) / 2
                if title.sizeThatFits(ProposedViewSize(width: width, height: nil)).height <= bounds.height + 0.5 {
                    high = width
                } else {
                    low = width
                }
            }
        }
        title.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: high, height: nil))
    }
}
