/**
 * HarmonyDecoderFactory - Creates SFBAudioEngine decoders from custom input sources
 *
 * Uses @import for SFBAudioEngine (modules enabled in .m files) so the .h header
 * doesn't need any SFBAudioEngine imports — keeping the bridging header clean.
 */

#import "HarmonyDecoderFactory.h"
#import "DeezerInputSource.h"
#import "ProgressiveInputSource.h"

#import "SFBAudioDecoder.h"

@implementation HarmonyDecoderFactory

+ (nullable id)decoderForDeezerTrackId:(NSString *)trackId
                          encryptedUrl:(NSString *)encryptedUrl
                         contentLength:(int64_t)contentLength
                           contentType:(NSString *)contentType
                                 error:(NSError **)error {

    DeezerInputSource *inputSource = [[DeezerInputSource alloc] initWithTrackId:trackId
                                                                   encryptedUrl:encryptedUrl
                                                                  contentLength:contentLength];

    // Determine MIME type hint for the decoder
    NSString *mimeType = [contentType containsString:@"flac"] ? @"audio/flac" : @"audio/mpeg";

    SFBAudioDecoder *decoder = [[SFBAudioDecoder alloc] initWithInputSource:inputSource
                                                               mimeTypeHint:mimeType
                                                                      error:error];
    return decoder;
}

+ (nullable id)decoderForProgressiveURL:(NSURL *)url
                                  error:(NSError **)error {
    @try {
        ProgressiveInputSource *inputSource = [[ProgressiveInputSource alloc] initWithRemoteURL:url];

        SFBAudioDecoder *decoder = [[SFBAudioDecoder alloc] initWithInputSource:inputSource
                                                                          error:error];
        if (!decoder) {
            NSLog(@"[HarmonyDecoderFactory] Progressive decoder returned nil for: %@", url);
            [inputSource cancelDownload];
        }
        return decoder;
    } @catch (NSException *exception) {
        NSLog(@"[HarmonyDecoderFactory] Exception creating progressive decoder: %@", exception.reason);
        if (error) {
            *error = [NSError errorWithDomain:@"HarmonyDecoderFactory" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Decoder creation failed"}];
        }
        return nil;
    }
}

@end
