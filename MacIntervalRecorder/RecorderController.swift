@preconcurrency import AVFoundation
import AppKit
import IOKit.pwr_mgt

enum RecordingMode: String, CaseIterable, Identifiable {
    case interval = "定时录制"
    case humanMovement = "人体走动检测"

    var id: Self { self }
}

@MainActor
final class RecorderController: NSObject, ObservableObject {
    @Published var cameras: [AVCaptureDevice] = []
    @Published var selectedCameraID = "" {
        didSet {
            guard oldValue != selectedCameraID, !isRunning else { return }
            configureSession()
        }
    }
    @Published var intervalMinutes = 5
    @Published var clipSeconds = 5
    @Published var recordingMode: RecordingMode = .interval
    @Published var movementSensitivity = 0.035
    @Published var inactivitySeconds = 10
    @Published var includeAudio = true
    @Published private(set) var isRunning = false
    @Published private(set) var isRecordingClip = false
    @Published private(set) var isExporting = false
    @Published private(set) var clipCount = 0
    @Published private(set) var humanDetected = false
    @Published private(set) var statusText = "正在准备摄像头…"
    @Published var errorMessage: String?

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let movementDetector = MovementDetector()
    private let analysisQueue = DispatchQueue(label: "MacIntervalRecorder.human-detection", qos: .userInitiated)
    private var clipURLs: [URL] = []
    private var scheduleTask: Task<Void, Never>?
    private var recordingContinuation: CheckedContinuation<Void, Never>?
    private var powerAssertionID: IOPMAssertionID = 0
    private var hasPowerAssertion = false
    private var sessionConfigured = false
    private var lastMovementAt: Date?

    override init() {
        super.init()
        movementDetector.onResult = { [weak self] personPresent, movementDetected in
            Task { @MainActor in
                self?.handleDetection(personPresent: personPresent, movementDetected: movementDetected)
            }
        }
    }

    func prepare() async {
        let videoAllowed = await requestAccess(for: .video)
        guard videoAllowed else {
            statusText = "没有摄像头权限"
            errorMessage = "请在“系统设置 → 隐私与安全性 → 相机”中允许此应用访问摄像头。"
            return
        }

        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        ).devices

