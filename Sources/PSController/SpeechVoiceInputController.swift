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
    var onASRServerRecoveryRequested: ((@escaping (Bool, String) -> Void) -> Void)?

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

    private static let maxTranscriptionAttempts = 2
    private static let recoverableNetworkErrorCodes: Set<Int> = [
        NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorTimedOut
    ]

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

        let captureID = UUID()
        let captureFileURL = makeCaptureFileURL(captureID: captureID)

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        let inputFormat = inputNode.outputFormat(forBus: 0)
        let targetCaptureSettings = makeCaptureFileSettings()

        logInfo("voice_audio_input_format channels=\(inputFormat.channelCount) sampleRate=\(inputFormat.sampleRate) interleaved=\(inputFormat.isInterleaved)")
        logInfo("voice_audio_target_format channels=1 sampleRate=16000 bitDepth=16 encoding=pcm_wav")

        do {
            let audioFile = try AVAudioFile(
                forWriting: captureFileURL,
                settings: targetCaptureSettings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )

            let outputFormat = audioFile.processingFormat
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                cleanupCaptureArtifacts(fileURL: captureFileURL)
                currentAudioFile = nil
                logError("voice_start_failed reason=audio_converter_init_failed trigger=\(trigger)")
                return
            }

            currentAudioFile = audioFile

            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }

                guard let convertedBuffer = self.convertCapturedBuffer(buffer, converter: converter, outputFormat: outputFormat) else {
                    return
                }

                do {
                    try self.currentAudioFile?.write(from: convertedBuffer)
                } catch {
                    self.logError("voice_capture_write_failed captureID=\(captureID.uuidString) message=\(error.localizedDescription)")
                }
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

        let endpointURL = makeOpenAITranscriptionEndpointURL(baseURL: asrServer.baseURL)
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

        submitTranscriptionRequest(
            requestID: requestID,
            attempt: 1,
            capture: capture,
            endpointURL: endpointURL,
            audioData: audioData,
            languageCode: languageCode,
            asrServer: asrServer
        )
    }

    private func submitTranscriptionRequest(
        requestID: UUID,
        attempt: Int,
        capture: CaptureContext,
        endpointURL: URL,
        audioData: Data,
        languageCode: String?,
        asrServer: VoiceInputASRServerConfiguration
    ) {
        let request = buildTranscriptionRequest(
            endpointURL: endpointURL,
            audioData: audioData,
            fileName: capture.fileURL.lastPathComponent,
            languageCode: languageCode,
            asrServer: asrServer
        )

        logInfo("voice_transcription_request_start requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) attempt=\(attempt) endpoint=\(endpointURL.absoluteString) api=openai_compatible model=\(asrServer.model) language=\(languageCode ?? "auto") bytes=\(audioData.count)")

        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            self.queue.async {
                self.handleTranscriptionResponse(
                    requestID: requestID,
                    attempt: attempt,
                    capture: capture,
                    endpointURL: endpointURL,
                    audioData: audioData,
                    languageCode: languageCode,
                    asrServer: asrServer,
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
        attempt: Int,
        capture: CaptureContext,
        endpointURL: URL,
        audioData: Data,
        languageCode: String?,
        asrServer: VoiceInputASRServerConfiguration,
        responseData: Data?,
        response: URLResponse?,
        error: Error?
    ) {
        guard currentTranscriptionID == requestID else {
            logDebug("voice_transcription_stale_response requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) attempt=\(attempt)")
            cleanupCaptureArtifacts(fileURL: capture.fileURL)
            return
        }

        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                logDebug("voice_transcription_cancelled requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) attempt=\(attempt)")
                finalizeTranscriptionRequest(requestID: requestID, capture: capture)
                return
            }

            if shouldRecoverByRestartingASR(nsError: nsError, attempt: attempt) {
                requestASRRecoveryAndRetry(
                    requestID: requestID,
                    attempt: attempt,
                    capture: capture,
                    endpointURL: endpointURL,
                    audioData: audioData,
                    languageCode: languageCode,
                    asrServer: asrServer,
                    nsError: nsError,
                    originalError: error
                )
                return
            }

            logError("voice_transcription_failed reason=network_error requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) attempt=\(attempt) domain=\(nsError.domain) code=\(nsError.code) message=\(error.localizedDescription)")
            finalizeTranscriptionRequest(requestID: requestID, capture: capture)
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            logError("voice_transcription_failed reason=invalid_http_response requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) attempt=\(attempt)")
            finalizeTranscriptionRequest(requestID: requestID, capture: capture)
            return
        }

        let responseText = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let rawResponseBody = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        logInfo("voice_transcription_response_raw requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) attempt=\(attempt) status=\(httpResponse.statusCode) body=\(rawResponseBody)")

        guard (200...299).contains(httpResponse.statusCode) else {
            logError("voice_transcription_failed reason=http_error requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) attempt=\(attempt) status=\(httpResponse.statusCode) body=\(rawResponseBody)")
            finalizeTranscriptionRequest(requestID: requestID, capture: capture)
            return
        }

        guard let responseData,
              let payload = try? JSONDecoder().decode(OpenAITranscriptionResponse.self, from: responseData),
              let text = payload.text else {
            logError("voice_transcription_failed reason=invalid_json_payload requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) attempt=\(attempt)")
            finalizeTranscriptionRequest(requestID: requestID, capture: capture)
            return
        }

        let transcript = normalizeASRTranscriptText(text)

        guard !transcript.isEmpty else {
            logInfo("voice_transcription_filtered requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) attempt=\(attempt) reason=missing_asr_text_marker_or_empty_payload")
            finalizeTranscriptionRequest(requestID: requestID, capture: capture)
            return
        }

        logInfo("voice_transcript final=true locale=\(capture.localeIdentifier ?? "auto") text=\(transcript)")
        onTranscript?(.init(text: transcript, isFinal: true))
        finalizeTranscriptionRequest(requestID: requestID, capture: capture)
    }

    private func requestASRRecoveryAndRetry(
        requestID: UUID,
        attempt: Int,
        capture: CaptureContext,
        endpointURL: URL,
        audioData: Data,
        languageCode: String?,
        asrServer: VoiceInputASRServerConfiguration,
        nsError: NSError,
        originalError: Error
    ) {
        guard let onASRServerRecoveryRequested else {
            logError("voice_transcription_failed reason=restart_handler_missing requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) attempt=\(attempt) domain=\(nsError.domain) code=\(nsError.code) message=\(originalError.localizedDescription)")
            finalizeTranscriptionRequest(requestID: requestID, capture: capture)
            return
        }

        currentTranscriptionTask = nil

        logInfo("voice_transcription_recovery_restart_requested requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) attempt=\(attempt) domain=\(nsError.domain) code=\(nsError.code)")

        onASRServerRecoveryRequested { [weak self] success, message in
            guard let self else { return }

            self.queue.async {
                guard self.currentTranscriptionID == requestID else {
                    self.logDebug("voice_transcription_recovery_ignored_stale requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) attempt=\(attempt)")
                    self.cleanupCaptureArtifacts(fileURL: capture.fileURL)
                    return
                }

                guard success else {
                    self.logError("voice_transcription_recovery_restart_failed requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) attempt=\(attempt) message=\(message)")
                    self.finalizeTranscriptionRequest(requestID: requestID, capture: capture)
                    return
                }

                let nextAttempt = attempt + 1
                self.logInfo("voice_transcription_retry_start requestID=\(requestID.uuidString) captureID=\(capture.id.uuidString) attempt=\(nextAttempt) recoveryMessage=\(message)")

                self.submitTranscriptionRequest(
                    requestID: requestID,
                    attempt: nextAttempt,
                    capture: capture,
                    endpointURL: endpointURL,
                    audioData: audioData,
                    languageCode: languageCode,
                    asrServer: asrServer
                )
            }
        }
    }

    private func shouldRecoverByRestartingASR(nsError: NSError, attempt: Int) -> Bool {
        guard attempt < Self.maxTranscriptionAttempts else {
            return false
        }

        guard nsError.domain == NSURLErrorDomain else {
            return false
        }

        return Self.recoverableNetworkErrorCodes.contains(nsError.code)
    }

    private func finalizeTranscriptionRequest(requestID: UUID, capture: CaptureContext) {
        cleanupCaptureArtifacts(fileURL: capture.fileURL)

        if currentTranscriptionID == requestID {
            currentTranscriptionID = nil
            currentTranscriptionTask = nil
        }
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

    private func makeCaptureFileSettings() -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    private func convertCapturedBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard inputBuffer.frameLength > 0 else {
            return nil
        }

        let sampleRateRatio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let scaledFrameCount = Double(inputBuffer.frameLength) * sampleRateRatio
        let frameCapacity = AVAudioFrameCount(max(1, ceil(scaledFrameCount) + 16))

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            logError("voice_capture_convert_failed reason=output_buffer_alloc_failed")
            return nil
        }

        var conversionError: NSError?
        var didProvideInput = false

        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            logError("voice_capture_convert_failed reason=converter_error message=\(conversionError.localizedDescription)")
            return nil
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        case .error:
            logError("voice_capture_convert_failed reason=converter_status_error")
            return nil
        @unknown default:
            logError("voice_capture_convert_failed reason=converter_status_unknown")
            return nil
        }
    }

    private func makeOpenAITranscriptionEndpointURL(baseURL: String) -> URL? {
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
        switch language {
        case "zh":
            return "chinese"
        case "en":
            return "english"
        default:
            return language.isEmpty ? nil : language
        }
    }

    private func normalizeASRTranscriptText(_ rawText: String) -> String {
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let markerRange = normalized.range(of: "<asr_text>", options: .backwards) else {
            return ""
        }

        let contentAfterMarker = String(normalized[markerRange.upperBound...])
        return contentAfterMarker.trimmingCharacters(in: .whitespacesAndNewlines)
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

        let trimmedAPIKey = asrServer.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }

        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        appendMultipartField(name: "model", value: asrServer.model, boundary: boundary, body: &body)
        appendMultipartField(name: "response_format", value: "json", boundary: boundary, body: &body)
        appendMultipartField(name: "temperature", value: "0", boundary: boundary, body: &body)

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
