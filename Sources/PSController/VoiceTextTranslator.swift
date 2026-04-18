import Foundation
import OSLog

protocol VoiceTextTranslating {
    func translateToEnglish(text: String, completion: @escaping (Result<String, Error>) -> Void)
}

final class OllamaVoiceTextTranslator: VoiceTextTranslating {
    struct Configuration {
        let baseURL: String
        let model: String
        let timeoutSeconds: TimeInterval

        static let `default` = Configuration(
            baseURL: "http://127.0.0.1:11434",
            model: "gemma4:e4b",
            timeoutSeconds: 20
        )
    }

    private struct OllamaGenerateRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
    }

    private struct OllamaGenerateResponse: Decodable {
        let response: String?
    }

    private enum TranslationError: LocalizedError {
        case invalidBaseURL(String)
        case requestEncodingFailed
        case invalidHTTPResponse
        case httpError(statusCode: Int, body: String)
        case invalidPayload
        case emptyTranslation

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL(let value):
                return "Invalid Ollama base URL: \(value)"
            case .requestEncodingFailed:
                return "Failed to encode Ollama translation request"
            case .invalidHTTPResponse:
                return "Ollama translation response is not HTTP"
            case .httpError(let statusCode, let body):
                return "Ollama translation HTTP \(statusCode): \(body)"
            case .invalidPayload:
                return "Ollama translation response payload is invalid"
            case .emptyTranslation:
                return "Ollama translation is empty"
            }
        }
    }

    private let configuration: Configuration
    private let urlSession: URLSession
    private let logger: Logger

    init(
        configuration: Configuration = .default,
        urlSession: URLSession = .shared,
        logger: Logger = Logger(subsystem: "PSController", category: "VoiceTranslation")
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.logger = logger
    }

    func translateToEnglish(text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let normalizedInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInput.isEmpty else {
            completion(.failure(TranslationError.emptyTranslation))
            return
        }

        guard let endpoint = translationEndpointURL() else {
            completion(.failure(TranslationError.invalidBaseURL(configuration.baseURL)))
            return
        }

        let requestPayload = OllamaGenerateRequest(
            model: configuration.model,
            prompt: translationPrompt(for: normalizedInput),
            stream: false
        )

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = configuration.timeoutSeconds
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(requestPayload)
        } catch {
            completion(.failure(TranslationError.requestEncodingFailed))
            return
        }

        logInfo("voice_translation_request_start endpoint=\(endpoint.absoluteString) model=\(configuration.model) inputChars=\(normalizedInput.count)")

        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                self.logError("voice_translation_failed reason=network_error message=\(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                self.logError("voice_translation_failed reason=invalid_http_response")
                completion(.failure(TranslationError.invalidHTTPResponse))
                return
            }

            let responseText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let trimmedResponseText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.logInfo("voice_translation_response_raw status=\(httpResponse.statusCode) body=\(trimmedResponseText)")

            guard (200...299).contains(httpResponse.statusCode) else {
                completion(.failure(TranslationError.httpError(statusCode: httpResponse.statusCode, body: trimmedResponseText)))
                return
            }

            guard let data,
                  let decoded = try? JSONDecoder().decode(OllamaGenerateResponse.self, from: data),
                  let translated = decoded.response?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                completion(.failure(TranslationError.invalidPayload))
                return
            }

            guard !translated.isEmpty else {
                completion(.failure(TranslationError.emptyTranslation))
                return
            }

            self.logInfo("voice_translation_success outputChars=\(translated.count)")
            completion(.success(translated))
        }

        task.resume()
    }

    private func translationEndpointURL() -> URL? {
        guard var components = URLComponents(string: configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        components.path = "/api/generate"
        return components.url
    }

    private func translationPrompt(for text: String) -> String {
        """
        Translate the following text into natural English.
        Return only the translated English text, without explanation, markdown, or quotes.

        Text:
        \(text)
        """
    }

    private func logInfo(_ message: String) {
        logger.info("\(message, privacy: .public)")
        AppFileLogger.shared.info(category: "VoiceTranslation", message)
    }

    private func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        AppFileLogger.shared.error(category: "VoiceTranslation", message)
    }
}
