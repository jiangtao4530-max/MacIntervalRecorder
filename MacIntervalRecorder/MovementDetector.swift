@preconcurrency import AVFoundation
@preconcurrency import Vision

final class MovementDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onResult: ((Bool, Bool) -> Void)?
    var movementThreshold: CGFloat = 0.035
    var isEnabled = false

    private var lastAnalysisTime = CMTime.invalid
    private var previousCenters: [CGPoint] = []

    func reset() {
        previousCenters = []
        lastAnalysisTime = .invalid
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isEnabled else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastAnalysisTime.isValid,
           CMTimeGetSeconds(CMTimeSubtract(timestamp, lastAnalysisTime)) < 0.25 {
            return
        }
        lastAnalysisTime = timestamp

        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        do {
            let handler = VNImageRequestHandler(
                cmSampleBuffer: sampleBuffer,
                orientation: .up,
                options: [:]
            )
            try handler.perform([request])
            let boxes = request.results ?? []
            let centers = boxes.map {
                CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)
            }
            let moved = movementDetected(from: previousCenters, to: centers)
            previousCenters = centers
            onResult?(!centers.isEmpty, moved)
        } catch {
            onResult?(false, false)
        }
    }

    private func movementDetected(from old: [CGPoint], to new: [CGPoint]) -> Bool {
        guard !new.isEmpty else { return false }
        // A newly appearing person is treated as movement so entry is captured.
        guard !old.isEmpty else { return true }

        for point in new {
            let nearestDistance = old.map {
                hypot(point.x - $0.x, point.y - $0.y)
            }.min() ?? .greatestFiniteMagnitude
            if nearestDistance >= movementThreshold { return true }
        }
        return new.count != old.count
    }
}
