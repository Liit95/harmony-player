/**
 * DeezerDecrypt - Track decryption for Deezer audio
 *
 * Handles:
 * - Track key generation from track ID
 * - Chunk-based decryption (every 3rd 2048-byte chunk)
 */

import Foundation
import CommonCrypto

class DeezerDecrypt {

    // MARK: - Constants

    static let CHUNK_SIZE = 2048
    static let SECRET = "g4el58wc0zvf9na1"
    static let IV = Data([0, 1, 2, 3, 4, 5, 6, 7])

    // MARK: - Key Generation

    /// Generate the Blowfish key for a track
    /// Key = MD5_HEX(trackId)[0:16] XOR MD5_HEX(trackId)[16:32] XOR SECRET
    /// Note: Uses hex string representation of MD5, not raw bytes (matches backend/refreezer)
    static func generateTrackKey(trackId: String) -> Data {
        let trackIdData = trackId.data(using: .utf8)!
        let md5Hex = md5Hex(trackIdData) // 32-char hex string

        // XOR first 16 hex chars with second 16 hex chars with secret
        var key = Data(count: 16)
        let secretBytes = Array(SECRET.utf8)
        let hexBytes = Array(md5Hex.utf8)

        for i in 0..<16 {
            key[i] = hexBytes[i] ^ hexBytes[i + 16] ^ secretBytes[i]
        }

        return key
    }

    /// Calculate MD5 hash and return as hex string (like Node.js digest('hex'))
    private static func md5Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_MD5(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Decryption

    /// Decrypt Deezer audio data
    /// Pattern: Every 3rd 2048-byte chunk (index % 3 == 0) is encrypted
    static func decryptTrack(trackId: String, encryptedData: Data) -> Data {
        let key = generateTrackKey(trackId: trackId)
        let blowfish = Blowfish(key: key)

        var result = Data()
        var chunkIndex = 0
        var offset = 0

        while offset < encryptedData.count {
            let chunkEnd = min(offset + CHUNK_SIZE, encryptedData.count)
            var chunk = encryptedData.subdata(in: offset..<chunkEnd)

            // Only decrypt every 3rd chunk (starting from index 0)
            if chunkIndex % 3 == 0 && chunk.count == CHUNK_SIZE {
                if let decrypted = blowfish.decryptCBC(data: chunk, iv: IV) {
                    chunk = decrypted
                }
            }

            result.append(chunk)
            offset = chunkEnd
            chunkIndex += 1
        }

        return result
    }

    /// Decrypt a specific range of data (for streaming with seeking)
    /// Matches refreezer/backend pattern:
    /// - alignedStart: byte position aligned to 2048 (deezerStart)
    /// - dropBytes: bytes to skip from first chunk after decryption
    /// - chunkIndex starts at alignedStart / CHUNK_SIZE
    static func decryptRange(
        trackId: String,
        encryptedData: Data,
        alignedStart: Int,
        dropBytes: Int
    ) -> Data {
        let key = generateTrackKey(trackId: trackId)
        let blowfish = Blowfish(key: key)

        // Starting chunk index in the original file (refreezer pattern)
        var chunkIndex = alignedStart / CHUNK_SIZE

        var result = Data()
        var offset = 0
        var bytesToDrop = dropBytes

        while offset < encryptedData.count {
            let chunkEnd = min(offset + CHUNK_SIZE, encryptedData.count)
            var chunk = encryptedData.subdata(in: offset..<chunkEnd)

            // Decrypt every 3rd chunk of exactly 2048 bytes (refreezer pattern)
            if chunk.count == CHUNK_SIZE && chunkIndex % 3 == 0 {
                if let decrypted = blowfish.decryptCBC(data: chunk, iv: IV) {
                    chunk = decrypted
                }
            }

            // Drop bytes from the first chunk if needed (for Range request alignment)
            if bytesToDrop > 0 {
                let skipAmount = min(bytesToDrop, chunk.count)
                chunk = chunk.subdata(in: skipAmount..<chunk.count)
                bytesToDrop = 0
            }

            result.append(chunk)
            offset = chunkEnd
            chunkIndex += 1
        }

        return result
    }

    /// Calculate the aligned start position for seeking (refreezer pattern)
    /// Returns (alignedStart, dropBytes) where:
    /// - alignedStart: Position to request from server (chunk-aligned to 2048)
    /// - dropBytes: Bytes to skip after decryption to reach actual requested position
    static func getAlignedPosition(requestedStart: Int) -> (alignedStart: Int, dropBytes: Int) {
        let alignedStart = requestedStart - (requestedStart % CHUNK_SIZE)
        let dropBytes = requestedStart % CHUNK_SIZE
        return (alignedStart, dropBytes)
    }
}
