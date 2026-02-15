/**
 * DownloadBridgeModule - Expo Module for Background Downloads
 *
 * Exposes native download functionality to JavaScript:
 * - enqueue(taskId, url, trackId, provider, format, artworkUrl, metadata)
 * - enqueueBatch(tasks)
 * - cancel(taskId)
 * - clearTask(taskId)
 * - cancelAll()
 * - getDownloads()
 *
 * Emits events:
 * - onDownloadProgress(taskId, progress)
 * - onDownloadComplete(taskId, filePath, artworkPath, fileSize, format)
 * - onDownloadError(taskId, error)
 */

import ExpoModulesCore

public class DownloadBridgeModule: Module {

    public func definition() -> ModuleDefinition {
        Name("DownloadBridge")

        Events("onDownloadProgress", "onDownloadComplete", "onDownloadError")

        OnStartObserving {
            self.setupCallbacks()
        }

        OnStopObserving {
            let manager = DownloadManager.shared
            manager.onProgress = nil
            manager.onComplete = nil
            manager.onError = nil
        }

        // MARK: - Enqueue

        AsyncFunction("enqueue") { (taskId: String, url: String, trackId: String, provider: String, format: String, artworkUrl: String?, metadata: [String: Any]) in
            let meta = DownloadManager.TrackMeta(
                title: metadata["title"] as? String ?? "Unknown",
                artist: metadata["artist"] as? String ?? "Unknown",
                album: metadata["album"] as? String ?? "Unknown",
                duration: (metadata["duration"] as? Double) ?? 0,
                thumbnail: metadata["thumbnail"] as? String
            )

            DownloadManager.shared.enqueue(
                taskId: taskId,
                url: url,
                trackId: trackId,
                provider: provider,
                format: format,
                artworkUrl: artworkUrl,
                metadata: meta
            )

            return ["success": true]
        }

        // MARK: - Enqueue Batch

        AsyncFunction("enqueueBatch") { (tasks: [[String: Any]]) in
            DownloadManager.shared.enqueueBatch(tasks)
            return ["success": true]
        }

        // MARK: - Cancel

        AsyncFunction("cancel") { (taskId: String) in
            DownloadManager.shared.cancel(taskId: taskId)
            return ["success": true]
        }

        // MARK: - Clear Task

        AsyncFunction("clearTask") { (taskId: String) in
            DownloadManager.shared.clearTask(taskId: taskId)
            return ["success": true]
        }

        // MARK: - Cancel All

        AsyncFunction("cancelAll") {
            DownloadManager.shared.cancelAll()
            return ["success": true]
        }

        // MARK: - Get Downloads

        AsyncFunction("getDownloads") {
            return DownloadManager.shared.getDownloads()
        }
    }

    // MARK: - Setup Callbacks

    private func setupCallbacks() {
        let manager = DownloadManager.shared

        manager.onProgress = { [weak self] taskId, progress in
            self?.sendEvent("onDownloadProgress", [
                "taskId": taskId,
                "progress": progress,
            ])
        }

        manager.onComplete = { [weak self] taskId, filePath, artworkPath, fileSize, format in
            var body: [String: Any] = [
                "taskId": taskId,
                "filePath": filePath,
                "fileSize": fileSize,
                "format": format,
            ]
            if let ap = artworkPath {
                body["artworkPath"] = ap
            }
            self?.sendEvent("onDownloadComplete", body)
        }

        manager.onError = { [weak self] taskId, error in
            self?.sendEvent("onDownloadError", [
                "taskId": taskId,
                "error": error,
            ])
        }
    }
}
