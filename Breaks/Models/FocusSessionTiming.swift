import Foundation

/// Wall-clock anchors keep a session accurate across delayed ticks, sleep and relaunch.
struct FocusSessionTiming: Codable {
    let id: UUID
    let startedAt: Date
    let targetSeconds: Int
    let allowsOvertime: Bool
    private(set) var accumulatedSeconds: TimeInterval = 0
    private(set) var resumedAt: Date?
    private(set) var lastActiveAt: Date
    var targetWasAnnounced = false

    init(startedAt: Date, targetSeconds: Int, allowsOvertime: Bool) {
        id = UUID()
        self.startedAt = startedAt
        self.targetSeconds = targetSeconds
        self.allowsOvertime = allowsOvertime
        resumedAt = startedAt
        lastActiveAt = startedAt
    }

    var isRunning: Bool { resumedAt != nil }

    var deadline: Date? {
        resumedAt?.addingTimeInterval(TimeInterval(targetSeconds) - accumulatedSeconds)
    }

    func elapsed(at date: Date) -> TimeInterval {
        accumulatedSeconds + (resumedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    func remaining(at date: Date) -> Int {
        Int(ceil(TimeInterval(targetSeconds) - elapsed(at: date)))
    }

    mutating func pause(at date: Date) {
        guard let resumedAt else { return }
        let end = max(resumedAt, date)
        accumulatedSeconds = elapsed(at: end)
        lastActiveAt = end
        self.resumedAt = nil
    }

    mutating func resume(at date: Date) {
        guard resumedAt == nil else { return }
        resumedAt = date
    }

    func completed(at date: Date) -> CompletedFocusSession {
        CompletedFocusSession(
            id: id,
            startedAt: startedAt,
            endedAt: isRunning ? max(startedAt, date) : lastActiveAt,
            durationSeconds: max(0, Int(elapsed(at: date).rounded(.down))),
            targetSeconds: targetSeconds
        )
    }
}

struct CompletedFocusSession {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Int
    let targetSeconds: Int

    var overtimeSeconds: Int { max(0, durationSeconds - targetSeconds) }
    var pausedSeconds: Int { max(0, Int(endedAt.timeIntervalSince(startedAt)) - durationSeconds) }
}

enum FocusDuration {
    static func text(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(remainder)s" }
        if remainder == 0 { return "\(minutes)m" }
        return "\(minutes)m \(remainder)s"
    }
}
