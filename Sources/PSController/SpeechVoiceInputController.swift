import Foundation
import AVFoundation
import OSLog

struct VoiceTranscriptEvent: Equatable {
    let text: String
    let isFinal: Bool
}

protocol VoiceInputControlling: AnyObject {
    var onTranscript: ((VoiceTranscriptEvent) -> Void)? { get set }

    func updateConfiguration(_ configuration: VoiceInputConfiguration?)
    func prepare()
    func startCapture(trigger: String, localeIdentifier: String?)
    func stopCapture(trigger: String)
}

extension VoiceInputControlling {
    func updateConfiguration(_ configuration: VoiceInputConfiguration?) {
        _ = configuration
    }

    func startCapture(trigger: String) {
        startCapture(trigger: trigger, localeIdentifier: nil)
    }
}

final class Qwen3ASRVoiceInputController: VoiceInputControlling {
    var onTranscript: ((VoiceTranscriptEvent) -> Void)?

    private struct CaptureContext {
        let id: UUID
        let trigger: String
        let localeIdentifier: String?
        let fileURL: URL
        let startedAt: Date
    }

    private struct OpenAITranscriptionResponse: Decodable {
        let text: String?
    }

    private let logger: Logger
    private let queue: DispatchQueue
    private let audioEngine: AVAudioEngine
    private let fileManager: FileManager
    private let urlSession: URLSession

    private var microphoneAuthorizationStatus: AVAuthorizationStatus
    private var voiceInputConfiguration: VoiceInputConfiguration

    private var isCapturing = false
    private var currentCapture: CaptureContext?
    private var currentAudioFile: AVAudioFile?

    private var currentTranscriptionTask: URLSessionDataTask?
    private var currentTranscriptionID: UUID?

    init(
        logger: Logger = Logger(subsystem: "PSController", category: "VoiceInput"),
        queue: DispatchQueue = DispatchQueue(label: "PSController.VoiceInput", qos: .userInitiated),
        audioEngine: AVAudioEngine = AVAudioEngine(),
        fileManager: FileManager = .default,
        urlSession: URLSession = .shared,
        initialConfiguration: VoiceInputConfiguration = VoiceInputConfiguration().normalizedForRuntime()
    ) {
        self.logger = logger
        self.queue = queue
        self.audioEngine = audioEngine
        self.fileManager = fileManager
        self.urlSession = urlSession
        self.microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.voiceInputConfiguration = initialConfiguration
    }

    func updateConfiguration(_ configuration: VoiceInputConfiguration?) {
        let normalized = configuration?.normalizedForRuntime() ?? VoiceInputConfiguration().normalizedForRuntime()

        queue.async {
            self.voiceInputConfiguration = normalized
            let asr = normalized.asrServer
            self.logInfo("voice_config_updated baseURL=\(asr.baseURL) model=\(asr.model) timeoutSeconds=\(asr.timeoutSeconds) apiKeyConfigured=\(!asr.apiKey.isEmpty)")
        }
    }

