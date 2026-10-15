import Foundation

actor LogRateLimiter {
    private let maxLogsCount = 20000
    private let timeDuration: TimeInterval = 5
    private var logCount = 0
    private var windowStart = ProcessInfo.processInfo.systemUptime
    private var blockedUntil: TimeInterval = 0
    private let onRateLimitTriggered: @MainActor @Sendable () -> Void

    init(onRateLimitTriggered: @escaping @MainActor @Sendable () -> Void) {
        self.onRateLimitTriggered = onRateLimitTriggered
    }

    func reset() {
        logCount = 0
        windowStart = ProcessInfo.processInfo.systemUptime
        blockedUntil = 0
    }

    func processLog() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= blockedUntil else { return false }
        if blockedUntil > 0 {
            reset()
            Logger.log("Log reception resumed after rate limiting")
        }
        if now - windowStart >= timeDuration {
            windowStart = now
            logCount = 0
        }
        guard logCount < maxLogsCount else {
            // Set the deadline before scheduling UI work; no modal dialog or timer task.
            blockedUntil = now + 60
            Logger.log("Log rate limit reached: 20000 messages in 5 seconds; pausing reception for 60 seconds", level: .warning)
            let callback = onRateLimitTriggered
            Task { @MainActor in callback() }
            return false
        }
        logCount += 1
        return true
    }
}
