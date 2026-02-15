/**
 * AudioRemuxer - Rewrite MP4/fMP4 containers using AVAssetExportSession
 *
 * YouTube/Invidious audio files have broken containers (duration ~2x real,
 * fragmented MP4). Remuxing with passthrough preset rewrites the moov atom
 * and produces a correct .m4a container (~200ms for a 3MB file).
 */

import AVFoundation

class AudioRemuxer {

    enum RemuxError: LocalizedError {
        case exportSessionCreationFailed
        case exportFailed(String)
        case exportCancelled

        var errorDescription: String? {
            switch self {
            case .exportSessionCreationFailed:
                return "Failed to create AVAssetExportSession"
            case .exportFailed(let reason):
                return "Export failed: \(reason)"
            case .exportCancelled:
                return "Export was cancelled"
            }
        }
    }

    /// Convert a path or file:// URI string to a file URL
    private static func fileURL(from pathOrUri: String) -> URL {
        if pathOrUri.hasPrefix("file://") {
            return URL(string: pathOrUri) ?? URL(fileURLWithPath: pathOrUri)
        }
        return URL(fileURLWithPath: pathOrUri)
    }

    static func remux(inputPath: String, outputPath: String, completion: @escaping (Error?) -> Void) {
        let inputURL = fileURL(from: inputPath)
        let outputURL = fileURL(from: outputPath)

        // Remove existing output file if present
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: inputURL)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            completion(RemuxError.exportSessionCreationFailed)
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a

        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                completion(nil)
            case .cancelled:
                completion(RemuxError.exportCancelled)
            case .failed:
                completion(exportSession.error ?? RemuxError.exportFailed("Unknown error"))
            default:
                completion(RemuxError.exportFailed("Unexpected status: \(exportSession.status.rawValue)"))
            }
        }
    }
}
