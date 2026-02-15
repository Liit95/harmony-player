/**
 * DeezerResourceLoaderRegistry - Singleton track info registry
 *
 * JS registers encrypted URL + metadata before passing a deezer-enc:// URL
 * to TrackPlayer. The resource loader delegate looks up this info when
 * AVPlayer requests data.
 */

import Foundation

struct DeezerTrackInfo {
    let trackId: String
    let encryptedUrl: URL
    let contentLength: Int64
    let contentType: String
}

class DeezerResourceLoaderRegistry {

    static let shared = DeezerResourceLoaderRegistry()

    private var tracks: [String: DeezerTrackInfo] = [:]
    private let lock = NSLock()

    private init() {}

    func register(trackId: String, encryptedUrl: String, contentLength: Int64, contentType: String) {
        guard let url = URL(string: encryptedUrl) else {
            print("[DeezerRegistry] Invalid URL for track \(trackId)")
            return
        }

        let info = DeezerTrackInfo(
            trackId: trackId,
            encryptedUrl: url,
            contentLength: contentLength,
            contentType: contentType
        )

        lock.lock()
        tracks[trackId] = info
        lock.unlock()

        print("[DeezerRegistry] Registered track: \(trackId) (\(contentType), \(contentLength) bytes)")
    }

    func lookup(trackId: String) -> DeezerTrackInfo? {
        lock.lock()
        let info = tracks[trackId]
        lock.unlock()
        return info
    }

    func unregister(trackId: String) {
        lock.lock()
        tracks.removeValue(forKey: trackId)
        lock.unlock()
        print("[DeezerRegistry] Unregistered track: \(trackId)")
    }
}
