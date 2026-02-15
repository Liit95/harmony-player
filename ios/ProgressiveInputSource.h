/**
 * ProgressiveInputSource - SFBInputSource subclass for HTTP progressive download
 *
 * Downloads audio data from an HTTP URL to a temporary file,
 * allowing SFBAudioEngine to read and decode while download is in progress.
 * Supports seeking within the already-downloaded portion.
 */

#ifndef ProgressiveInputSource_h
#define ProgressiveInputSource_h

#import <Foundation/Foundation.h>
@import CSFBAudioEngine;

NS_ASSUME_NONNULL_BEGIN

@interface ProgressiveInputSource : SFBInputSource

- (instancetype)initWithRemoteURL:(NSURL *)url;

/// Cancel the download and clean up
- (void)cancelDownload;

@end

NS_ASSUME_NONNULL_END

#endif /* ProgressiveInputSource_h */
