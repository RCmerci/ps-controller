import Foundation
import OSLog

protocol VoiceTranscriptCorrecting: AnyObject {
    func correct(_ text: String) -> String
}

final class DictionaryVoiceTranscriptCorrector: VoiceTranscriptCorrecting {
    private struct ReplacementRule {
        let wrong: String
        let correct: String
        let regex: NSRegularExpression
    }

    private let logger: Logger
    private let rules: [ReplacementRule]

    init(
        logger: Logger = Logger(subsystem: "PSController", category: "VoiceDictionary"),
        fileManager: FileManager = .default,
        explicitDictionaryPath: String? = ProcessInfo.processInfo.environment["PS_CONTROLLER_WORD_REPLACEMENTS_PATH"],
        currentDirectoryPath: String? = nil,
        bundle: Bundle = .main
    ) {
        self.logger = logger

        let loaded = Self.loadReplacementMap(
            fileManager: fileManager,
            explicitDictionaryPath: explicitDictionaryPath,
            currentDirectoryPath: currentDirectoryPath,
            bundle: bundle,
            logger: logger
        )

        self.rules = Self.buildRules(from: loaded.map, logger: logger)

        logger.info("voice_dictionary_ready source=\(loaded.source, privacy: .public) rules=\(self.rules.count)")
        AppFileLogger.shared.info(category: "VoiceDictionary", "voice_dictionary_ready source=\(loaded.source) rules=\(self.rules.count)")
    }

    init(
        replacementMap: [String: [String]],
        logger: Logger = Logger(subsystem: "PSController", category: "VoiceDictionary")
    ) {
        self.logger = logger
        self.rules = Self.buildRules(from: replacementMap, logger: logger)

        logger.info("voice_dictionary_ready source=inline rules=\(self.rules.count)")
        AppFileLogger.shared.info(category: "VoiceDictionary", "voice_dictionary_ready source=inline rules=\(self.rules.count)")
    }

    func correct(_ text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return normalized
        }

        var output = normalized
        var totalMatches = 0

