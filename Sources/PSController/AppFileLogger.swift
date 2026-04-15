import Foundation

enum AppLogLevel: String {
    case info = "INFO"
    case debug = "DEBUG"
    case error = "ERROR"
}

final class AppFileLogger {
    static let shared = AppFileLogger()

    private let queue = DispatchQueue(label: "PSController.FileLogger", qos: .utility)
    private let fileManager: FileManager
    private let logFileURL: URL
    private let dateFormatter: ISO8601DateFormatter

    private var didPrepareFile = false
    private var didReportPreparationFailure = false

    init(fileManager: FileManager = .default, logFileURL: URL? = nil) {
        self.fileManager = fileManager
        self.logFileURL = logFileURL ?? Self.defaultLogFileURL(fileManager: fileManager)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.dateFormatter = formatter
    }

    func info(category: String, _ message: String) {
        log(level: .info, category: category, message: message)
    }

    func debug(category: String, _ message: String) {
        log(level: .debug, category: category, message: message)
    }

    func error(category: String, _ message: String) {
        log(level: .error, category: category, message: message)
    }

    func log(level: AppLogLevel, category: String, message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.appendLine(level: level, category: category, message: message)
        }
    }

    private static func defaultLogFileURL(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("PSController", isDirectory: true)
            .appendingPathComponent("app.log", isDirectory: false)
    }

    private func appendLine(level: AppLogLevel, category: String, message: String) {
        guard ensureLogFileReady() else { return }

        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) [\(level.rawValue)] [\(category)] \(message)\n"

        guard let data = line.data(using: .utf8) else { return }

        do {
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer {
                try? handle.close()
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            if !didReportPreparationFailure {
                didReportPreparationFailure = true
                fputs("[PSController.FileLogger] failed to write log file at \(logFileURL.path): \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private func ensureLogFileReady() -> Bool {
        if didPrepareFile {
            return true
        }

        let directoryURL = logFileURL.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            if !fileManager.fileExists(atPath: logFileURL.path) {
                let created = fileManager.createFile(atPath: logFileURL.path, contents: nil)
                guard created else {
                    if !didReportPreparationFailure {
                        didReportPreparationFailure = true
                        fputs("[PSController.FileLogger] failed to create log file at \(logFileURL.path)\n", stderr)
                    }
                    return false
                }
            }

            didPrepareFile = true
            return true
        } catch {
            if !didReportPreparationFailure {
                didReportPreparationFailure = true
                fputs("[PSController.FileLogger] failed to prepare log file at \(logFileURL.path): \(error.localizedDescription)\n", stderr)
            }
            return false
        }
    }
}
