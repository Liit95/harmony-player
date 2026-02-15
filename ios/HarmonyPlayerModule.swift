/**
 * HarmonyPlayerModule - Expo Module for HarmonyAudioEngine
 *
 * Provides a native module API for:
 * - Playback control (play, pause, stop, seek, volume)
 * - Source loading (URL, file, Deezer encrypted track)
 * - Gapless preloading
 * - Now Playing info
 * - State queries (position, duration, state) — sync via JSI
 * - Event emission (state changes, progress, track ended, errors)
 */

import ExpoModulesCore
import SFBAudioEngine

public class HarmonyPlayerModule: Module {

    private let engine = HarmonyAudioEngine.shared

    public func definition() -> ModuleDefinition {
        Name("HarmonyPlayer")

        Events("onStateChanged", "onProgress", "onTrackEnded", "onError", "onRemoteCommand", "onPreloadReady")

        OnStartObserving { self.engine.delegate = self }
        OnStopObserving  { self.engine.delegate = nil }

        // MARK: - Lifecycle

        AsyncFunction("initialize") {
            self.engine.initialize()
        }

        // MARK: - Playback Control (sync — fire-and-forget)

        Function("play")  { self.engine.play() }
        Function("pause") { self.engine.pause() }
        Function("stop")  { self.engine.stop() }

        Function("seekTo") { (ms: Double) in
            self.engine.seekTo(ms: ms)
        }

        Function("setVolume") { (vol: Float) in
            self.engine.setVolume(vol)
        }

        // MARK: - Source Loading (async)

        AsyncFunction("openURL") { (url: String, promise: Promise) in
            self.engine.openURL(url) { error in
                if let error {
                    promise.reject(error)
                } else {
                    promise.resolve(nil)
                }
            }
        }

        AsyncFunction("openFile") { (path: String) in
            try self.engine.openFile(path)
        }

        AsyncFunction("openDeezerTrack") { (trackId: String, encUrl: String, contentLength: Int, contentType: String) in
            try self.engine.openDeezerTrack(
                trackId: trackId,
                encUrl: encUrl,
                contentLength: Int64(contentLength),
                contentType: contentType
            )
        }

        // MARK: - Gapless Preload (async)

        AsyncFunction("preloadURL") { (url: String, promise: Promise) in
            self.engine.preloadURL(url) { error in
                if let error {
                    promise.reject(error)
                } else {
                    promise.resolve(nil)
                }
            }
        }

        AsyncFunction("preloadFile") { (path: String) in
            try self.engine.preloadFile(path)
        }

        AsyncFunction("preloadDeezerTrack") { (trackId: String, encUrl: String, contentLength: Int, contentType: String) in
            try self.engine.preloadDeezerTrack(
                trackId: trackId,
                encUrl: encUrl,
                contentLength: Int64(contentLength),
                contentType: contentType
            )
        }

        // MARK: - State Queries (sync — no forced Promise like RCT bridge)

        Function("getPositionMs") {
            return self.engine.getPositionMs()
        }

        Function("getDurationMs") {
            return self.engine.getDurationMs()
        }

        Function("getState") {
            return self.engine.getState().rawValue
        }

        // MARK: - Now Playing (sync)

        Function("updateNowPlaying") { (title: String, artist: String, album: String, artwork: String, duration: Double) in
            self.engine.updateNowPlaying(
                title: title,
                artist: artist,
                album: album,
                artwork: artwork,
                duration: duration
            )
        }

        Function("setHalveDuration") { (enabled: Bool) in
            self.engine.setHalveDuration(enabled)
        }

        // MARK: - Audio Remuxer (rewrites MP4 containers)

        AsyncFunction("remux") { (inputPath: String, outputPath: String, promise: Promise) in
            AudioRemuxer.remux(inputPath: inputPath, outputPath: outputPath) { error in
                if let error {
                    promise.reject(error)
                } else {
                    promise.resolve(nil)
                }
            }
        }
    }
}

// MARK: - HarmonyAudioEngineDelegate

extension HarmonyPlayerModule: HarmonyAudioEngineDelegate {

    func onStateChanged(_ state: HarmonyPlaybackState) {
        sendEvent("onStateChanged", ["state": state.rawValue])
    }

    func onProgress(positionMs: Double, durationMs: Double, bufferedMs: Double) {
        sendEvent("onProgress", [
            "position": positionMs,
            "duration": durationMs,
            "buffered": bufferedMs,
        ])
    }

    func onTrackEnded() {
        sendEvent("onTrackEnded", [:])
    }

    func onError(_ message: String) {
        sendEvent("onError", ["message": message])
    }

    func onPreloadReady() {
        sendEvent("onPreloadReady", [:])
    }
}
