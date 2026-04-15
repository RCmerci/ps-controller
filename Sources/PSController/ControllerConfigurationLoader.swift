import Foundation
import OSLog

struct ControllerConfigurationResolutionInfo {
    let url: URL
    let source: String
    let fileExists: Bool
}

protocol ControllerConfigurationProviding {
    func loadConfiguration() -> ControllerConfiguration
    func latestResolutionInfo() -> ControllerConfigurationResolutionInfo?
}

extension ControllerConfigurationProviding {
    func latestResolutionInfo() -> ControllerConfigurationResolutionInfo? {
        nil
    }
}

final class ControllerConfigurationLoader: ControllerConfigurationProviding {
    private let logger: Logger
    private let fileManager: FileManager
    private let explicitConfigPath: String?

    private var latestResolution: ControllerConfigurationResolutionInfo?

    init(
        logger: Logger = Logger(subsystem: "PSController", category: "Configuration"),
        fileManager: FileManager = .default,
        explicitConfigPath: String? = ProcessInfo.processInfo.environment["PS_CONTROLLER_CONFIG_PATH"]
    ) {
        self.logger = logger
        self.fileManager = fileManager
        self.explicitConfigPath = explicitConfigPath
    }

    func loadConfiguration() -> ControllerConfiguration {
        let resolved = resolveConfigURL()
        let configURL = resolved.url
        let fileExists = fileManager.fileExists(atPath: configURL.path)

        latestResolution = ControllerConfigurationResolutionInfo(
            url: configURL,
            source: resolved.source.rawValue,
            fileExists: fileExists
        )

        if !fileExists {
            writeDefaultConfiguration(to: configURL)
            logInfo("Configuration file created at: \(configURL.path) source=\(resolved.source.rawValue)")
            return .default.normalizedForRuntime()
        }

        do {
            let data = try Data(contentsOf: configURL)
            let decoded = try JSONDecoder().decode(ControllerConfiguration.self, from: data)
            let normalized = decoded.normalizedForRuntime()
            logInfo("Configuration loaded from: \(configURL.path) source=\(resolved.source.rawValue)")
            return normalized
        } catch {
            logError("Failed to load configuration at \(configURL.path) source=\(resolved.source.rawValue), fallback to default. error=\(error.localizedDescription)")
            return .default.normalizedForRuntime()
        }
    }

    func latestResolutionInfo() -> ControllerConfigurationResolutionInfo? {
        latestResolution
    }

    private func resolveConfigURL() -> (url: URL, source: ConfigSource) {
        if let explicitConfigPath, !explicitConfigPath.isEmpty {
            return (URL(fileURLWithPath: explicitConfigPath), .environmentOverride)
        }

        if let bundledConfigURL = bundledConfigURL(),
           fileManager.fileExists(atPath: bundledConfigURL.path) {
            return (bundledConfigURL, .appBundleResource)
        }

        if let workingDirectoryConfigURL = workingDirectoryConfigURL(),
           fileManager.fileExists(atPath: workingDirectoryConfigURL.path) {
            return (workingDirectoryConfigURL, .workingDirectory)
        }

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())

        let appSupportConfigURL = appSupport
            .appendingPathComponent("PSController", isDirectory: true)
            .appendingPathComponent("controller-config.json", isDirectory: false)

        return (appSupportConfigURL, .appSupport)
    }

    private func bundledConfigURL() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }

        return resourceURL.appendingPathComponent("controller-config.json", isDirectory: false)
    }

    private func workingDirectoryConfigURL() -> URL? {
        let currentDirectoryPath = fileManager.currentDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentDirectoryPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: currentDirectoryPath)
            .appendingPathComponent("controller-config.json", isDirectory: false)
    }

    private func writeDefaultConfiguration(to url: URL) {
        do {
            let directoryURL = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(ControllerConfiguration.default)
            try data.write(to: url, options: .atomic)
        } catch {
            logError("Failed to write default configuration to \(url.path). error=\(error.localizedDescription)")
        }
    }

    private enum ConfigSource: String {
        case environmentOverride = "env"
        case appBundleResource = "bundle"
        case workingDirectory = "cwd"
        case appSupport = "app_support"
    }

    private func logInfo(_ message: String) {
        logger.info("\(message, privacy: .public)")
        AppFileLogger.shared.info(category: "Configuration", message)
    }

    private func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        AppFileLogger.shared.error(category: "Configuration", message)
    }
}
