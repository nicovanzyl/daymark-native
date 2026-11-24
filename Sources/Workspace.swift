import Foundation
import SwiftUI

enum Stage: String, Codable, CaseIterable, Identifiable {
    case now = "Now", next = "Next", later = "Later"
    var id: String { rawValue }

    func shifted(_ offset: Int) -> Stage {
        let index = Self.allCases.firstIndex(of: self) ?? 0
        return Self.allCases[min(Self.allCases.count - 1, max(0, index + offset))]
    }
}

struct Task: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var colour: Int
    var stage: Stage
    var completedOn: String? = nil
}

struct KeyboardTaskMove { let id: UUID; var destination: Stage }

struct Workspace: Codable, Equatable {
    var settings = Settings()
    var tasks = [Task]()

    var needsSetup: Bool { tasks.isEmpty && !settings.onboardingComplete }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var workspace: Workspace
    @Published private(set) var blocks: [FocusBlock]
    @Published private(set) var error: String?
    let url: URL

    nonisolated static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Daymark Native", isDirectory: true)
            .appendingPathComponent("workspace.json")
    }

    init(url: URL = WorkspaceStore.defaultURL()) {
        self.url = url
        var value = Workspace()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                value = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url))
                guard (1...6).contains(value.settings.labels.count),
                      Schedule.valid(value.settings.work, count: value.settings.labels.count) != nil,
                      value.tasks.allSatisfy({ $0.colour >= 0 })
                else { throw CocoaError(.fileReadCorruptFile) }
            } catch {
                value = Workspace()
                self.error = "Could not read the saved workspace. Changes are disabled to protect the original file."
            }
        }
        workspace = value
        blocks = Schedule.buildWeek(value.settings.work, count: value.settings.labels.count, shares: value.settings.shares)
    }

    func canEnterNow(excluding id: UUID? = nil) -> Bool {
        workspace.tasks.filter { $0.id != id && $0.stage == .now && $0.completedOn == nil }.count < 3
    }

    func label(_ colour: Int) -> String {
        let index = min(max(0, colour), workspace.settings.labels.count - 1)
        let name = workspace.settings.labels[index]
        return name.isEmpty ? Schedule.defaults[index] : name
    }

    private func apply(_ change: (inout Workspace) -> Void) -> Bool {
        if error?.hasPrefix("Could not read") == true { return false }
        var next = workspace
        change(&next)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(next).write(to: url, options: [.atomic])
            let current = workspace.settings
            let updated = next.settings
            if current.work != updated.work || current.shares != updated.shares || current.labels.count != updated.labels.count {
                blocks = Schedule.buildWeek(next.settings.work, count: next.settings.labels.count, shares: next.settings.shares)
            }
            workspace = next
            error = nil
            return true
        } catch {
            self.error = "Could not save changes. Check that Daymark’s workspace is writable."
            return false
        }
    }

    // Category edits take effect immediately. Work-hour edits have their own Save/Cancel boundary.
    func updateCategories(labels: [String], shares: [Double], coloursFrom previous: [Int?]) -> Bool {
        guard (1...6).contains(labels.count), previous.count == labels.count else { return false }
        var settings = workspace.settings
        settings.labels = labels
        settings.shares = shares
        if previous != workspace.settings.labels.indices.map(Optional.some) {
            settings.work = settings.work.map { day in
                day.map { window in
                    var updated = window
                    updated.allowed = Schedule.remapped(window.allowed, coloursFrom: previous)
                    return updated
                }
            }
        }
        return save(settings, coloursFrom: previous, completeSetup: false)
    }

    func save(_ settings: Settings, coloursFrom original: [Int?], completeSetup: Bool = true) -> Bool {
        guard let work = Schedule.valid(settings.work, count: settings.labels.count) else { return false }
        var normalized = settings
        normalized.work = work
        if completeSetup { normalized.onboardingComplete = true }
        return apply { next in
            next.settings = normalized
            next.tasks = next.tasks.map { old in
                var task = old
                task.colour = original.firstIndex { $0 == old.colour } ?? 0
                return task
            }
        }
    }

    func add(_ text: String, colour: Int, stage: Stage) -> Bool {
        let title = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        guard !title.isEmpty, workspace.settings.labels.indices.contains(colour),
              stage != .now || canEnterNow() else { return false }
        return apply { $0.tasks.append(Task(title: title, colour: colour, stage: stage)) }
    }

    func move(_ id: UUID, _ stage: Stage) -> Bool {
        guard let index = workspace.tasks.firstIndex(where: { $0.id == id }),
              workspace.tasks[index].completedOn == nil, stage != .now || canEnterNow(excluding: id)
        else { return false }
        return apply { $0.tasks[index].stage = stage }
    }

    func toggle(_ id: UUID, at now: Date) -> Bool {
        guard let index = workspace.tasks.firstIndex(where: { $0.id == id }) else { return false }
        if workspace.tasks[index].completedOn != nil, workspace.tasks[index].stage == .now, !canEnterNow(excluding: id) { return false }
        return apply { $0.tasks[index].completedOn = $0.tasks[index].completedOn == nil ? Schedule.dateKey(now) : nil }
    }

    func edit(_ id: UUID, title: String, colour: Int) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, workspace.settings.labels.indices.contains(colour),
              let index = workspace.tasks.firstIndex(where: { $0.id == id }) else { return false }
        return apply { $0.tasks[index].title = trimmed; $0.tasks[index].colour = colour }
    }

    func delete(_ id: UUID) -> Bool { apply { $0.tasks.removeAll { $0.id == id } } }

    func visible(on day: String, today: String, colour: Int?) -> [Task] {
        workspace.tasks.filter {
            ($0.completedOn == day || ($0.completedOn == nil && day >= today))
              && (colour == nil || min($0.colour, workspace.settings.labels.count - 1) == colour)
        }
    }
}
