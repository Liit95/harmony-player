/**
 * HarmonyDecoderFactory - Creates SFBAudioEngine decoders from custom input sources
 *
 * This factory isolates SFBAudioEngine imports from the bridging header.
 * It creates AudioDecoders backed by DeezerInputSource or ProgressiveInputSource,
 * returning them as untyped `id` so the header doesn't need SFBAudioEngine imports.
 *
 * From Swift, cast the returned object to `AudioDecoder` or `any PCMDecoding`.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HarmonyDecoderFactory : NSObject

/// Create a decoder for a Deezer encrypted stream.
/// Downloads, decrypts (Blowfish-CBC), and decodes FLAC/MP3 via SFBAudioEngine.
/// Returns an SFBAudioDecoder (cast to AudioDecoder in Swift).
+ (nullable id)decoderForDeezerTrackId:(NSString *)trackId
                          encryptedUrl:(NSString *)encryptedUrl
                         contentLength:(int64_t)contentLength
                           contentType:(NSString *)contentType
                                 error:(NSError **)error;

/// Create a decoder for an HTTP progressive download stream (e.g. YouTube).
/// Downloads to temp file while SFBAudioEngine decodes progressively.
/// Returns an SFBAudioDecoder (cast to AudioDecoder in Swift).
+ (nullable id)decoderForProgressiveURL:(NSURL *)url
                                  error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
