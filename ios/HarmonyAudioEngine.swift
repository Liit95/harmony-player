/**
 * HarmonyAudioEngine - Core audio engine wrapper around SFBAudioEngine
 *
 * Singleton that manages:
 * - SFBAudioPlayer for playback (gapless via decoder queue)
 * - AVAudioSession configuration
 * - MPRemoteCommandCenter (play/pause/next/prev/seek)
 * - MPNowPlayingInfoCenter
 * - Progress timer for JS event emission
 * - Custom InputSources for Deezer (decrypt) and HTTP progressive streams
 */

import AVFoundation
import MediaPlayer
import SFBAudioEngine

// MARK: - Playback State

enum HarmonyPlaybackState: String {
    case idle
    case playing
    case paused
    case stopped
    case error
}

// MARK: - Event Delegate

protocol HarmonyAudioEngineDelegate: AnyObject {
    func onStateChanged(_ state: HarmonyPlaybackState)
    func onProgress(positionMs: Double, durationMs: Double, bufferedMs: Double)
    func onTrackEnded()
    func onError(_ message: String)
    func onPreloadReady()
}

// MARK: - Engine

class HarmonyAudioEngine: NSObject {

    static let shared = HarmonyAudioEngine()

    weak var delegate: HarmonyAudioEngineDelegate?

    private var player: AudioPlayer!
    private var progressTimer: Timer?
    private var state: HarmonyPlaybackState = .idle

    // Now Playing metadata
    private var nowPlayingTitle: String = ""
    private var nowPlayingArtist: String = ""
    private var nowPlayingAlbum: String = ""
    private var nowPlayingArtworkURL: String = ""
    private var nowPlayingDuration: Double = 0
    private var halveDuration: Bool = false

    // Preload state
    private var preloadedDecoder: (any PCMDecoding)?
    private var hasPreload: Bool = false

    // MARK: - Initialization

    private override init() {
        super.init()
    }