        for rule in rules {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            let matchCount = rule.regex.numberOfMatches(in: output, range: range)
            guard matchCount > 0 else { continue }

            output = rule.regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: rule.correct)
            totalMatches += matchCount
        }

        logger.info("voice_dictionary_apply changed=\(totalMatches > 0) matches=\(totalMatches)")
        AppFileLogger.shared.info(category: "VoiceDictionary", "voice_dictionary_apply changed=\(totalMatches > 0) matches=\(totalMatches)")

        return output
    }

    private static func loadReplacementMap(
        fileManager: FileManager,
        explicitDictionaryPath: String?,
        currentDirectoryPath: String?,
        bundle: Bundle,
        logger: Logger
    ) -> (map: [String: [String]], source: String) {
        for candidate in dictionaryCandidates(
            fileManager: fileManager,
            explicitDictionaryPath: explicitDictionaryPath,
            currentDirectoryPath: currentDirectoryPath,
            bundle: bundle
        ) {
            do {
                let data = try Data(contentsOf: candidate.url)
                let decoded = try JSONDecoder().decode([String: [String]].self, from: data)
                logger.info("voice_dictionary_loaded source=\(candidate.source, privacy: .public) path=\(candidate.url.path, privacy: .public) entries=\(decoded.count)")
                AppFileLogger.shared.info(category: "VoiceDictionary", "voice_dictionary_loaded source=\(candidate.source) path=\(candidate.url.path) entries=\(decoded.count)")
                return (decoded, candidate.source)
            } catch {
                logger.error("voice_dictionary_load_failed source=\(candidate.source, privacy: .public) path=\(candidate.url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                AppFileLogger.shared.error(category: "VoiceDictionary", "voice_dictionary_load_failed source=\(candidate.source) path=\(candidate.url.path) error=\(error.localizedDescription)")
            }
        }

        logger.info("voice_dictionary_fallback_builtin entries=\(fallbackReplacementMap.count)")
        AppFileLogger.shared.info(category: "VoiceDictionary", "voice_dictionary_fallback_builtin entries=\(fallbackReplacementMap.count)")
        return (fallbackReplacementMap, "built_in_default")
    }

    private static func dictionaryCandidates(
        fileManager: FileManager,
        explicitDictionaryPath: String?,
        currentDirectoryPath: String?,
        bundle: Bundle
    ) -> [(source: String, url: URL)] {
        var candidates: [(source: String, url: URL)] = []

        if let explicitDictionaryPath {
            let trimmed = explicitDictionaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                candidates.append(("env", URL(fileURLWithPath: trimmed)))
            }
        }

        if let resourceURL = bundle.resourceURL {
            let bundledURL = resourceURL.appendingPathComponent(dictionaryFileName, isDirectory: false)
            candidates.append(("bundle", bundledURL))
        }

        let resolvedCurrentDirectory = currentDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = (resolvedCurrentDirectory?.isEmpty == false) ? resolvedCurrentDirectory! : fileManager.currentDirectoryPath
        if !cwd.isEmpty {
            let cwdURL = URL(fileURLWithPath: cwd).appendingPathComponent(dictionaryFileName, isDirectory: false)
            candidates.append(("cwd", cwdURL))
        }

        return candidates
    }

    private static func buildRules(from replacementMap: [String: [String]], logger: Logger) -> [ReplacementRule] {
        var pairs: [(wrong: String, correct: String)] = []
        var dedup: Set<String> = []

        for correct in replacementMap.keys.sorted() {
            let normalizedCorrect = correct.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedCorrect.isEmpty else { continue }

            for wrongRaw in replacementMap[correct] ?? [] {
                let normalizedWrong = wrongRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedWrong.isEmpty else { continue }

                let dedupKey = dedupKeyForWrong(normalizedWrong)
                guard !dedup.contains(dedupKey) else { continue }
                dedup.insert(dedupKey)

                pairs.append((wrong: normalizedWrong, correct: normalizedCorrect))
            }
        }

        let sortedPairs = pairs.sorted { lhs, rhs in
            if lhs.wrong.count == rhs.wrong.count {
                return lhs.wrong < rhs.wrong
            }
            return lhs.wrong.count > rhs.wrong.count
        }

        var rules: [ReplacementRule] = []
        for pair in sortedPairs {
            let pattern = replacementPattern(forWrong: pair.wrong)
            let options: NSRegularExpression.Options = containsLatinCharacters(pair.wrong) ? [.caseInsensitive] : []

            do {
                let regex = try NSRegularExpression(pattern: pattern, options: options)
                rules.append(ReplacementRule(wrong: pair.wrong, correct: pair.correct, regex: regex))
            } catch {
                logger.error("voice_dictionary_rule_invalid wrong=\(pair.wrong, privacy: .public) correct=\(pair.correct, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                AppFileLogger.shared.error(category: "VoiceDictionary", "voice_dictionary_rule_invalid wrong=\(pair.wrong) correct=\(pair.correct) error=\(error.localizedDescription)")
            }
        }

        return rules
    }

    private static func replacementPattern(forWrong wrong: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: wrong)

        if containsLatinCharacters(wrong) {
            return "(?<![A-Za-z0-9_])\(escaped)(?![A-Za-z0-9_])"
        }

        return escaped
    }

    private static func containsLatinCharacters(_ text: String) -> Bool {
        text.range(of: "[A-Za-z]", options: .regularExpression) != nil
    }

    private static func dedupKeyForWrong(_ wrong: String) -> String {
        if containsLatinCharacters(wrong) {
            return wrong.lowercased()
        }

        return wrong
    }

    private static let dictionaryFileName = "voice-word-replacements.json"

    private static let fallbackReplacementMap: [String: [String]] = [
        "API": ["阿皮爱"],
        "Clojure": ["Cello", "Closer"],
        "Emacs": ["E max", "IMAX"],
        "JSON": ["jason", "杰森"],
        "Logseq": ["Log萨克", "log seek", "log six"],
        "Python": ["派森", "配森"]
    ]
}