    func prepare() {
        logInfo("voice_prepare_start micStatus=\(microphoneAuthorizationStatus.rawValue)")

        if microphoneAuthorizationStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                self?.queue.async {
                    self?.microphoneAuthorizationStatus = granted ? .authorized : .denied
                    self?.logInfo("voice_mic_auth_result granted=\(granted)")
                }
            }
        }
    }

    func startCapture(trigger: String, localeIdentifier: String?) {
        queue.async {
            self.startCaptureLocked(trigger: trigger, localeIdentifier: localeIdentifier)
        }
    }

    private func startCaptureLocked(trigger: String, localeIdentifier: String?) {
        guard !isCapturing else {
            logDebug("voice_start_ignored_already_running trigger=\(trigger)")
            return
        }

        guard microphoneAuthorizationStatus == .authorized else {
            logInfo("voice_start_blocked mic_auth_status=\(microphoneAuthorizationStatus.rawValue) trigger=\(trigger)")
            prepare()
            return
        }

        cancelActiveTranscriptionLocked(reason: "new_capture_start")

        let asrServer = voiceInputConfiguration.asrServer
        if asrServer.apiKey.isEmpty {
            logError("voice_start_blocked reason=missing_asr_api_key trigger=\(trigger)")
            return
        }

        let captureID = UUID()
        let captureFileURL = makeCaptureFileURL(captureID: captureID)

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        let inputFormat = inputNode.outputFormat(forBus: 0)
        logInfo("voice_audio_input_format channels=\(inputFormat.channelCount) sampleRate=\(inputFormat.sampleRate) interleaved=\(inputFormat.isInterleaved)")

        do {
            let audioFile = try AVAudioFile(forWriting: captureFileURL, settings: inputFormat.settings)
            currentAudioFile = audioFile

            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }
                try? self.currentAudioFile?.write(from: buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            cleanupCaptureArtifacts(fileURL: captureFileURL)
            currentAudioFile = nil
            logError("voice_start_failed reason=audio_engine_start_error message=\(error.localizedDescription) trigger=\(trigger)")
            return
        }

        currentCapture = CaptureContext(
            id: captureID,
            trigger: trigger,
            localeIdentifier: localeIdentifier,
            fileURL: captureFileURL,
            startedAt: Date()
        )

        isCapturing = true
        logInfo("voice_started trigger=\(trigger) locale=\(localeIdentifier ?? "auto") captureID=\(captureID.uuidString)")
    }

    func stopCapture(trigger: String) {
        queue.async {
            self.logInfo("voice_stop_requested trigger=\(trigger)")
            self.stopCaptureLocked(trigger: trigger)
        }
    }

    private func stopCaptureLocked(trigger: String) {
        guard isCapturing else {
            logDebug("voice_stop_ignored_not_running trigger=\(trigger)")
            return
        }

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine.inputNode.removeTap(onBus: 0)

        let capture = currentCapture
        currentCapture = nil
        currentAudioFile = nil
        isCapturing = false

        guard let capture else {
            logDebug("voice_stop_without_capture_context trigger=\(trigger)")
            return
        }

        let duration = Date().timeIntervalSince(capture.startedAt)
        let shouldTranscribe = trigger.hasPrefix("button.")

        logInfo("voice_stopped reason=manual_stop trigger=\(trigger) captureID=\(capture.id.uuidString) durationSeconds=\(String(format: "%.3f", duration)) shouldTranscribe=\(shouldTranscribe)")

        guard shouldTranscribe else {
            cleanupCaptureArtifacts(fileURL: capture.fileURL)
            logDebug("voice_transcription_skipped reason=non_button_trigger captureID=\(capture.id.uuidString)")
            return
        }

        transcribeCapture(capture)
    }

    private func transcribeCapture(_ capture: CaptureContext) {
        let asrServer = voiceInputConfiguration.asrServer

        let endpointURL = makeTranscriptionEndpointURL(baseURL: asrServer.baseURL)
        guard let endpointURL else {
            cleanupCaptureArtifacts(fileURL: capture.fileURL)
            logError("voice_transcription_failed reason=invalid_base_url baseURL=\(asrServer.baseURL) captureID=\(capture.id.uuidString)")
            return
        }

        let languageCode = asrLanguageCode(from: capture.localeIdentifier)

        let audioData: Data
        do {
            audioData = try Data(contentsOf: capture.fileURL)
        } catch {
            cleanupCaptureArtifacts(fileURL: capture.fileURL)
            logError("voice_transcription_failed reason=read_audio_file_error captureID=\(capture.id.uuidString) message=\(error.localizedDescription)")
            return
        }

        if audioData.isEmpty {
            cleanupCaptureArtifacts(fileURL: capture.fileURL)
            logError("voice_transcription_failed reason=empty_audio_data captureID=\(capture.id.uuidString)")
            return
        }

        let requestID = UUID()
        currentTranscriptionID = requestID

        let request = buildTranscriptionRequest(
            endpointURL: endpointURL,
            audioData: audioData,
            fileName: capture.fileURL.lastPathComponent,
            languageCode: languageCode,
            asrServer: asrServer
        )

        logInfo("voice_transcription_request_start requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) endpoint=\(endpointURL.absoluteString) model=\(asrServer.model) language=\(languageCode ?? "auto") bytes=\(audioData.count)")

        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            self.queue.async {
                self.handleTranscriptionResponse(
                    requestID: requestID,
                    capture: capture,
                    responseData: data,
                    response: response,
                    error: error
                )
            }
        }

        currentTranscriptionTask = task
        task.resume()
    }

    private func handleTranscriptionResponse(
        requestID: UUID,
        capture: CaptureContext,
        responseData: Data?,
        response: URLResponse?,
        error: Error?
    ) {
        defer {
            cleanupCaptureArtifacts(fileURL: capture.fileURL)
            if currentTranscriptionID == requestID {
                currentTranscriptionID = nil
                currentTranscriptionTask = nil
            }
        }

        guard currentTranscriptionID == requestID else {
            logDebug("voice_transcription_stale_response requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString)")
            return
        }

        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                logDebug("voice_transcription_cancelled requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString)")
                return
            }

            logError("voice_transcription_failed reason=network_error requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) message=\(error.localizedDescription)")
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            logError("voice_transcription_failed reason=invalid_http_response requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString)")
            return
        }

        let responseText = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyPreview = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            logError("voice_transcription_failed reason=http_error requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) status=\(httpResponse.statusCode) body=\(bodyPreview)")
            return
        }

        let transcript: String
        if (httpResponse.mimeType ?? "").lowercased().contains("text/plain") {
            transcript = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            guard let responseData,
                  let payload = try? JSONDecoder().decode(OpenAITranscriptionResponse.self, from: responseData),
                  let text = payload.text else {
                logError("voice_transcription_failed reason=invalid_json_payload requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString)")
                return
            }

            transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !transcript.isEmpty else {
            logInfo("voice_transcription_empty requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString)")
            return
        }

        logInfo("voice_transcript final=true locale=\(capture.localeIdentifier ?? "auto") text=\(transcript)")
        onTranscript?(.init(text: transcript, isFinal: true))
    }

    private func cancelActiveTranscriptionLocked(reason: String) {
        if let currentTranscriptionTask {
            logInfo("voice_transcription_cancel reason=\(reason)")
            currentTranscriptionTask.cancel()
            self.currentTranscriptionTask = nil
            self.currentTranscriptionID = nil
        }
    }

    private func makeCaptureFileURL(captureID: UUID) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("pscontroller-voice-\(captureID.uuidString)", isDirectory: false)
            .appendingPathExtension("wav")
    }

    private func makeTranscriptionEndpointURL(baseURL: String) -> URL? {
        let normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBaseURL.isEmpty else { return nil }

        let withoutTrailingSlash: String
        if normalizedBaseURL.hasSuffix("/") {
            withoutTrailingSlash = String(normalizedBaseURL.dropLast())
        } else {
            withoutTrailingSlash = normalizedBaseURL
        }

        if withoutTrailingSlash.hasSuffix("/v1/audio/transcriptions") {
            return URL(string: withoutTrailingSlash)
        }

        if withoutTrailingSlash.hasSuffix("/v1") {
            return URL(string: "\(withoutTrailingSlash)/audio/transcriptions")
        }

        return URL(string: "\(withoutTrailingSlash)/v1/audio/transcriptions")
    }

    private func asrLanguageCode(from localeIdentifier: String?) -> String? {
        guard let localeIdentifier else {
            return nil
        }

        let trimmed = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let normalized = trimmed.replacingOccurrences(of: "_", with: "-")
        guard let languageSubtag = normalized.split(separator: "-").first else {
            return nil
        }

        let language = String(languageSubtag).lowercased()
        return language.isEmpty ? nil : language
    }

    private func buildTranscriptionRequest(
        endpointURL: URL,
        audioData: Data,
        fileName: String,
        languageCode: String?,
        asrServer: VoiceInputASRServerConfiguration
    ) -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = asrServer.timeoutSeconds
        request.setValue("Bearer \(asrServer.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        appendMultipartField(name: "model", value: asrServer.model, boundary: boundary, body: &body)
        appendMultipartField(name: "response_format", value: "json", boundary: boundary, body: &body)

        if let languageCode, !languageCode.isEmpty {
            appendMultipartField(name: "language", value: languageCode, boundary: boundary, body: &body)
        }

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")

        request.httpBody = body
        return request
    }

    private func appendMultipartField(name: String, value: String, boundary: String, body: inout Data) {
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendString("\(value)\r\n")
    }

    private func cleanupCaptureArtifacts(fileURL: URL) {
        try? fileManager.removeItem(at: fileURL)
    }

    private func logInfo(_ message: String) {
        logger.info("\(message, privacy: .public)")
        AppFileLogger.shared.info(category: "VoiceInput", message)
        print("[VoiceInput] \(message)")
    }

    private func logDebug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        AppFileLogger.shared.debug(category: "VoiceInput", message)
        print("[VoiceInput] \(message)")
    }

    private func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        AppFileLogger.shared.error(category: "VoiceInput", message)
        print("[VoiceInput] \(message)")
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        append(data)
    }
}
