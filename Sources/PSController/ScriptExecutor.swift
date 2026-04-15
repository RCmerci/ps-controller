import Foundation
import OSLog

protocol ScriptExecuting {
    func execute(binding: ScriptBinding, trigger: String)
}

final class ProcessScriptExecutor: ScriptExecuting {
    private let logger: Logger
    private let queue: DispatchQueue
    private let onLog: (String) -> Void

    init(
        logger: Logger = Logger(subsystem: "PSController", category: "ScriptExecutor"),
        queue: DispatchQueue = DispatchQueue(label: "PSController.ScriptExecutor", qos: .userInitiated),
        onLog: @escaping (String) -> Void = { _ in }
    ) {
        self.logger = logger
        self.queue = queue
        self.onLog = onLog
    }

    func execute(binding: ScriptBinding, trigger: String) {
        let command = binding.command
        let displayName = binding.name

        log("script_start trigger=\(trigger) name=\(displayName) command=\(command)")

        queue.async { [logger, onLog] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]

            if let workingDirectory = binding.workingDirectory, !workingDirectory.isEmpty {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                process.waitUntilExit()

                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                let status = process.terminationStatus
                let reason = process.terminationReason == .exit ? "exit" : "uncaughtSignal"

                let finishMessage = "script_finish trigger=\(trigger) name=\(displayName) status=\(status) reason=\(reason)"
                logger.info("\(finishMessage, privacy: .public)")
                AppFileLogger.shared.info(category: "ScriptExecutor", finishMessage)
                onLog(finishMessage)
                print("[ScriptExecutor] \(finishMessage)")

                if !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let stdoutMessage = "script_stdout name=\(displayName) output=\(stdout.trimmingCharacters(in: .whitespacesAndNewlines))"
                    logger.debug("\(stdoutMessage, privacy: .public)")
                    AppFileLogger.shared.debug(category: "ScriptExecutor", stdoutMessage)
                    onLog(stdoutMessage)
                    print("[ScriptExecutor] \(stdoutMessage)")
                }

                if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let stderrMessage = "script_stderr name=\(displayName) output=\(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                    logger.error("\(stderrMessage, privacy: .public)")
                    AppFileLogger.shared.error(category: "ScriptExecutor", stderrMessage)
                    onLog(stderrMessage)
                    print("[ScriptExecutor] \(stderrMessage)")
                }
            } catch {
                let errorMessage = "script_error trigger=\(trigger) name=\(displayName) error=\(error.localizedDescription)"
                logger.error("\(errorMessage, privacy: .public)")
                AppFileLogger.shared.error(category: "ScriptExecutor", errorMessage)
                onLog(errorMessage)
                print("[ScriptExecutor] \(errorMessage)")
            }
        }
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        AppFileLogger.shared.info(category: "ScriptExecutor", message)
        onLog(message)
        print("[ScriptExecutor] \(message)")
    }
}
