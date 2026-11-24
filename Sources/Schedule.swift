import Foundation

struct WorkWindow: Codable, Equatable {
    var start: Int
    var end: Int
    var allowed: [Int]? = nil
}

struct FocusBlock: Codable, Equatable, Identifiable {
    let day: Int
    let start: Int
    let end: Int
    let colour: Int
    var id: Int { day * 1440 + start }
}

struct Settings: Codable, Equatable {
    var labels = ["", "", ""]
    var shares = [1.0, 1.0, 1.0]
    var work = Array(repeating: [WorkWindow(start: 540, end: 1020)], count: 5) + [[], []]
    var onboardingComplete = false
}

enum Schedule {
    static let defaults = ["Research", "Marketing", "Prototyping", "Design", "Development", "Planning"]
    static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    static func day(_ date: Date, calendar: Calendar = .current) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    static func seconds(_ date: Date, calendar: Calendar = .current) -> Int {
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (time.hour ?? 0) * 3600 + (time.minute ?? 0) * 60 + (time.second ?? 0)
    }

    static func dateKey(_ date: Date, calendar: Calendar = .current) -> String {
        let d = calendar.dateComponents([.year,.month,.day], from: date)
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    static func remapped(_ allowed: [Int]?, coloursFrom previous: [Int?]) -> [Int]? {
        guard let allowed, !allowed.isEmpty else { return nil }
        let surviving = previous.indices.filter { index in
            previous[index].map(allowed.contains) ?? false
        }
        return surviving.isEmpty || surviving.count == previous.count ? nil : surviving
    }

    static func valid(_ week: [[WorkWindow]], count: Int) -> [[WorkWindow]]? {
        guard week.count == 7 else { return nil }
        var result = [[WorkWindow]]()
        for day in week {
            var normalized = [WorkWindow]()
            for var range in day.sorted(by: { $0.start < $1.start }) {
                guard range.start >= 0, range.start < range.end, range.end <= 1440,
                      (normalized.last?.end ?? 0) <= range.start else { return nil }
                let allowed = Array(Set((range.allowed ?? []).filter { (0..<count).contains($0) })).sorted()
                range.allowed = allowed.isEmpty || allowed.count == count ? nil : allowed
                if let last = normalized.last, last.end == range.start, last.allowed == range.allowed {
                    normalized[normalized.count - 1].end = range.end
                } else { normalized.append(range) }
            }
            result.append(normalized)
        }
        return result
    }

    static func focusShares(_ count: Int, _ shares: [Double]?) -> [Double] {
        guard count > 0 else { return [] }
        if let shares, shares.count == count, shares.allSatisfy({ $0.isFinite && $0 > 0 }) {
            let total = shares.reduce(0, +)
            if total.isFinite { return shares.map { $0 / total * 100 } }
        }
        return Array(repeating: 1.0 / Double(count) * 100, count: count)
    }

    private struct Slot {
        let day: Int
        let window: WorkWindow
        var length: Int { window.end - window.start }
    }

    static func buildWeek(_ work: [[WorkWindow]], count: Int, shares: [Double]?) -> [FocusBlock] {
        guard (1...6).contains(count), let week = valid(work, count: count) else { return [] }
        let windows = week.enumerated().flatMap { day, ranges in ranges.map { Slot(day: day, window: $0) } }
        let total = windows.map(\.length).reduce(0, +)
        guard total > 0 else { return [] }
        let exact = focusShares(count, shares).map { Double(total) * $0 / 100 }
        var targets = exact.map { Int(floor($0)) }
        let fractions = exact.indices.sorted {
            let a = exact[$0] - Double(targets[$0]), b = exact[$1] - Double(targets[$1])
            return a == b ? $0 < $1 : a > b
        }
        for index in fractions.prefix(max(0, total - targets.reduce(0, +))) { targets[index] += 1 }
        if windows.contains(where: { $0.window.allowed != nil }) { return allocateRestricted(windows, targets) }

        typealias Score = (blocks: [FocusBlock], shortfall: Int, splits: Int, coverage: Int)
        func allocate(_ slots: [Slot]) -> Score {
            var blocks = [FocusBlock](), days = Array(repeating: Set<Int>(), count: count)
            var colour = 0, remaining = targets[0], shortfall = 0, splits = 0
            for slot in slots {
                var start = slot.window.start
                while start < slot.window.end {
                    while remaining == 0 && colour + 1 < count {
                        colour += 1
                        remaining = targets[colour]
                    }
                    let length = min(remaining, slot.window.end - start)
                    guard length > 0 else { break }
                    let end = start + length
                    blocks.append(FocusBlock(day: slot.day, start: start, end: end, colour: colour))
                    days[colour].insert(slot.day)
                    shortfall += max(0, min(240, slot.length, targets[colour]) - length)
                    if end < slot.window.end { splits += 1 }
                    start = end; remaining -= length
                }
            }
            return (blocks, shortfall, splits, days.map(\.count).reduce(0, +))
        }
        var best = allocate(windows)
        if count > 1 {
            let longest = windows.enumerated().sorted {
                $0.element.length == $1.element.length ? $0.offset < $1.offset : $0.element.length > $1.element.length
            }.map(\.element)
            for order in [windows, longest] {
                let size = order.count, offsets = min(size, 24)
                for offset in 0..<offsets {
                    for step in 1...min(12, size) {
                        let start = offset * size / offsets
                        let indices = (0..<size).map { (start + $0 * step) % size }
                        if Set(indices).count != size { continue }
                        let plan = allocate(indices.map { order[$0] })
                        if (plan.shortfall, plan.splits, -plan.coverage) < (best.shortfall, best.splits, -best.coverage) {
                            best = plan
                        }
                    }
                }
            }
        }
        return best.blocks.sorted(by: blockOrder)
    }

    private static func blockOrder(_ a: FocusBlock, _ b: FocusBlock) -> Bool {
        (a.day, a.start) < (b.day, b.start)
    }

    private static func allocateRestricted(_ windows: [Slot], _ targets: [Int]) -> [FocusBlock] {
        let eligible = windows.map { $0.window.allowed ?? Array(targets.indices) }
        let order = windows.indices.sorted {
            eligible[$0].count == eligible[$1].count ? $0 < $1 : eligible[$0].count < eligible[$1].count
        }
        var amounts = Array(repeating: Array(repeating: 0, count: targets.count), count: windows.count)
        var remaining = targets
        func assign(_ index: Int, _ length: Int, _ visited: inout Set<Int>) -> Int {
            let whole = eligible[index].first { !visited.contains($0) && remaining[$0] >= length }
            for colour in whole.map({ [$0] }) ?? eligible[index] where !visited.contains(colour) {
                let take = min(remaining[colour], length)
                if take > 0 {
                    remaining[colour] -= take
                    amounts[index][colour] += take
                    return take
                }
            }
            for colour in eligible[index] where !visited.contains(colour) {
                visited.insert(colour)
                for other in order where other != index && amounts[other][colour] > 0 {
                    let needed = min(length, amounts[other][colour])
                    let moved = assign(other, needed, &visited)
                    if moved > 0 {
                        amounts[other][colour] -= moved
                        amounts[index][colour] += moved
                        return moved
                    }
                }
            }
            return 0
        }
        for index in order {
            var left = windows[index].length
            while left > 0 {
                var visited = Set<Int>()
                let moved = assign(index, left, &visited)
                if moved == 0 { break }
                left -= moved
            }
        }
        var totals = targets.indices.map { colour in amounts.reduce(0) { $0 + $1[colour] } }
        var blocks = [FocusBlock]()
        for index in order {
            let slot = windows[index], assigned = amounts[index].reduce(0, +)
            for _ in 0..<max(0, slot.length - assigned) {
                let colour = eligible[index].reduce(eligible[index][0]) {
                    Double(totals[$1] + 1) / Double(max(1, targets[$1]))
                    < Double(totals[$0] + 1) / Double(max(1, targets[$0])) ? $1 : $0
                }
                amounts[index][colour] += 1; totals[colour] += 1
            }
            var start = slot.window.start
            for (colour, length) in amounts[index].enumerated() where length > 0 {
                blocks.append(FocusBlock(day: slot.day, start: start, end: start + length, colour: colour))
                start += length
            }
        }
        return blocks.sorted(by: blockOrder)
    }

    struct Moment: Equatable {
        let block: FocusBlock
        let seconds: Int
    }

    static func current(_ blocks: [FocusBlock], at date: Date, calendar: Calendar = .current) -> Moment? {
        let dayIndex = day(date, calendar: calendar), now = seconds(date, calendar: calendar)
        return blocks.first { $0.day == dayIndex && $0.start * 60 <= now && now < $0.end * 60 }
            .map { Moment(block: $0, seconds: $0.end * 60 - now) }
    }
}
