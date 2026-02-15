/**
 * DownloadManager - Background download service for iOS
 *
 * Uses NSURLSession with background configuration so downloads
 * continue even when the app is suspended or terminated.
 *
 * Features:
 * - Persistent task queue (UserDefaults)
 * - Deezer decryption post-download (via DeezerDecrypt)
 * - Artwork downloading
 * - Progress/completion/error callbacks
 */

import Foundation

class DownloadManager: NSObject {

    // MARK: - Singleton

    static let shared = DownloadManager()

    // MARK: - Types

    enum TaskStatus: String, Codable {
        case pending
        case downloading
        case decrypting
        case completed
        case error
    }

    struct TrackMeta: Codable {
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let thumbnail: String?
    }

    struct DownloadTaskInfo: Codable {
        let taskId: String          // composite key "provider:trackId"
        let url: String             // media URL
        let trackId: String         // raw track ID (for decryption key)
        let provider: String        // "deezer" | "youtube"
        let format: String          // "MP3_320", "FLAC", "MP3"
        let artworkUrl: String?     // thumbnail URL
        let metadata: TrackMeta
        var status: TaskStatus
        var urlSessionTaskId: Int?
        var filePath: String?
        var artworkPath: String?
        var fileSize: Int64?
        var error: String?
    }

    // MARK: - Callbacks

    var onProgress: ((String, Double) -> Void)?
    var onComplete: ((String, String, String?, Int64, String) -> Void)?
    var onError: ((String, String) -> Void)?

    // MARK: - Properties

    private let sessionIdentifier = "com.lit95.harmony.downloads"
    private let storageKey = "harmony.download.tasks"
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.httpMaximumConnectionsPerHost = 2
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var tasks: [String: DownloadTaskInfo] = [:]
    private var taskIdMap: [Int: String] = [:] // URLSession taskId → our taskId
    private var backgroundCompletionHandler: (() -> Void)?
    private let queue = DispatchQueue(label: "com.lit95.harmony.downloadmanager", qos: .utility)

    // MARK: - Directories

