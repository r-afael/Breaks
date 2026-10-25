import Foundation
import EventKit

private struct CheckFailed: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                    file: StaticString = #filePath, line: UInt = #line) throws {
    if !condition() { throw CheckFailed(description: "\(file):\(line): \(message)") }
}

@MainActor
private final class Fixture {
    let suite = "Breaks.OvertimeTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let start = Date()
    var date: Date
    var timer: BreakTimer!

    init(overtime: Bool = true, autoCycle: Bool = true) {
        date = start
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(20, forKey: "workMinutes")
        defaults.set(overtime, forKey: "overtimeEnabled")
        defaults.set(autoCycle, forKey: "autoCycle")
        defaults.set(false, forKey: "idleDetectionEnabled")
        reload()
        timer.journal.startDay(with: "Study")
    }

    func reload() {
        timer = BreakTimer(defaults: defaults, now: { [unowned self] in self.date },
                           systemIntegrationEnabled: false)
    }

    func advance(_ seconds: TimeInterval) {
        date = date.addingTimeInterval(seconds)
        timer.tick()
    }

    func clean() { defaults.removePersistentDomain(forName: suite) }
}

@main
struct OvertimeTests {
    @MainActor
    static func main() throws {
        var passed = 0
        func test(_ name: String, _ body: (Fixture) throws -> Void) throws {
            let f = Fixture()
            defer { f.clean() }
            try body(f)
            passed += 1
            print("PASS \(name)")
            fflush(stdout)
        }

        try test("20 minutes plus seven minutes saves one 27-minute session") { f in
            f.timer.start()
            f.advance(20 * 60)
            try expect(f.timer.isRunning && f.timer.isOvertime, "Must continue at zero")
            try expect(f.timer.formatted(f.timer.clock.remaining) == "+00:00", "Zero overtime display")
            try expect(f.timer.history.totalToday() == 0, "Do not log at target")
            try expect(f.timer.journal.blockLogs.isEmpty, "Do not save a partial session at target")
            f.advance(7 * 60)
            try expect(f.timer.formatted(f.timer.clock.remaining) == "+07:00", "Overtime display")
            f.timer.finishFocus()
            try expect(!f.timer.isRunning, "Finish must stop")
            try expect(f.timer.journal.blockLogs.count == 1, "One journal entry")
            let block = f.timer.journal.blockLogs[0]
            try expect(block.actualSeconds == 27 * 60, "Actual duration includes overtime")
            try expect(block.overtimeSeconds == 7 * 60, "Overtime is retained")
            try expect(block.label == "Study", "Label is retained")
            try expect(block.startedAt == f.start && block.date == f.date, "Actual timestamps")
            try expect(f.timer.history.totalToday() == 1, "One completion")
        }
        try test("pause and resume exclude pauses before and after zero") { f in
            f.timer.start()
            f.advance(600)
            f.timer.pause()
            f.advance(300)
            f.timer.start()
            f.advance(720)
            try expect(f.timer.clock.remaining == -120, "22 active minutes")
            f.timer.pause()
            f.advance(600)
            try expect(f.timer.clock.remaining == -120, "Paused overtime must not grow")
            try expect(f.timer.canStart, "Negative timer can resume")
            f.timer.start()
            f.advance(60)
            f.timer.finishFocus()
            try expect(f.timer.journal.blockLogs[0].actualSeconds == 1380, "23 active minutes")
        }
        try test("a pause exactly at zero can resume") { f in
            f.timer.start()
            f.advance(1200)
            f.timer.pause()
            try expect(f.timer.canStart, "Zero is a valid paused overtime state")
            f.advance(60)
            f.timer.start()
            f.advance(60)
            f.timer.finishFocus()
            try expect(f.timer.journal.blockLogs[0].actualSeconds == 1260, "21 active minutes")
        }
        try test("running overtime survives relaunch") { f in
            f.timer.start()
            f.advance(1320)
            f.date = f.date.addingTimeInterval(180)
            f.reload()
            try expect(f.timer.isRunning && f.timer.isOvertime, "Restore running overtime")
            try expect(f.timer.clock.remaining == -300, "Account for time while closed")
            f.timer.finishFocus()
            try expect(f.timer.journal.blockLogs[0].actualSeconds == 1500, "25 minutes persisted")
        }
        try test("paused overtime survives relaunch without counting closed time") { f in
            f.timer.start()
            f.advance(1320)
            f.timer.pause()
            f.date = f.date.addingTimeInterval(600)
            f.reload()
            try expect(!f.timer.isRunning && f.timer.isOvertime, "Restore paused overtime")
            try expect(f.timer.remaining == -120, "Paused duration survives")
            f.timer.start()
            f.advance(60)
            f.timer.finishFocus()
            try expect(f.timer.journal.blockLogs[0].actualSeconds == 1380, "23 active minutes")
        }
        try test("sleep crossing the target continues overtime") { f in
            f.timer.start()
            f.advance(600)
            f.timer.handleSleep()
            f.date = f.date.addingTimeInterval(900)
            f.timer.handleWake()
            try expect(f.timer.isRunning && f.timer.isOvertime, "Wake into overtime")
            try expect(f.timer.clock.remaining == -300, "Sleep elapsed is included")
        }
        try test("finish before target saves exact seconds") { f in
            f.timer.start()
            f.advance(95)
            f.timer.finishFocus()
            try expect(f.timer.journal.blockLogs[0].actualSeconds == 95, "Early finish is recorded")
            try expect(f.timer.journal.blockLogs[0].durationText == "1m 35s", "Second precision visible")
        }
        try test("finish while paused excludes the trailing pause") { f in
            f.timer.start()
            f.advance(1320)
            f.timer.pause()
            let end = f.date
            f.advance(600)
            f.timer.finishFocus()
            let block = f.timer.journal.blockLogs[0]
            try expect(block.actualSeconds == 1320 && block.date == end, "End at last active instant")
        }
        try test("repeated ticks and finish cannot duplicate completion") { f in
            f.timer.start()
            f.advance(1500)
            for _ in 0..<5 { f.timer.tick() }
            f.timer.finishFocus()
            f.timer.finishFocus()
            f.timer.tick()
            try expect(f.timer.journal.blockLogs.count == 1, "No duplicate journal entry")
            try expect(f.timer.completedWorkSessions == 1, "No duplicate count")
            f.reload()
            try expect(!f.timer.hasActiveWorkSession, "Completed timer stays completed after relaunch")
        }
        try test("journal is saved without answering reflection") { f in
            f.timer.start()
            f.advance(1500)
            f.timer.finishFocus()
            f.reload()
            try expect(f.timer.journal.blockLogs.count == 1, "Journal persists immediately")
            try expect(f.timer.journal.pendingBlock != nil, "Reflection persists")
            f.timer.resolvePendingBlock(as: .messy)
            try expect(f.timer.journal.blockLogs.count == 1, "Reflection updates rather than appends")
            try expect(f.timer.journal.blockLogs[0].outcome == .messy, "Outcome is updated")
        }
        try test("settings changes do not rewrite an active session") { f in
            f.timer.start()
            f.advance(900)
            f.timer.pause()
            f.timer.settings.workMinutes = 5
            f.timer.settings.overtimeEnabled = false
            f.reload()
            try expect(f.timer.duration == 1200, "Original target persists")
            f.timer.start()
            f.advance(600)
            try expect(f.timer.isOvertime && f.timer.isRunning, "Original overtime policy persists")
        }
        try test("reset discards active overtime") { f in
            f.timer.start()
            f.advance(1500)
            f.timer.reset()
            f.reload()
            try expect(!f.timer.hasActiveWorkSession && !f.timer.isOvertime, "Discarded state stays clear")
            try expect(f.timer.journal.blockLogs.isEmpty, "Discard does not log")
        }
        try test("skip hotkey saves active work") { f in
            f.timer.start()
            f.advance(1500)
            f.timer.skip()
            try expect(f.timer.journal.blockLogs[0].actualSeconds == 1500, "Skip preserves overtime")
            try expect(f.timer.mode == .shortBreak && !f.timer.isRunning, "Break ready")
        }
        try test("mode switch saves active work") { f in
            f.timer.start()
            f.advance(1500)
            f.timer.setMode(.longBreak)
            try expect(f.timer.journal.blockLogs[0].actualSeconds == 1500, "Mode switch preserves work")
            try expect(f.timer.mode == .longBreak, "Requested mode")
        }
        try test("overtime disabled preserves automatic cycling") { f in
            f.timer.settings.overtimeEnabled = false
            f.timer.start()
            f.advance(1500)
            try expect(f.timer.mode == .shortBreak && f.timer.isRunning, "Automatic break")
            try expect(f.timer.journal.blockLogs[0].actualSeconds == 1200, "Only configured duration")
            try expect(f.timer.journal.blockLogs[0].date == f.start.addingTimeInterval(1200), "Deadline, not late tick")
        }
        try test("breaks still stop at zero without auto-cycle") { f in
            f.timer.settings.autoCycle = false
            f.timer.setMode(.shortBreak)
            f.timer.start()
            f.advance(600)
            try expect(!f.timer.isRunning && f.timer.remaining == 0, "Break ends")
            try expect(!f.timer.isOvertime, "Breaks do not enter overtime")
        }
        try test("target alarm state survives relaunch") { f in
            f.timer.start()
            f.advance(1200)
            try expect(f.timer.focusSession?.targetWasAnnounced == true, "Mark target announced once")
            f.reload()
            try expect(f.timer.focusSession?.targetWasAnnounced == true, "Do not repeat target alarm")
        }
        try test("legacy journal entries still decode") { _ in
            let json = """
            {"id":"00000000-0000-0000-0000-000000000001","date":0,"label":"Old work","minutes":25,"outcome":"Good"}
            """
            let old = try JSONDecoder().decode(FocusBlockLog.self, from: Data(json.utf8))
            try expect(old.actualSeconds == 1500 && old.durationText == "25m", "Legacy minute duration")
        }
        try test("legacy running timer crossing zero is migrated") { f in
            f.defaults.set("Work", forKey: TimerStorageKey.mode)
            f.defaults.set(true, forKey: TimerStorageKey.isRunning)
            f.defaults.set(f.date.addingTimeInterval(-300), forKey: TimerStorageKey.endDate)
            f.reload()
            try expect(f.timer.isRunning && f.timer.clock.remaining == -300, "Legacy timer remains live")
            f.timer.finishFocus()
            try expect(f.timer.journal.blockLogs[0].actualSeconds == 1500, "Legacy overtime retained")
        }
        try test("calendar payload has real timestamps and actual focus duration") { f in
            var timing = FocusSessionTiming(startedAt: f.start, targetSeconds: 1200, allowsOvertime: true)
            timing.pause(at: f.start.addingTimeInterval(600))
            timing.resume(at: f.start.addingTimeInterval(900))
            let session = timing.completed(at: f.start.addingTimeInterval(1920))
            let store = EKEventStore()
            let event = EKEvent(eventStore: store)
            f.timer.calendarExporter.configure(event, title: "Study", session: session)
            try expect(event.title == "Study", "Calendar label")
            try expect(abs(event.startDate.timeIntervalSince(f.start)) < 1, "Original start time")
            try expect(abs(event.endDate.timeIntervalSince(f.start) - 1920) < 1, "Actual finish time")
            try expect(event.notes?.contains("Focused: 27m") == true, "Calendar active duration")
            try expect(event.notes?.contains("Overtime: 7m") == true, "Calendar overtime")
            try expect(event.notes?.contains("Paused: 5m") == true, "Calendar pause duration")
        }
        try test("history older than thirty days is preserved") { f in
            let oldDate = f.start.addingTimeInterval(-60 * 86400)
            let old = FocusSessionTiming(startedAt: oldDate, targetSeconds: 1200, allowsOvertime: true)
            f.timer.journal.recordCompletedWork(session: old.completed(at: oldDate.addingTimeInterval(1500)))
            f.reload()
            try expect(f.timer.journal.blockLogs.count == 1, "Do not prune the session log")
        }
        try test("pause after a delayed tick caps sessions with overtime disabled") { f in
            f.timer.settings.overtimeEnabled = false
            f.timer.start()
            f.date = f.date.addingTimeInterval(1500)
            f.timer.pause()
            try expect(!f.timer.hasActiveWorkSession, "Complete expired countdown")
            try expect(f.timer.journal.blockLogs[0].actualSeconds == 1200, "No accidental overtime")
        }
        try test("restoring a stale completed timer does not duplicate history") { f in
            f.timer.start()
            f.advance(1500)
            let stale = f.defaults.data(forKey: TimerStorageKey.focusSession)!
            f.timer.finishFocus()
            f.defaults.set(stale, forKey: TimerStorageKey.focusSession)
            f.defaults.set("Work", forKey: TimerStorageKey.mode)
            f.reload()
            f.timer.finishFocus()
            try expect(f.timer.journal.blockLogs.count == 1, "No duplicate journal after interruption")
            try expect(f.timer.history.totalToday() == 1, "No duplicate daily count")
        }
        try test("daily totals older than 120 days remain available") { f in
            let old = f.start.addingTimeInterval(-180 * 86400)
            f.timer.history.addCompletion(on: old)
            f.reload()
            try expect(f.timer.history.completions(on: old) == 1, "Preserve old totals")
        }
        print("\(passed) regression checks passed. No calendar events were saved.")
    }
}
