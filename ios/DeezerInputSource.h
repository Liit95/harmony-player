/**
 * DeezerInputSource - SFBInputSource subclass for Deezer encrypted streams
 *
 * Downloads encrypted audio from Deezer CDN, decrypts every 3rd 2048-byte chunk
 * using Blowfish-CBC, and serves decrypted data to SFBAudioEngine.
 * The decoder sees clean FLAC/MP3 data and parses natively.
 */

#ifndef DeezerInputSource_h
#define DeezerInputSource_h

#import <Foundation/Foundation.h>
#import "SFBInputSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface DeezerInputSource : SFBInputSource

- (instancetype)initWithTrackId:(NSString *)trackId
                   encryptedUrl:(NSString *)encryptedUrl
                  contentLength:(int64_t)contentLength;

/// Cancel the download and clean up
- (void)cancelDownload;

@end

NS_ASSUME_NONNULL_END

#endif /* DeezerInputSource_h */
