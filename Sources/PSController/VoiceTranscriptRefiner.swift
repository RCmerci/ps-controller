import Foundation
import OSLog

protocol VoiceTranscriptRefining: AnyObject {
    func refine(
        text: String,
        configuration: VoiceInputLLMRefinerConfiguration,
        completion: @escaping (Result<String, Error>) -> Void
    )

    func cancelCurrentRefinement(reason: String)
}

final class OllamaVoiceTranscriptRefiner: VoiceTranscriptRefining {
    private let logger: Logger
    private let callbackQueue: DispatchQueue
    private let syncQueue: DispatchQueue

    private var currentTask: URLSessionDataTask?

    init(
        logger: Logger = Logger(subsystem: "PSController", category: "VoiceRefiner"),
        callbackQueue: DispatchQueue = .main,
        syncQueue: DispatchQueue = DispatchQueue(label: "PSController.VoiceRefiner")
    ) {
        self.logger = logger
        self.callbackQueue = callbackQueue
        self.syncQueue = syncQueue
    }

    func refine(
        text: String,
        configuration: VoiceInputLLMRefinerConfiguration,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            dispatchCompletion(.success(""), completion: completion)
            return
        }

        guard configuration.enabled else {
            dispatchCompletion(.success(normalizedText), completion: completion)
            return
        }

        guard let url = makeChatURL(baseURL: configuration.baseURL) else {
            dispatchCompletion(.failure(OllamaRefinerError.invalidBaseURL(configuration.baseURL)), completion: completion)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": configuration.model,
            "stream": false,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": normalizedText]
            ],
            "options": [
                "temperature": 0.1
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            dispatchCompletion(.failure(error), completion: completion)
            return
        }

        logInfo("voice_refiner_request model=\(configuration.model) baseURL=\(configuration.baseURL) chars=\(normalizedText.count)")

        cancelCurrentRefinement(reason: "new_request")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }

            self.syncQueue.async {
                self.currentTask = nil
            }

            if let error {
                self.logError("voice_refiner_failed reason=network_error message=\(error.localizedDescription)")
                self.dispatchCompletion(.failure(error), completion: completion)
                return
            }

            guard let data else {
                self.logError("voice_refiner_failed reason=empty_response")
                self.dispatchCompletion(.failure(OllamaRefinerError.emptyResponse), completion: completion)
                return
            }

            do {
                let payload = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
                let content = payload.message?.content ?? payload.response ?? ""
                let refined = content.trimmingCharacters(in: .whitespacesAndNewlines)

                if refined.isEmpty {
                    self.logInfo("voice_refiner_success changed=false empty_refined=true")
                    self.dispatchCompletion(.success(normalizedText), completion: completion)
                    return
                }

                self.logInfo("voice_refiner_success changed=\(refined != normalizedText)")
                self.dispatchCompletion(.success(refined), completion: completion)
            } catch {
                self.logError("voice_refiner_failed reason=parse_error message=\(error.localizedDescription)")
                self.dispatchCompletion(.failure(OllamaRefinerError.invalidResponse), completion: completion)
            }
        }

        syncQueue.async {
            self.currentTask = task
            task.resume()
        }
    }

    func cancelCurrentRefinement(reason: String) {
        syncQueue.async {
            if let task = self.currentTask {
                self.logInfo("voice_refiner_cancel reason=\(reason) task=\(task.taskIdentifier)")
                task.cancel()
                self.currentTask = nil
            }
        }
    }

    private func logInfo(_ message: String) {
        logger.info("\(message, privacy: .public)")
        AppFileLogger.shared.info(category: "VoiceRefiner", message)
    }

    private func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        AppFileLogger.shared.error(category: "VoiceRefiner", message)
    }

    private func dispatchCompletion(_ result: Result<String, Error>, completion: @escaping (Result<String, Error>) -> Void) {
        callbackQueue.async {
            completion(result)
        }
    }

    private func makeChatURL(baseURL: String) -> URL? {
        let normalizedBase = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !normalizedBase.isEmpty else { return nil }

        if normalizedBase.hasSuffix("/api/chat") {
            return URL(string: normalizedBase)
        }

        return URL(string: "\(normalizedBase)/api/chat")
    }

    private struct OllamaChatResponse: Decodable {
        let message: OllamaChatMessage?
        let response: String?
    }

    private struct OllamaChatMessage: Decodable {
        let content: String
    }

    enum OllamaRefinerError: LocalizedError {
        case invalidBaseURL(String)
        case emptyResponse
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL(let baseURL):
                return "Invalid Ollama base URL: \(baseURL)"
            case .emptyResponse:
                return "Ollama returned empty response"
            case .invalidResponse:
                return "Invalid Ollama response payload"
            }
        }
    }

    private static let systemPrompt = """
    You are a conservative speech recognition error corrector.
    ONLY fix clear transcription errors and keep original wording.

    What to fix:
    - English words/acronyms wrongly rendered as Chinese characters
      (e.g. "配森" → "Python", "杰森" → "JSON", "阿皮爱" → "API")
    - Obvious Chinese homophone errors where context makes the correct character clear
    - Broken English words or phrases split/merged incorrectly by the recognizer
    - Unrecognized technical proper nouns
      - IMAX -> Emacs
      - Closer,Cello -> Clojure
      - Log萨克 -> Logseq

    What NOT to do:
    - Do not rewrite style or add extra text
    - Do not change text that could plausibly be correct

    Return only the corrected text.
    """
}