        guard let first = cameras.first else {
            statusText = "未找到摄像头"
            errorMessage = "请连接摄像头后重新启动应用。"
            return
        }
        selectedCameraID = first.uniqueID
        configureSession()
    }

    func startSchedule() async {
        errorMessage = nil
        guard sessionConfigured, !selectedCameraID.isEmpty else {
            errorMessage = "摄像头尚未准备好。"
            return
        }

        if includeAudio {
            let audioAllowed = await requestAccess(for: .audio)
            guard audioAllowed else {
                errorMessage = "未获得麦克风权限。可关闭“录制声音”后再开始，或在系统设置中授权。"
                return
            }
            configureSession()
        }

        isRunning = true
        statusText = recordingMode == .interval ? "定时录制已开始" : "正在等待有人走动…"
        acquirePowerAssertion()

        scheduleTask = Task { [weak self] in
            guard let self else { return }
            if self.recordingMode == .interval {
                while !Task.isCancelled {
                    await self.recordOneTimedClip()
                    if Task.isCancelled { break }
                    self.statusText = "等待下一次录制…"
                    let delay = UInt64(self.intervalMinutes) * 60 * 1_000_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            } else {
                self.movementDetector.movementThreshold = self.movementSensitivity
                self.movementDetector.reset()
                self.movementDetector.isEnabled = true
                while !Task.isCancelled {
                    self.stopMotionClipIfInactive()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
    }

    func stopAndExport() async {
        scheduleTask?.cancel()
        scheduleTask = nil
        movementDetector.isEnabled = false
        movementDetector.reset()
        humanDetected = false
        if movieOutput.isRecording {
            movieOutput.stopRecording()
            while isRecordingClip {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        isRunning = false
        isRecordingClip = false
        releasePowerAssertion()

        guard !clipURLs.isEmpty else {
            statusText = "没有可导出的片段"
            return
        }
        await exportClips()
    }

    func clearClips() {
        for url in clipURLs { try? FileManager.default.removeItem(at: url) }
        clipURLs.removeAll()
        clipCount = 0
        statusText = "片段已清除"
    }

    func shutdown() {
        scheduleTask?.cancel()
        movementDetector.isEnabled = false
        if movieOutput.isRecording { movieOutput.stopRecording() }
        releasePowerAssertion()
        session.stopRunning()
    }

    private func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: mediaType)
        default: return false
        }
    }

    private func configureSession() {
        guard !selectedCameraID.isEmpty,
              let camera = cameras.first(where: { $0.uniqueID == selectedCameraID }) else { return }

        session.beginConfiguration()
        session.sessionPreset = .high
        for input in session.inputs { session.removeInput(input) }

        do {
            let videoInput = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(videoInput) else { throw RecorderError.cannotAddVideo }
            session.addInput(videoInput)

            if includeAudio,
               AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
               let microphone = AVCaptureDevice.default(for: .audio) {
                let audioInput = try AVCaptureDeviceInput(device: microphone)
                if session.canAddInput(audioInput) { session.addInput(audioInput) }
            }

            if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
            }
            if !session.outputs.contains(videoDataOutput), session.canAddOutput(videoDataOutput) {
                videoDataOutput.alwaysDiscardsLateVideoFrames = true
                videoDataOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                videoDataOutput.setSampleBufferDelegate(movementDetector, queue: analysisQueue)
                session.addOutput(videoDataOutput)
            }
            session.commitConfiguration()
            sessionConfigured = true
            if !session.isRunning { session.startRunning() }
            statusText = "准备就绪"
        } catch {
            session.commitConfiguration()
            sessionConfigured = false
            errorMessage = "摄像头配置失败：\(error.localizedDescription)"
        }
    }

    private func recordOneTimedClip() async {
        guard isRunning, !movieOutput.isRecording else { return }
        startClip(status: "正在录制 \(clipSeconds) 秒…")
        statusText = "正在录制 \(clipSeconds) 秒…"

        do {
            try await Task.sleep(nanoseconds: UInt64(clipSeconds) * 1_000_000_000)
        } catch { }
        if movieOutput.isRecording { movieOutput.stopRecording() }
        await waitForCurrentRecording()
    }

    private func startClip(status: String) {
        guard isRunning, !movieOutput.isRecording else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIntervalRecorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("clip-\(UUID().uuidString).mov")
        isRecordingClip = true
        statusText = status
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    private func handleDetection(personPresent: Bool, movementDetected: Bool) {
        guard isRunning, recordingMode == .humanMovement else { return }
        humanDetected = personPresent
        if movementDetected {
            lastMovementAt = Date()
            if !movieOutput.isRecording {
                startClip(status: "检测到有人走动，正在录制…")
            } else {
                statusText = "检测到持续活动，正在录制…"
            }
        } else if !movieOutput.isRecording {
            statusText = personPresent ? "检测到人，等待走动…" : "正在等待有人走动…"
        }
    }

    private func stopMotionClipIfInactive() {
        guard recordingMode == .humanMovement,
              movieOutput.isRecording,
              let lastMovementAt,
              Date().timeIntervalSince(lastMovementAt) >= Double(inactivitySeconds) else { return }
        statusText = "活动停止，正在保存片段…"
        movieOutput.stopRecording()
        self.lastMovementAt = nil
    }

    private func waitForCurrentRecording() async {
        guard isRecordingClip else { return }
        await withCheckedContinuation { continuation in
            recordingContinuation = continuation
        }
    }

    private func exportClips() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "间隔录像-\(Self.timestamp()).mov"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else {
            statusText = "已取消导出，片段仍然保留"
            return
        }

        isExporting = true
        statusText = "正在合并并压缩 \(clipURLs.count) 个片段…"
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }

        do {
            try await VideoMerger.merge(clipURLs, to: destination)
            clearClips()
            statusText = "导出完成：\(destination.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
            statusText = "导出失败，原始片段仍然保留"
        }
        isExporting = false
    }

    private func acquirePowerAssertion() {
        let reason = "Mac Interval Recorder is waiting to capture video" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &powerAssertionID
        )
        hasPowerAssertion = result == kIOReturnSuccess
    }

    private func releasePowerAssertion() {
        if hasPowerAssertion {
            IOPMAssertionRelease(powerAssertionID)
            hasPowerAssertion = false
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

extension RecorderController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.errorMessage = "片段录制失败：\(error.localizedDescription)"
                try? FileManager.default.removeItem(at: outputFileURL)
            } else {
                self.clipURLs.append(outputFileURL)
                self.clipCount = self.clipURLs.count
            }
            self.isRecordingClip = false
            self.recordingContinuation?.resume()
            self.recordingContinuation = nil
            if self.isRunning, self.recordingMode == .humanMovement {
                self.statusText = "正在等待有人走动…"
            }
        }
    }
}

private enum RecorderError: LocalizedError {
    case cannotAddVideo
    var errorDescription: String? { "无法将所选摄像头添加到捕捉会话。" }
}
