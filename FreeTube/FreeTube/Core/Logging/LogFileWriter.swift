import Foundation
import Observation
import OSLog
import UIKit

/// Optional direct file mirror of `AppLog` output. Direct mirroring avoids the deferred unified-log
/// interpolation payloads that sometimes appear as `<compose failure […]>` when read via OSLogStore.
@available(iOS 17.0, *)
@Observable
@MainActor
final class LogFileWriter {
    static let shared = LogFileWriter()

    private(set) var isEnabled: Bool
    private(set) var currentLogFileURL: URL?

    @ObservationIgnored private var fileHandle: FileHandle?
    @ObservationIgnored private let preferences = UserPreferences()
    @ObservationIgnored private let systemLog = Logger(
        subsystem: "com.leshko.freetube",
        category: "LogFileWriter"
    )

    nonisolated static let subsystem = "com.leshko.freetube"

    private init() {
        Self.migrateLegacyLogs()
        isEnabled = UserPreferences().logToFile
        if isEnabled { start() }
    }

    // MARK: - Direct mirror

    nonisolated static func record(category: String, level: String, message: String) {
        // Avoid allocating a Task for every ordinary app log when file diagnostics are off.
        guard UserDefaults.standard.bool(forKey: "logToFile") else { return }
        Task { @MainActor in
            shared.append(category: category, level: level, message: message)
        }
    }

    private func append(category: String, level: String, message: String) {
        guard isEnabled, let fileHandle else { return }
        let timestamp = Self.isoTimestampFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            systemLog.error("failed to append diagnostic log: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Public

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        preferences.logToFile = enabled
        enabled ? start() : stop()
    }

    nonisolated static func allLogFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: logsDirectory(),
            includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// `Library/Application Support/Logs`. Earlier builds wrote to `Documents/Logs`, which
    /// `UIFileSharingEnabled` exposes to Finder / the Files app and which is part of device
    /// backups — the wrong place for request traces. Logs remain shareable on demand through
    /// the Settings share sheet. `migrateLegacyLogs()` removes the old folder once.
    nonisolated static func logsDirectory() -> URL {
        SecurityHardening.diagnosticsDirectory
    }

    /// Deletes `Documents/Logs` left behind by builds that logged into the shared folder.
    nonisolated static func migrateLegacyLogs() {
        let legacy = AppDirectories.documents.appendingPathComponent("Logs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        try? FileManager.default.removeItem(at: legacy)
    }

    func clearAllLogs() {
        stop()
        for url in Self.allLogFiles() {
            try? FileManager.default.removeItem(at: url)
        }
        if isEnabled { start() }
    }

    // MARK: - Lifecycle

    private func start() {
        closeFile()
        do {
            let directory = Self.logsDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(Self.makeFilename())
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            fileHandle = handle
            currentLogFileURL = url
            writeHeader(to: handle)
            append(category: "LogFileWriter", level: "INFO", message: "file logging started: \(url.lastPathComponent)")
            systemLog.info("file logging started: \(url.lastPathComponent, privacy: .public)")
        } catch {
            systemLog.error("failed to start file logging: \(String(describing: error), privacy: .public)")
            closeFile()
        }
    }

    private func stop() { closeFile() }

    private func closeFile() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
        currentLogFileURL = nil
    }

    // MARK: - Formatting

    private nonisolated static let isoTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated static func makeFilename() -> String {
        let date = filenameDateFormatter.string(from: Date())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "flux-\(date)-v\(version)-b\(build).log"
    }

    private nonisolated static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private func writeHeader(to handle: FileHandle) {
        let device = UIDevice.current
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let launch = Self.isoTimestampFormatter.string(from: Date())
        let header = """
        =============================================
         FreeTube log
         App version:   \(version) (build \(build))
         iOS:           \(device.systemVersion)
         Device:        \(device.model)
         Launch:        \(launch)
         Subsystem:     \(Self.subsystem)
        =============================================

        """
        if let data = header.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}
