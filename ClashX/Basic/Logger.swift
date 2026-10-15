//
//  Logger.swift
//  ClashX
//
//  Created by CYC on 2018/8/7.
//  Copyright © 2018年 yichengchen. All rights reserved.
//

import CocoaLumberjackSwift
import Foundation

private class AppLogFileManager: DDLogFileManagerDefault {
    override var newLogFileName: String {
        "clashx.log"
    }

    override func isLogFile(withName fileName: String) -> Bool {
        fileName.range(of: #"^clashx\.log(\.\d+)?$"#, options: .regularExpression) != nil
    }
}

private class CoreLogFileManager: DDLogFileManagerDefault {
    override var newLogFileName: String {
        let df = DateFormatter()
        df.dateFormat = "dd_HH-mm-ss"
        return "clashx_core_\(df.string(from: Date())).log"
    }

    override func isLogFile(withName fileName: String) -> Bool {
        fileName.range(of: #"^clashx_core_\d{2}_\d{2}-\d{2}-\d{2}\.log(\.\d+)?$"#, options: .regularExpression) != nil
    }
}

class Logger {
    static let shared = Logger()
    var fileLogger: DDFileLogger = .init()
    var coreFileLogger: DDFileLogger = .init()
    private(set) var sessionId = ""
    
    private let coreLog = DDLog()
    private let logCleanupQueue = DispatchQueue(label: "com.clashx.log-cleanup", qos: .utility)
    private var logWriteSources: [DispatchSourceFileSystemObject] = []
    private var logCleanupTimer: DispatchSourceTimer?

    var coreLogPath: String {
        "\(logFolder())/\(kCoreLogName)"
    }

    var coreCrashLogPath: String {
        "\(logFolder())/\(kCoreCrashLogName)"
    }

    private init() {
        #if DEBUG
            DDLog.add(DDOSLogger.sharedInstance)
        #endif
        dynamicLogLevel = .debug
    }

    func configure(logDirectory: String, sessionId: String) {
        self.sessionId = sessionId
        let dateFormatter = DateFormatter()
        dateFormatter.setLocalizedDateFormatFromTemplate("YYYY/MM/dd HH:mm:ss:SSS")

        let fm = AppLogFileManager(logsDirectory: logDirectory)
        let newLogger = DDFileLogger(logFileManager: fm)
        newLogger.logFormatter = DDLogFileFormatterDefault(dateFormatter: dateFormatter)
        DDLog.remove(fileLogger)
        fileLogger = newLogger
        DDLog.add(newLogger)

        let coreFm = CoreLogFileManager(logsDirectory: logDirectory)
        let newCoreLogger = DDFileLogger(logFileManager: coreFm)
        newCoreLogger.logFormatter = DDLogFileFormatterDefault(dateFormatter: dateFormatter)
        newCoreLogger.rollingFrequency = TimeInterval(60 * 60 * 24) // 24 hours
        newCoreLogger.maximumFileSize = 5 * 1024 * 1024 // 5MB
        newCoreLogger.logFileManager.maximumNumberOfLogFiles = 3
        coreLog.removeAllLoggers()
        coreLog.add(newCoreLogger)
        coreFileLogger = newCoreLogger
    }

    private func logToLog(_ ddlog: DDLog, msg: String, level: ClashLogLevel) {
        switch level {
        case .debug, .silent:
            DDLogDebug(DDLogMessageFormat(stringLiteral: msg), ddlog: ddlog)
        case .error:
            DDLogError(DDLogMessageFormat(stringLiteral: msg), ddlog: ddlog)
        case .info:
            DDLogInfo(DDLogMessageFormat(stringLiteral: msg), ddlog: ddlog)
        case .warning:
            DDLogWarn(DDLogMessageFormat(stringLiteral: msg), ddlog: ddlog)
        case .unknow:
            DDLogWarn(DDLogMessageFormat(stringLiteral: msg), ddlog: ddlog)
        }
    }

    static func log(_ msg: String, level: ClashLogLevel = .info, file: String = #file, function: String = #function) {
		let fileName = URL(fileURLWithPath: file).lastPathComponent
        shared.logToLog(.sharedInstance, msg: "[\(level.rawValue)] \(fileName) \(function) \(msg)", level: level)
    }

    static func logCore(_ msg: String, level: ClashLogLevel) {
        shared.logToLog(shared.coreLog, msg: "[\(level.rawValue)] \(msg)", level: level)
    }

    func logFilePath() -> String {
        return fileLogger.logFileManager.sortedLogFilePaths.first ?? ""
    }

    func logFolder() -> String {
        return fileLogger.logFileManager.logsDirectory
    }

    func setupLogSession() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let sessionId = dateFormatter.string(from: Date())

        let logsDir = "\(kConfigFolderPath)logs/\(sessionId)"
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)

        configure(logDirectory: logsDir, sessionId: sessionId)

        FileManager.default.createFile(atPath: coreLogPath, contents: nil)
        FileManager.default.createFile(atPath: coreCrashLogPath, contents: nil)
        startCleanup()
        cleanupLogDirectories()
    }
    

    private func cleanupLogDirectories() {
        let logsRoot = "\(kConfigFolderPath)logs/"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: logsRoot) else { return }

        let maxCount = 10
        let sorted = contents
            .filter { $0.contains("-") }
            .sorted(by: >)

        guard sorted.count > maxCount else { return }

        for name in sorted[maxCount...] {
            try? FileManager.default.removeItem(atPath: "\(logsRoot)\(name)")
        }
    }
    
    
    private func startCleanup() {
        let paths = [coreLogPath, coreCrashLogPath]
        logCleanupQueue.sync {
            logWriteSources.forEach { $0.cancel() }
            logWriteSources.removeAll()
            logCleanupTimer?.cancel()

            for path in paths {
                let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
                guard descriptor >= 0 else {
                    Logger.log("Cannot watch core log writes; periodic cleanup remains enabled", level: .warning)
                    continue
                }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor, eventMask: [.write, .extend], queue: logCleanupQueue)
                source.setEventHandler {
                    try? Self.trimLog(atPath: path, maxSize: 1024 * 1024)
                }
                source.setCancelHandler { close(descriptor) }
                logWriteSources.append(source)
                source.resume()
            }

            // Fallback for missed/coalesced events. Both paths share the serial queue
            // so a timer and a write event never trim the same file concurrently.
            let timer = DispatchSource.makeTimerSource(queue: logCleanupQueue)
            timer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .seconds(1))
            timer.setEventHandler {
                for path in paths { try? Self.trimLog(atPath: path, maxSize: 1024 * 1024) }
            }
            logCleanupTimer = timer
            timer.resume()
        }
    }

    private static func trimLog(atPath path: String, maxSize: Int) throws {
        let url = URL(fileURLWithPath: path)
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > UInt64(maxSize) else { return }

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let currentSize = try handle.seekToEnd()
        guard currentSize > UInt64(maxSize) else { return }
        // Leave headroom rather than copying the whole tail on every subsequent write.
        // Keep the inode: launchd still holds the append descriptor for this file.
        let retainedSize = maxSize / 2
        try handle.seek(toOffset: currentSize - UInt64(retainedSize))
        var tail = try handle.read(upToCount: retainedSize) ?? Data()

        if let firstNewline = tail.firstIndex(of: 0x0A) {
            tail.removeSubrange(0...firstNewline)
        }

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: tail)
        try handle.truncate(atOffset: UInt64(tail.count))
    }
}
