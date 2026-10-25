//
//  BreakTimer.swift
//  Breaks
//
//  Core timer controller: mode cycling, idle detection, sleep/wake, notifications.
//

import SwiftUI
import Combine
import UserNotifications
import AppKit

// MARK: - Idle Prompt

struct IdlePrompt: Identifiable {
    let id = UUID()
    let idleSeconds: TimeInterval
}

// MARK: - Tick Clock

// `TimerStorageKey` lives in `SharedStorage.swift` so the widget extension
// can read the same keys.

@MainActor
final class TickClock: ObservableObject {
    @Published var remaining: Int = 0
}

// MARK: - Timer Logic

final class BreakTimer: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case work = "Work"
        case shortBreak = "Short Break"
        case longBreak = "Long Break"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .work: return "brain.head.profile"
            case .shortBreak: return "cup.and.saucer"
            case .longBreak: return "leaf"
            }
        }
        var shortLabel: String {
            switch self {
            case .work: return "Focus"
            case .shortBreak: return "Short"
            case .longBreak: return "Long"
            }
        }
    }

    let settings: TimerSettings
    let history: SessionHistory
    let journal: FocusJournal
    let clock = TickClock()
    let suggestions = BreakSuggestionLibrary()
    let calendarExporter = CalendarExporter()
    let projects: FocusProjectLibrary

    @Published private(set) var mode: Mode
    @Published private(set) var duration: Int
    /// Action-boundary updates only; per-second values go through TickClock.
    @Published private(set) var remaining: Int {
        didSet { clock.remaining = remaining }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var isOvertime = false
    @Published private(set) var completedWorkSessions: Int
    @Published private(set) var focusSession: FocusSessionTiming?
    @Published var idlePrompt: IdlePrompt?

    private let defaults: UserDefaults
    private let now: () -> Date
    private let systemIntegrationEnabled: Bool
    private var ticker: Timer?
    private var endDate: Date?
    private var permissionRequested = false
    private var bag = Set<AnyCancellable>()
    var flowMode: Bool { settings.flowMode }
    var hasActiveWorkSession: Bool { focusSession != nil }
    var canStart: Bool { !isRunning && (hasActiveWorkSession || remaining > 0) }

    init(defaults: UserDefaults = .shared,
         now: @escaping () -> Date = Date.init,
         systemIntegrationEnabled: Bool = true) {
        self.defaults = defaults
        self.now = now
        self.systemIntegrationEnabled = systemIntegrationEnabled
        let s = TimerSettings(defaults: defaults)
        settings = s
        history = SessionHistory(defaults: defaults)
        journal = FocusJournal(defaults: defaults)
        projects = FocusProjectLibrary(defaults: defaults)
        let restoredMode = Mode(rawValue: defaults.string(forKey: TimerStorageKey.mode) ?? s.lastMode) ?? .work
        let restoredDuration = s.minutes(for: restoredMode) * 60
        mode = restoredMode
        duration = restoredDuration
        remaining = restoredDuration
        completedWorkSessions = defaults.integer(forKey: TimerStorageKey.completedWorkSessions)
        journal.projectLibrary = projects
        restoreTimerState()

        if systemIntegrationEnabled {
            if s.hasCompletedOnboarding {
                Task { await requestPermissionIfNeeded() }
            }
            let ws = NSWorkspace.shared.notificationCenter
            ws.addObserver(self, selector: #selector(handleSleep),
                           name: NSWorkspace.willSleepNotification, object: nil)
            ws.addObserver(self, selector: #selector(handleWake),
                           name: NSWorkspace.didWakeNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(saveStateOnQuit),
                                                   name: NSApplication.willTerminateNotification, object: nil)
        }
        s.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async { self?.refreshIdleDuration() }
            }
            .store(in: &bag)
    }

    deinit {
        ticker?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Display
    var menuIcon: String { isOvertime ? "timer" : (isRunning ? mode.icon : "timer") }

    func menuBarTitle(for current: Int) -> String? {
        guard isRunning || hasActiveWorkSession || current != duration else { return nil }
        return formatted(current)
    }

    func formatted(_ seconds: Int) -> String {
        let value = abs(seconds)
        let prefix = seconds < 0 || (seconds == 0 && isOvertime) ? "+" : ""
        return prefix + String(format: "%02d:%02d", value / 60, value % 60)
    }

    // MARK: Actions
    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        if hasActiveWorkSession { finishFocus() }
        stopTicker()
        self.mode = mode
        settings.lastMode = mode.rawValue
        duration = settings.minutes(for: mode) * 60
        remaining = duration
        isOvertime = false
        idlePrompt = nil
        persistTimerState()
    }

    func start() {
        guard canStart else { return }
        let date = now()
        if journal.needsCheckIn { journal.startDay(with: "Focus") }
        idlePrompt = nil
        if mode == .work {
            if focusSession == nil {
                // Capture settings for this session so editing preferences cannot
                // change its target or end it unexpectedly while paused.
                focusSession = FocusSessionTiming(startedAt: date,
                                                  targetSeconds: duration,
                                                  allowsOvertime: settings.overtimeEnabled)
            } else {
                focusSession?.resume(at: date)
            }
            endDate = focusSession?.deadline
        } else {
            endDate = date.addingTimeInterval(TimeInterval(remaining))
        }
        isRunning = true
        scheduleTicker()
        persistTimerState()
    }

    func pause() {
        guard isRunning else { return }
        let date = now()
        if let session = focusSession, !session.allowsOvertime,
           let deadline = session.deadline, date >= deadline {
            completeFocus(session.completed(at: deadline))
            return
        }
        if focusSession != nil {
            focusSession?.pause(at: date)
            updateFocusDisplay(at: date)
        } else {
            syncRemaining()
        }
        stopTicker()
        persistTimerState()
    }

    /// Save once, including overtime, and leave the break ready to start.
    func finishFocus() {
        guard let session = focusSession else { return }
        let date = now()
        let finish = !session.allowsOvertime ? min(date, session.deadline ?? date) : date
        completeFocus(session.completed(at: finish))
        advanceMode()
    }

    func reset() {
        stopTicker()
        focusSession = nil
        isOvertime = false
        idlePrompt = nil
        duration = settings.minutes(for: mode) * 60
        remaining = duration
        persistTimerState()
    }

    func skip() {
        if hasActiveWorkSession {
            finishFocus()
            return
        }
        let wasRunning = isRunning
        stopTicker()
        advanceMode()
        if wasRunning { start() }
    }

    func resetCycle() {
        reset()
        completedWorkSessions = 0
        setMode(.work)
        persistTimerState()
    }

    func resetToday() {
        resetCycle()
        history.clearToday()
        journal.resetToday()
    }

    func resolvePendingBlock(as outcome: FocusOutcome) {
        if outcome == .skipped, let block = journal.pendingBlock {
            history.removeCompletion(on: block.date)
            completedWorkSessions = max(0, completedWorkSessions - 1)
            journal.resolvePendingBlock(as: outcome, keepLog: false)
        } else {
            journal.resolvePendingBlock(as: outcome)
        }
        persistTimerState()
    }

    func resumeAfterIdle() {
        idlePrompt = nil
        start()
    }

    func resetAfterIdle() {
        reset()
    }

    // MARK: Internals
    private func refreshIdleDuration() {
        guard !isRunning, !hasActiveWorkSession else { return }
        let new = settings.minutes(for: mode) * 60
        if duration != new {
            duration = new
            remaining = new
            persistTimerState()
        }
    }

    private func syncRemaining() {
        if focusSession != nil {
            updateFocusDisplay(at: now())
        } else if let endDate {
            remaining = max(0, Int(ceil(endDate.timeIntervalSince(now()))))
        }
    }

    private func updateFocusDisplay(at date: Date) {
        guard let session = focusSession else { return }
        remaining = session.remaining(at: date)
        isOvertime = session.allowsOvertime && session.elapsed(at: date) >= Double(session.targetSeconds)
    }

    private func scheduleTicker() {
        guard systemIntegrationEnabled else { return }
        ticker?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        t.tolerance = 0.15
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        isRunning = false
        ticker?.invalidate()
        ticker = nil
        endDate = nil
    }

    func tick() {
        guard isRunning else { return }
        let date = now()
        if systemIntegrationEnabled { detectIdleIfNeeded(at: date) }
        guard isRunning else { return }
        if let session = focusSession {
            let seconds = session.remaining(at: date)
            clock.remaining = seconds
            guard session.elapsed(at: date) >= Double(session.targetSeconds) else { return }
            if session.allowsOvertime {
                if !isOvertime { isOvertime = true }
                if !session.targetWasAnnounced {
                    focusSession?.targetWasAnnounced = true
                    playSound()
                    postNotification(for: .work, overtime: true)
                    persistTimerState()
                }
            } else {
                let completed = session.completed(at: session.deadline ?? date)
                playSound()
                postNotification(for: .work)
                completeFocus(completed)
                if settings.autoCycle {
                    advanceMode()
                    start()
                }
            }
        } else if let endDate {
            clock.remaining = max(0, Int(ceil(endDate.timeIntervalSince(date))))
            if date >= endDate { finishBreak() }
        }
    }

    private func detectIdleIfNeeded(at date: Date) {
        guard settings.idleDetectionEnabled,
              idlePrompt == nil,
              let session = focusSession,
              let resumedAt = session.resumedAt else { return }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idleSeconds >= TimeInterval(settings.idleThresholdMinutes * 60) else { return }
        focusSession?.pause(at: max(resumedAt, date.addingTimeInterval(-idleSeconds)))
        updateFocusDisplay(at: date)
        stopTicker()
        idlePrompt = IdlePrompt(idleSeconds: idleSeconds)
        persistTimerState()
    }

    private func completeFocus(_ completed: CompletedFocusSession) {
        stopTicker()
        focusSession = nil
        remaining = 0
        isOvertime = false
        idlePrompt = nil
        if completed.durationSeconds > 0,
           !journal.blockLogs.contains(where: { $0.id == completed.id }) {
            completedWorkSessions += 1
            history.addCompletion(on: completed.endedAt)
            journal.recordCompletedWork(session: completed)
            if settings.calendarExportEnabled && systemIntegrationEnabled {
                calendarExporter.exportCompletedSession(
                    title: journal.effectiveBlockLabel,
                    session: completed,
                    calendarIdentifier: settings.calendarExportIdentifier.isEmpty ? nil : settings.calendarExportIdentifier
                )
            }
        }
        persistTimerState()
    }

    private func finishBreak() {
        let finished = mode
        stopTicker()
        remaining = 0
        playSound()
        postNotification(for: finished)
        if finished == .longBreak { completedWorkSessions = 0 }
        if settings.autoCycle {
            advanceMode()
            start()
        } else {
            persistTimerState()
        }
    }

    private func advanceMode() {
        switch mode {
        case .work:
            mode = completedWorkSessions > 0 && completedWorkSessions % settings.sessionsPerCycle == 0
                ? .longBreak : .shortBreak
        case .shortBreak, .longBreak:
            mode = .work
        }
        settings.lastMode = mode.rawValue
        duration = settings.minutes(for: mode) * 60
        remaining = duration
        isOvertime = false
        persistTimerState()
    }

    @objc func handleSleep() {
        ticker?.invalidate()
        ticker = nil
        persistTimerState()
    }

    @objc func handleWake() {
        guard isRunning else { return }
        tick()
        if isRunning { scheduleTicker() }
        persistTimerState()
    }

    @objc private func saveStateOnQuit() {
        syncRemaining()
        persistTimerState()
    }

    private func persistTimerState() {
        defaults.set(mode.rawValue, forKey: TimerStorageKey.mode)
        defaults.set(remaining, forKey: TimerStorageKey.remaining)
        defaults.set(isRunning, forKey: TimerStorageKey.isRunning)
        defaults.set(completedWorkSessions, forKey: TimerStorageKey.completedWorkSessions)
        if let session = focusSession, let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: TimerStorageKey.focusSession)
        } else {
            defaults.removeObject(forKey: TimerStorageKey.focusSession)
        }
        if isRunning, let endDate {
            defaults.set(endDate, forKey: TimerStorageKey.endDate)
        } else {
            defaults.removeObject(forKey: TimerStorageKey.endDate)
        }
    }

    private func restoreTimerState() {
        let date = now()
        if mode == .work,
           let data = defaults.data(forKey: TimerStorageKey.focusSession),
           let session = try? JSONDecoder().decode(FocusSessionTiming.self, from: data) {
            focusSession = session
            duration = session.targetSeconds
            isRunning = session.isRunning
            endDate = session.deadline
            updateFocusDisplay(at: date)
        } else if let savedEnd = defaults.object(forKey: TimerStorageKey.endDate) as? Date,
                  defaults.bool(forKey: TimerStorageKey.isRunning) {
            isRunning = true
            endDate = savedEnd
            if mode == .work {
                focusSession = FocusSessionTiming(startedAt: savedEnd.addingTimeInterval(-Double(duration)),
                                                  targetSeconds: duration,
                                                  allowsOvertime: settings.overtimeEnabled)
                updateFocusDisplay(at: date)
            } else {
                remaining = max(0, Int(ceil(savedEnd.timeIntervalSince(date))))
            }
        } else if let saved = defaults.object(forKey: TimerStorageKey.remaining) as? Int,
                  saved >= 0, saved <= duration {
            remaining = saved
            if mode == .work, saved > 0, saved < duration {
                var session = FocusSessionTiming(startedAt: date.addingTimeInterval(-Double(duration - saved)),
                                                 targetSeconds: duration,
                                                 allowsOvertime: settings.overtimeEnabled)
                session.pause(at: date)
                focusSession = session
            }
        }
        clock.remaining = remaining
        if isRunning {
            tick()
            if isRunning { scheduleTicker() }
        }
    }

    // MARK: Notifications + Sound
    private func requestPermissionIfNeeded() async {
        guard !permissionRequested else { return }
        permissionRequested = true
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    private func postNotification(for mode: Mode, overtime: Bool = false) {
        guard systemIntegrationEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = overtime ? "Focus target reached" : "\(mode.rawValue) finished"
        content.body = overtime ? "Overtime is being tracked. Finish when you are ready."
            : (mode == .work ? "Time for a break." : "Back to focus.")
        content.sound = .default
        content.threadIdentifier = "breaks.timer"
        let identifier = "breaks.timer.\(mode.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))"
        let req = UNNotificationRequest(identifier: identifier,
                                        content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(req)
    }

    private func playSound() {
        guard systemIntegrationEnabled else { return }
        guard let sound = NSSound(named: NSSound.Name(settings.soundName)) else { return }
        sound.volume = Float(settings.volume)
        sound.play()
    }
}
