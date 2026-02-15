/**
 * DeezerDecryptBridge - Exposes DeezerDecrypt to Objective-C
 *
 * Provides a class method that DeezerInputSource.m can call
 * to decrypt individual 2048-byte chunks using the existing
 * Blowfish.swift + DeezerDecrypt.swift infrastructure.
 */

import Foundation

@objc public class DeezerDecryptBridge: NSObject {

    /// Decrypt a single 2048-byte Deezer chunk.
    /// Called from DeezerInputSource.m.
    /// Returns decrypted data if chunkIndex % 3 == 0 and chunk is exactly 2048 bytes,
    /// otherwise returns the original chunk unmodified.
    @objc public static func decryptChunk(_ trackId: NSString, _ chunkData: NSData, _ chunkIndex: Int) -> NSData? {
        let CHUNK_SIZE = 2048

        guard chunkData.length == CHUNK_SIZE, chunkIndex % 3 == 0 else {
            return chunkData
        }

        let key = DeezerDecrypt.generateTrackKey(trackId: trackId as String)
        let blowfish = Blowfish(key: key)

        if let decrypted = blowfish.decryptCBC(data: chunkData as Data, iv: DeezerDecrypt.IV) {
            return decrypted as NSData
        }

        return chunkData
    }
}
