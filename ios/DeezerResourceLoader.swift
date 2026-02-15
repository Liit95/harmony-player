/**
 * DeezerResourceLoader - AVAssetResourceLoaderDelegate for Deezer streams
 *
 * When AVPlayer encounters a deezer-enc:// URL, this delegate:
 * 1. Responds to content info requests with UTI, content length, byte-range support
 * 2. Handles data requests by fetching encrypted data from CDN, decrypting
 *    Blowfish-CBC chunks (every 3rd 2048-byte chunk), and feeding clean bytes
 *    to AVPlayer incrementally
 *
 * AVPlayer then parses FLAC/MP3 natively — duration from STREAMINFO,
 * seek via SEEKTABLE, gapless via AVQueuePlayer.
 */

import Foundation
import AVFoundation
import MobileCoreServices

class DeezerResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    private let trackInfo: DeezerTrackInfo
    private let blowfish: Blowfish
    private let delegateQueue: DispatchQueue

    /// Active loading requests and their associated URL tasks
    private var pendingRequests: [AVAssetResourceLoadingRequest: URLSessionDataTask] = [:]
    /// Per-request decryption state
    private var requestState: [AVAssetResourceLoadingRequest: RequestState] = [:]
    private var session: URLSession?

    private struct RequestState {
        var buffer = Data()
        var chunkIndex: Int = 0
        var dropBytes: Int = 0
        var bytesResponded: Int64 = 0
        let requestedOffset: Int64
        let requestedLength: Int
    }

    init(trackInfo: DeezerTrackInfo) {
        self.trackInfo = trackInfo
        let key = DeezerDecrypt.generateTrackKey(trackId: trackInfo.trackId)
        self.blowfish = Blowfish(key: key)
        self.delegateQueue = DispatchQueue(label: "com.harmony.deezer.resourceloader.\(trackInfo.trackId)")

        super.init()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit {
        session?.invalidateAndCancel()
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        // Content information request
        if let contentRequest = loadingRequest.contentInformationRequest {
            fillContentInformation(contentRequest)
            // If there's no data request, finish immediately
            if loadingRequest.dataRequest == nil {
                loadingRequest.finishLoading()
                return true
            }
        }

        // Data request
        if let dataRequest = loadingRequest.dataRequest {
            startDataRequest(loadingRequest: loadingRequest, dataRequest: dataRequest)
            return true
        }

        return false
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        delegateQueue.async { [weak self] in
            guard let self = self else { return }
            if let task = self.pendingRequests.removeValue(forKey: loadingRequest) {
                task.cancel()
            }
            self.requestState.removeValue(forKey: loadingRequest)
        }
    }

    // MARK: - Content Info

    private func fillContentInformation(_ contentRequest: AVAssetResourceLoadingContentInformationRequest) {
        let ct = trackInfo.contentType.lowercased()
        if ct.contains("flac") {
            contentRequest.contentType = "org.xiph.flac"
        } else if ct.contains("mp3") || ct.contains("mpeg") {
            contentRequest.contentType = "public.mp3"
        } else {
            contentRequest.contentType = "public.audio"
        }

        contentRequest.contentLength = trackInfo.contentLength
        contentRequest.isByteRangeAccessSupported = true
    }

    // MARK: - Data Request

    private func startDataRequest(loadingRequest: AVAssetResourceLoadingRequest, dataRequest: AVAssetResourceLoadingDataRequest) {
        let requestedOffset = dataRequest.requestedOffset
        let requestedLength = dataRequest.requestedLength

        // Align to 2048 boundary for decryption
        let chunkSize = Int64(DeezerDecrypt.CHUNK_SIZE)
        let alignedStart = (requestedOffset / chunkSize) * chunkSize
        let dropBytes = Int(requestedOffset - alignedStart)

        // Calculate how many bytes we need from CDN (aligned range covering the request)
        let alignedEnd = min(
            ((requestedOffset + Int64(requestedLength) + chunkSize - 1) / chunkSize) * chunkSize,
            trackInfo.contentLength
        )
        let alignedLength = alignedEnd - alignedStart

        let state = RequestState(
            chunkIndex: Int(alignedStart / chunkSize),
            dropBytes: dropBytes,
            requestedOffset: requestedOffset,
            requestedLength: requestedLength
        )

        // Build HTTP range request to CDN
        var request = URLRequest(url: trackInfo.encryptedUrl)
        let rangeEnd = alignedStart + alignedLength - 1
        request.setValue("bytes=\(alignedStart)-\(rangeEnd)", forHTTPHeaderField: "Range")

        delegateQueue.async { [weak self] in
            guard let self = self else { return }
            self.requestState[loadingRequest] = state

            let task = self.session?.dataTask(with: request)
            self.pendingRequests[loadingRequest] = task
            task?.resume()
        }
    }

    // MARK: - Data Processing

    private func processData(_ data: Data, for loadingRequest: AVAssetResourceLoadingRequest) {
        guard var state = requestState[loadingRequest],
              let dataRequest = loadingRequest.dataRequest else { return }

        state.buffer.append(data)

        let chunkSize = DeezerDecrypt.CHUNK_SIZE

        // Process complete 2048-byte chunks
        while state.buffer.count >= chunkSize {
            var chunk = state.buffer.subdata(in: 0..<chunkSize)
            state.buffer = state.buffer.subdata(in: chunkSize..<state.buffer.count)

            // Decrypt every 3rd chunk (index % 3 == 0)
            if state.chunkIndex % 3 == 0 {
                if let decrypted = blowfish.decryptCBC(data: chunk, iv: DeezerDecrypt.IV) {
                    chunk = decrypted
                }
            }
            state.chunkIndex += 1

            // Drop alignment bytes from first chunk
            if state.dropBytes > 0 {
                let skip = min(state.dropBytes, chunk.count)
                chunk = chunk.subdata(in: skip..<chunk.count)
                state.dropBytes = 0
            }

            // Limit response to requestedLength
            let remaining = Int64(state.requestedLength) - state.bytesResponded
            if remaining <= 0 { break }

            if Int64(chunk.count) > remaining {
                chunk = chunk.subdata(in: 0..<Int(remaining))
            }

            dataRequest.respond(with: chunk)
            state.bytesResponded += Int64(chunk.count)
        }

        requestState[loadingRequest] = state
    }

    private func finishRequest(_ loadingRequest: AVAssetResourceLoadingRequest, error: Error?) {
        // Flush remaining buffer (last partial chunk — not encrypted)
        if var state = requestState[loadingRequest],
           let dataRequest = loadingRequest.dataRequest,
           state.buffer.count > 0 {
            var remaining = state.buffer
            state.buffer = Data()

            if state.dropBytes > 0 {
                let skip = min(state.dropBytes, remaining.count)
                remaining = remaining.subdata(in: skip..<remaining.count)
                state.dropBytes = 0
            }

            let bytesLeft = Int64(state.requestedLength) - state.bytesResponded
            if bytesLeft > 0 && remaining.count > 0 {
                if Int64(remaining.count) > bytesLeft {
                    remaining = remaining.subdata(in: 0..<Int(bytesLeft))
                }
                dataRequest.respond(with: remaining)
                state.bytesResponded += Int64(remaining.count)
            }
            requestState[loadingRequest] = state
        }

        pendingRequests.removeValue(forKey: loadingRequest)
        requestState.removeValue(forKey: loadingRequest)

        if let error = error, (error as NSError).code != NSURLErrorCancelled {
            loadingRequest.finishLoading(with: error)
        } else if !loadingRequest.isCancelled && !loadingRequest.isFinished {
            loadingRequest.finishLoading()
        }
    }
}

// MARK: - URLSessionDataDelegate

extension DeezerResourceLoader: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask task: URLSessionDataTask, didReceive data: Data) {
        delegateQueue.async { [weak self] in
            guard let self = self else { return }

            // Find the loading request associated with this data task
            guard let loadingRequest = self.pendingRequests.first(where: { $0.value == task })?.key else { return }

            self.processData(data, for: loadingRequest)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        delegateQueue.async { [weak self] in
            guard let self = self else { return }

            guard let loadingRequest = self.pendingRequests.first(where: { $0.value == task as? URLSessionDataTask })?.key else { return }

            self.finishRequest(loadingRequest, error: error)
        }
    }
}
