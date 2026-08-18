import AVFoundation
import SwiftUI

final class PreviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer()
        preview.videoGravity = .resizeAspectFill
        layer = preview
    }

    required init?(coder: NSCoder) { nil }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.previewLayer.session = session
    }
}

