@preconcurrency import AVFoundation

enum VideoMerger {
    static func merge(_ urls: [URL], to destination: URL) async throws {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw MergeError.cannotCreateTrack }

        var audioTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var preferredTransform = CGAffineTransform.identity
        var naturalSize = CGSize(width: 1280, height: 720)

        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: cursor)
            if cursor == .zero {
                preferredTransform = try await sourceVideo.load(.preferredTransform)
                naturalSize = try await sourceVideo.load(.naturalSize)
            }

            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                if audioTrack == nil {
                    audioTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                try audioTrack?.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: sourceAudio,
                    at: cursor
                )
            }
            cursor = CMTimeAdd(cursor, duration)
        }

        guard cursor > .zero else { throw MergeError.noVideo }
        let videoComposition = makeBalancedVideoComposition(
            track: videoTrack,
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            duration: cursor
        )

        // The HEVC preset provides substantially smaller files. The custom video
        // composition constrains the output to a maximum of 1280 x 720.
        let preferredPreset = AVAssetExportPresetHEVC1920x1080
        let fallbackPreset = AVAssetExportPreset1280x720
        let preset = AVAssetExportSession(asset: composition, presetName: preferredPreset) != nil
            ? preferredPreset
            : fallbackPreset

        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw MergeError.cannotCreateExporter
        }
        exporter.outputURL = destination
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition = videoComposition

        await exporter.export()
        if let error = exporter.error { throw error }
        guard exporter.status == .completed else { throw MergeError.exportFailed }
    }

    private static func makeBalancedVideoComposition(
        track: AVMutableCompositionTrack,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        duration: CMTime
    ) -> AVMutableVideoComposition {
        let transformedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
        let orientedSize = CGSize(
            width: abs(transformedRect.width),
            height: abs(transformedRect.height)
        )
        let scale = min(
            1.0,
            min(1280.0 / max(orientedSize.width, 1), 720.0 / max(orientedSize.height, 1))
        )
        let width = max(2, floor(orientedSize.width * scale / 2) * 2)
        let height = max(2, floor(orientedSize.height * scale / 2) * 2)

        var transform = preferredTransform
        transform = transform.concatenating(
            CGAffineTransform(translationX: -transformedRect.minX, y: -transformedRect.minY)
        )
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(transform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: width, height: height)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]
        return composition
    }
}

private enum MergeError: LocalizedError {
    case cannotCreateTrack, noVideo, cannotCreateExporter, exportFailed

    var errorDescription: String? {
        switch self {
        case .cannotCreateTrack: return "无法创建视频轨道。"
        case .noVideo: return "片段中没有可用视频。"
        case .cannotCreateExporter: return "无法创建视频导出器。"
        case .exportFailed: return "视频导出未完成。"
        }
    }
}