    func initialize() {
        guard player == nil else { return }

        player = AudioPlayer()
        player.delegate = self

        // AVAudioSession, MPRemoteCommandCenter, and Timer require main thread
        let setup = { [self] in
            configureAudioSession()
            configureRemoteCommands()
            startProgressTimer()
        }

        if Thread.isMainThread {
            setup()
        } else {
            DispatchQueue.main.sync { setup() }
        }

        print("[HarmonyEngine] Initialized")
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            print("[HarmonyEngine] Audio session error: \(error)")
        }
    }

    // MARK: - Remote Commands

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.player.isPlaying {
                self.pause()
            } else {
                self.play()
            }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.delegate?.onTrackEnded()
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { _ in
            // Handled by JS — emits remote command event
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.seekTo(ms: event.positionTime * 1000)
            return .success
        }
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.emitProgress()
        }
    }

    private func emitProgress() {
        guard player != nil, player.isPlaying || player.isPaused else { return }

        let positionMs = getPositionMs()
        let durationMs = getDurationMs()

        delegate?.onProgress(positionMs: positionMs, durationMs: durationMs, bufferedMs: durationMs)
        updateNowPlayingElapsedTime()
    }

    // MARK: - Playback Control

    func play() {
        guard let player else { return }
        do {
            if player.isPaused {
                player.resume()
            } else if player.isStopped, player.isReady {
                try player.play()
            }
            updateState(.playing)
        } catch {
            print("[HarmonyEngine] Play error: \(error)")
            delegate?.onError(error.localizedDescription)
        }
    }

    func pause() {
        guard let player else { return }
        player.pause()
        updateState(.paused)
    }

    func stop() {
        guard let player else { return }
        player.stop()
        clearPreload()
        updateState(.stopped)
    }

    func seekTo(ms: Double) {
        guard let player else { return }
        let seconds = ms / 1000.0
        player.seek(time: seconds)
        updateNowPlayingElapsedTime()
    }

    func setVolume(_ vol: Float) {
        // SFBAudioEngine volume is macOS-only; use AVAudioSession on iOS
        // Volume on iOS is system-controlled; this is a no-op
    }

    // MARK: - Open Sources

    func openURL(_ urlString: String, completion: @escaping (Error?) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(NSError(domain: "HarmonyEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }

        clearPreload()
        player.stop()

        if url.scheme == "http" || url.scheme == "https" {
            // Download to temp file first, then play from disk (no blocking semaphores)
            downloadAndPlay(url: url, completion: completion)
        } else {
            do {
                try player.play(url)
                updateState(.playing)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    private func downloadAndPlay(url: URL, completion: @escaping (Error?) -> Void) {
        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: url) { [self] tempURL, response, error in
            defer { session.finishTasksAndInvalidate() }

            if let error {
                print("[HarmonyEngine] Download failed: \(error.localizedDescription)")
                completion(error)
                return
            }

            guard let tempURL else {
                completion(NSError(domain: "HarmonyEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download returned no file"]))
                return
            }

            // Move to a persistent temp path (the system temp is deleted after the callback)
            let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: tempURL, to: dest)
                try player.play(dest)
                updateState(.playing)
                print("[HarmonyEngine] Playing downloaded: \(url.lastPathComponent) (\((response as? HTTPURLResponse)?.expectedContentLength ?? 0) bytes)")
                completion(nil)
            } catch {
                try? FileManager.default.removeItem(at: dest)
                print("[HarmonyEngine] Play after download failed: \(error)")
                completion(error)
            }
        }
        task.resume()
    }

    func openFile(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        clearPreload()
        player.stop()
        try player.play(url)
        updateState(.playing)
    }

    func openDeezerTrack(trackId: String, encUrl: String, contentLength: Int64, contentType: String) throws {
        clearPreload()
        player.stop()

        guard let decoder = try HarmonyDecoderFactory.decoder(forDeezerTrackId: trackId,
                                                               encryptedUrl: encUrl,
                                                               contentLength: contentLength,
                                                               contentType: contentType) as? AudioDecoder else {
            throw NSError(domain: "HarmonyEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create Deezer decoder"])
        }
        try player.play(decoder)

        updateState(.playing)
    }

    // MARK: - Gapless Preload

    func preloadURL(_ urlString: String, completion: @escaping (Error?) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(NSError(domain: "HarmonyEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }

        clearPreload()

        if url.scheme == "http" || url.scheme == "https" {
            let session = URLSession(configuration: .default)
            let task = session.downloadTask(with: url) { [self] tempURL, _, error in
                defer { session.finishTasksAndInvalidate() }

                if let error {
                    completion(error)
                    return
                }
                guard let tempURL else {
                    completion(NSError(domain: "HarmonyEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Preload download returned no file"]))
                    return
                }

                let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    try player.enqueue(dest)
                    hasPreload = true
                    delegate?.onPreloadReady()
                    print("[HarmonyEngine] Preloaded downloaded: \(url.lastPathComponent)")
                    completion(nil)
                } catch {
                    try? FileManager.default.removeItem(at: dest)
                    completion(error)
                }
            }
            task.resume()
        } else {
            do {
                try player.enqueue(url)
                hasPreload = true
                delegate?.onPreloadReady()
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func preloadFile(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        clearPreload()
        try player.enqueue(url)
        hasPreload = true
        delegate?.onPreloadReady()
    }

    func preloadDeezerTrack(trackId: String, encUrl: String, contentLength: Int64, contentType: String) throws {
        clearPreload()

        guard let decoder = try HarmonyDecoderFactory.decoder(forDeezerTrackId: trackId,
                                                               encryptedUrl: encUrl,
                                                               contentLength: contentLength,
                                                               contentType: contentType) as? AudioDecoder else {
            throw NSError(domain: "HarmonyEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create Deezer decoder"])
        }
        try player.enqueue(decoder)
        preloadedDecoder = decoder
        hasPreload = true
        delegate?.onPreloadReady()
    }

    private func clearPreload() {
        if hasPreload {
            player.clearQueue()
        }
        preloadedDecoder = nil
        hasPreload = false
    }

    // MARK: - State Queries

    func getPositionMs() -> Double {
        guard let player, let time = player.currentTime else { return 0 }
        return time * 1000.0
    }

    func getDurationMs() -> Double {
        guard let player, let time = player.totalTime else { return 0 }
        return time * 1000.0
    }

    func getState() -> HarmonyPlaybackState {
        return state
    }

    // MARK: - Now Playing

    func updateNowPlaying(title: String, artist: String, album: String, artwork: String, duration: Double) {
        nowPlayingTitle = title
        nowPlayingArtist = artist
        nowPlayingAlbum = album
        nowPlayingArtworkURL = artwork
        nowPlayingDuration = duration

        let publish = { [self] in
            let info: [String: Any] = [
                MPMediaItemPropertyTitle: title,
                MPMediaItemPropertyArtist: artist,
                MPMediaItemPropertyAlbumTitle: album,
                MPMediaItemPropertyPlaybackDuration: halveDuration ? duration / 2.0 : duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: (player?.currentTime ?? 0),
                MPNowPlayingInfoPropertyPlaybackRate: player?.isPlaying == true ? 1.0 : 0.0,
            ]

            MPNowPlayingInfoCenter.default().nowPlayingInfo = info

            // Load artwork async
            if !artwork.isEmpty, let artworkURL = URL(string: artwork) {
                loadArtwork(from: artworkURL) { image in
                    guard let image else { return }
                    var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? info
                    let mpArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    updated[MPMediaItemPropertyArtwork] = mpArtwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
                }
            }
        }

        if Thread.isMainThread { publish() } else { DispatchQueue.main.async { publish() } }
    }

    func setHalveDuration(_ enabled: Bool) {
        halveDuration = enabled
        // Re-publish now playing with corrected duration
        if !nowPlayingTitle.isEmpty {
            updateNowPlaying(title: nowPlayingTitle, artist: nowPlayingArtist,
                           album: nowPlayingAlbum, artwork: nowPlayingArtworkURL,
                           duration: nowPlayingDuration)
        }
    }

    private func updateNowPlayingElapsedTime() {
        let update = { [self] in
            guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = (player?.currentTime ?? 0)
            info[MPNowPlayingInfoPropertyPlaybackRate] = player?.isPlaying == true ? 1.0 : 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async { update() } }
    }

    private func loadArtwork(from url: URL, completion: @escaping (UIImage?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async {
                if let data, let image = UIImage(data: data) {
                    completion(image)
                } else {
                    completion(nil)
                }
            }
        }.resume()
    }

    // MARK: - State Management

    private func updateState(_ newState: HarmonyPlaybackState) {
        guard state != newState else { return }
        state = newState
        delegate?.onStateChanged(newState)
    }
}

// MARK: - AudioPlayer.Delegate

extension HarmonyAudioEngine: AudioPlayer.Delegate {

    func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
        switch playbackState {
        case .playing:
            updateState(.playing)
        case .paused:
            updateState(.paused)
        case .stopped:
            updateState(.stopped)
        @unknown default:
            break
        }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, nowPlayingChanged nowPlaying: (any PCMDecoding)?, previouslyPlaying: (any PCMDecoding)?) {
        // Gapless transition detected — the player auto-advanced to the next decoder
        if nowPlaying != nil && previouslyPlaying != nil && hasPreload {
            hasPreload = false
            preloadedDecoder = nil
            print("[HarmonyEngine] Gapless transition detected")
            delegate?.onTrackEnded()
        }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, endOfAudio decoder: any PCMDecoding) {
        // End of audio — if no preloaded decoder, this means the queue is done
        if !hasPreload {
            print("[HarmonyEngine] End of audio")
            delegate?.onTrackEnded()
        }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: any Error) {
        print("[HarmonyEngine] Error: \(error)")
        updateState(.error)
        delegate?.onError(error.localizedDescription)
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, decoderCanceled decoder: any PCMDecoding, framesRendered: AVAudioFramePosition) {
        print("[HarmonyEngine] Decoder canceled, framesRendered: \(framesRendered)")
    }
}