    private var tracksDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("downloads/tracks", isDirectory: true)
    }

    private var artworkDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("downloads/artwork", isDirectory: true)
    }

    // MARK: - Init

    private override init() {
        super.init()
        ensureDirectories()
        loadTasks()
        // Recreate URLSession to pick up any pending background events
        _ = urlSession
        reconnectTasks()
    }

    // MARK: - Background Completion

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    // MARK: - Directory Setup

    private func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)
    }

    // MARK: - Persistence

    private func loadTasks() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([String: DownloadTaskInfo].self, from: data) else {
            return
        }
        tasks = saved
        // Rebuild taskIdMap from persisted urlSessionTaskId
        for (taskId, info) in tasks {
            if let sessionId = info.urlSessionTaskId {
                taskIdMap[sessionId] = taskId
            }
        }
    }

    private func saveTasks() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Reconnect persisted tasks that were downloading when app was killed
    private func reconnectTasks() {
        urlSession.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
            guard let self = self else { return }
            self.queue.async {
                let activeSessionIds = Set(downloadTasks.map { $0.taskIdentifier })
                for (taskId, var info) in self.tasks {
                    if info.status == .downloading || info.status == .pending {
                        if let sessionId = info.urlSessionTaskId, activeSessionIds.contains(sessionId) {
                            // Task is still active in URLSession — keep it
                            continue
                        }
                        // Task was lost — re-enqueue if pending/downloading
                        if info.status == .downloading {
                            info.status = .pending
                            info.urlSessionTaskId = nil
                            self.tasks[taskId] = info
                        }
                    }
                }
                self.saveTasks()
                self.processQueue()
            }
        }
    }

    // MARK: - Public API

    func enqueue(
        taskId: String,
        url: String,
        trackId: String,
        provider: String,
        format: String,
        artworkUrl: String?,
        metadata: TrackMeta
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }

            // Skip if already exists
            if self.tasks[taskId] != nil { return }

            let info = DownloadTaskInfo(
                taskId: taskId,
                url: url,
                trackId: trackId,
                provider: provider,
                format: format,
                artworkUrl: artworkUrl,
                metadata: metadata,
                status: .pending,
                urlSessionTaskId: nil,
                filePath: nil,
                artworkPath: nil,
                fileSize: nil,
                error: nil
            )

            self.tasks[taskId] = info
            self.saveTasks()
            self.processQueue()
        }
    }

    func enqueueBatch(_ batch: [[String: Any]]) {
        queue.async { [weak self] in
            guard let self = self else { return }

            for item in batch {
                guard let taskId = item["taskId"] as? String,
                      let url = item["url"] as? String,
                      let trackId = item["trackId"] as? String,
                      let provider = item["provider"] as? String,
                      let format = item["format"] as? String else { continue }

                if self.tasks[taskId] != nil { continue }

                let artworkUrl = item["artworkUrl"] as? String
                let metaDict = item["metadata"] as? [String: Any] ?? [:]
                let meta = TrackMeta(
                    title: metaDict["title"] as? String ?? "Unknown",
                    artist: metaDict["artist"] as? String ?? "Unknown",
                    album: metaDict["album"] as? String ?? "Unknown",
                    duration: metaDict["duration"] as? Double ?? 0,
                    thumbnail: metaDict["thumbnail"] as? String
                )

                let info = DownloadTaskInfo(
                    taskId: taskId,
                    url: url,
                    trackId: trackId,
                    provider: provider,
                    format: format,
                    artworkUrl: artworkUrl,
                    metadata: meta,
                    status: .pending,
                    urlSessionTaskId: nil,
                    filePath: nil,
                    artworkPath: nil,
                    fileSize: nil,
                    error: nil
                )

                self.tasks[taskId] = info
            }

            self.saveTasks()
            self.processQueue()
        }
    }

    func cancel(taskId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let info = self.tasks[taskId] else { return }

            // Cancel URLSession task if active
            if let sessionTaskId = info.urlSessionTaskId {
                self.urlSession.getTasksWithCompletionHandler { _, _, downloadTasks in
                    for task in downloadTasks where task.taskIdentifier == sessionTaskId {
                        task.cancel()
                    }
                }
            }

            self.tasks.removeValue(forKey: taskId)
            if let sid = info.urlSessionTaskId {
                self.taskIdMap.removeValue(forKey: sid)
            }
            self.saveTasks()
        }
    }

    func cancelAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.urlSession.getTasksWithCompletionHandler { _, _, downloadTasks in
                for task in downloadTasks {
                    task.cancel()
                }
            }
            self.tasks.removeAll()
            self.taskIdMap.removeAll()
            self.saveTasks()
        }
    }

    /// Remove a failed task from persistence so it can be re-enqueued
    func clearTask(taskId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let info = self.tasks[taskId], let sid = info.urlSessionTaskId {
                self.taskIdMap.removeValue(forKey: sid)
            }
            self.tasks.removeValue(forKey: taskId)
            self.saveTasks()
        }
    }

    func getDownloads() -> [[String: Any]] {
        return queue.sync {
            return tasks.values.map { info in
                var dict: [String: Any] = [
                    "taskId": info.taskId,
                    "provider": info.provider,
                    "format": info.format,
                    "status": info.status.rawValue,
                    "metadata": [
                        "title": info.metadata.title,
                        "artist": info.metadata.artist,
                        "album": info.metadata.album,
                        "duration": info.metadata.duration,
                    ],
                ]
                if let fp = info.filePath { dict["filePath"] = fp }
                if let ap = info.artworkPath { dict["artworkPath"] = ap }
                if let fs = info.fileSize { dict["fileSize"] = fs }
                if let err = info.error { dict["error"] = err }
                return dict
            }
        }
    }

    // MARK: - Queue Processing

    private func processQueue() {
        // Count active downloads
        let activeCount = tasks.values.filter { $0.status == .downloading }.count
        guard activeCount < 2 else { return }

        // Find next pending task
        let slotsAvailable = 2 - activeCount
        let pending = tasks.values
            .filter { $0.status == .pending }
            .sorted { $0.taskId < $1.taskId }
            .prefix(slotsAvailable)

        for info in pending {
            startDownload(info)
        }
    }

    private func startDownload(_ info: DownloadTaskInfo) {
        guard let url = URL(string: info.url) else {
            failTask(info.taskId, error: "Invalid URL")
            return
        }

        let request = URLRequest(url: url)
        let downloadTask = urlSession.downloadTask(with: request)

        var updatedInfo = info
        updatedInfo.status = .downloading
        updatedInfo.urlSessionTaskId = downloadTask.taskIdentifier
        tasks[info.taskId] = updatedInfo
        taskIdMap[downloadTask.taskIdentifier] = info.taskId

        saveTasks()
        downloadTask.resume()

        print("[DownloadManager] Started download: \(info.taskId)")
    }

    // MARK: - Post-Download Processing

    private func processCompletedDownload(taskId: String, tempLocation: URL) {
        guard var info = tasks[taskId] else { return }

        let ext: String
        if info.provider == "deezer" {
            ext = info.format == "FLAC" ? "flac" : "mp3"
        } else {
            ext = info.format == "M4A" ? "m4a" : "mp3"
        }
        let prefix = info.provider == "deezer" ? "deezer" : "youtube"
        let destURL = tracksDir.appendingPathComponent("\(prefix)_\(info.trackId).\(ext)")

        do {
            if info.provider == "deezer" {
                // Decrypt Deezer file
                info.status = .decrypting
                tasks[taskId] = info
                saveTasks()

                let encryptedData = try Data(contentsOf: tempLocation)
                let decryptedData = DeezerDecrypt.decryptTrack(
                    trackId: info.trackId,
                    encryptedData: encryptedData
                )

                // Remove destination if it already exists
                try? FileManager.default.removeItem(at: destURL)
                try decryptedData.write(to: destURL)
            } else {
                // YouTube/SABR — remux fMP4 container to fix seek/duration, then save
                try? FileManager.default.removeItem(at: destURL)

                let semaphore = DispatchSemaphore(value: 0)
                var remuxError: Error? = nil

                AudioRemuxer.remux(inputPath: tempLocation.path, outputPath: destURL.path) { error in
                    remuxError = error
                    semaphore.signal()
                }
                semaphore.wait()

                if let error = remuxError {
                    // Remux failed — fall back to raw file
                    print("[DownloadManager] Remux failed, using raw file: \(error.localizedDescription)")
                    try? FileManager.default.removeItem(at: destURL)
                    try FileManager.default.moveItem(at: tempLocation, to: destURL)
                }
            }

            // Download artwork
            var artworkPath: String? = nil
            if let artUrlStr = info.artworkUrl, let artUrl = URL(string: artUrlStr) {
                let artDest = artworkDir.appendingPathComponent("\(prefix)_\(info.trackId).jpg")
                if let artData = try? Data(contentsOf: artUrl) {
                    try? artData.write(to: artDest)
                    artworkPath = artDest.path
                }
            }

            // Get file size
            let attrs = try FileManager.default.attributesOfItem(atPath: destURL.path)
            let fileSize = attrs[.size] as? Int64 ?? 0

            // Mark completed
            info.status = .completed
            info.filePath = destURL.path
            info.artworkPath = artworkPath
            info.fileSize = fileSize
            tasks[taskId] = info
            saveTasks()

            print("[DownloadManager] Completed: \(taskId) → \(destURL.path)")

            // Notify JS
            DispatchQueue.main.async {
                self.onComplete?(
                    taskId,
                    destURL.path,
                    artworkPath,
                    fileSize,
                    info.format
                )
            }

        } catch {
            failTask(taskId, error: error.localizedDescription)
        }

        // Process next in queue
        queue.async { [weak self] in
            self?.processQueue()
        }
    }

    private func failTask(_ taskId: String, error: String) {
        guard var info = tasks[taskId] else { return }
        info.status = .error
        info.error = error
        tasks[taskId] = info
        saveTasks()

        print("[DownloadManager] Error for \(taskId): \(error)")

        DispatchQueue.main.async {
            self.onError?(taskId, error)
        }

        // Process next in queue
        queue.async { [weak self] in
            self?.processQueue()
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        guard let taskId = taskIdMap[downloadTask.taskIdentifier] else { return }

        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        DispatchQueue.main.async {
            self.onProgress?(taskId, progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let taskId = taskIdMap[downloadTask.taskIdentifier] else { return }

        // Copy temp file to a location we control (OS deletes temp after delegate returns)
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".tmp")
        do {
            try FileManager.default.copyItem(at: location, to: tempCopy)
        } catch {
            failTask(taskId, error: "Failed to copy temp file: \(error.localizedDescription)")
            return
        }

        queue.async { [weak self] in
            self?.processCompletedDownload(taskId: taskId, tempLocation: tempCopy)
            // Clean up temp copy
            try? FileManager.default.removeItem(at: tempCopy)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }
        guard let taskId = taskIdMap[task.taskIdentifier] else { return }

        // Ignore cancellation
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }

        queue.async { [weak self] in
            self?.failTask(taskId, error: error.localizedDescription)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
