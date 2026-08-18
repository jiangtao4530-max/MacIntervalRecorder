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

        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: cursor)
            if cursor == .zero {
                preferredTransform = try await sourceVideo.load(.preferredTransform)
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
        videoTrack.preferredTransform = preferredTransform

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw MergeError.cannotCreateExporter
        }
        exporter.outputURL = destination
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = true

        await exporter.export()
        if let error = exporter.error { throw error }
        guard exporter.status == .completed else { throw MergeError.exportFailed }
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

