import Foundation
import XCTest
@testable import PSController

final class VoiceTranscriptCorrectorTests: XCTestCase {
    func testDictionaryCorrectorReplacesCommonEnglishMistakes() {
        let corrector = DictionaryVoiceTranscriptCorrector(
            replacementMap: [
                "Emacs": ["IMAX", "e max"],
                "Clojure": ["Closer", "Cello"],
                "JSON": ["jason"]
            ]
        )

        let output = corrector.correct("Open IMAX and Cello, parse jason.")

        XCTAssertEqual(output, "Open Emacs and Clojure, parse JSON.")
    }

    func testDictionaryCorrectorDoesNotReplaceInsideLongerEnglishWords() {
        let corrector = DictionaryVoiceTranscriptCorrector(
            replacementMap: [
                "JSON": ["json"]
            ]
        )

        let output = corrector.correct("Please keep jsonify unchanged.")

        XCTAssertEqual(output, "Please keep jsonify unchanged.")
    }

    func testDictionaryCorrectorHandlesMultipleVariantsForSameWord() {
        let corrector = DictionaryVoiceTranscriptCorrector(
            replacementMap: [
                "Logseq": ["log seek", "log six", "Log萨克"]
            ]
        )

        let output = corrector.correct("Open log seek and Log萨克 notes")

        XCTAssertEqual(output, "Open Logseq and Logseq notes")
    }

    func testDictionaryCorrectorLoadsRulesFromJSONFile() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-dict-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let json = """
        {
          "Emacs": ["IMAX"],
          "JSON": ["jason"]
        }
        """

        try Data(json.utf8).write(to: fileURL, options: .atomic)

        let corrector = DictionaryVoiceTranscriptCorrector(explicitDictionaryPath: fileURL.path)
        let output = corrector.correct("Use IMAX with jason")

        XCTAssertEqual(output, "Use Emacs with JSON")
    }
}
