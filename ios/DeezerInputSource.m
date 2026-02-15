/**
 * DeezerInputSource - SFBInputSource subclass for Deezer encrypted streams
 *
 * Downloads encrypted audio from Deezer CDN, aligns to 2048-byte chunks,
 * decrypts every 3rd chunk using Blowfish-CBC via DeezerDecrypt.swift,
 * and serves decrypted data to SFBAudioEngine decoders.
 *
 * The decryption is done in a background thread during download.
 * SFBAudioEngine reads clean FLAC/MP3 data and parses natively.
 */

#import "DeezerInputSource.h"
#import <os/lock.h>
#import <objc/message.h>


// Import the auto-generated Swift header to access DeezerDecryptBridge
// In a CocoaPods pod, the header is named <ModuleName>-Swift.h
#if __has_include("HarmonyPlayer-Swift.h")
#import "HarmonyPlayer-Swift.h"
#else
// Fallback: forward-declare the bridge class
@interface DeezerDecryptBridge : NSObject
+ (NSData * _Nullable)decryptChunk:(NSString * _Nonnull)trackId :(NSData * _Nonnull)chunkData :(NSInteger)chunkIndex;
@end
#endif

@interface DeezerInputSource () <NSURLSessionDataDelegate>

@property (nonatomic, copy) NSString *trackId;
@property (nonatomic, copy) NSString *encryptedUrl;
@property (nonatomic, assign) int64_t totalContentLength;

@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *dataTask;
@property (nonatomic, strong, nullable) NSFileHandle *writeHandle;
@property (nonatomic, strong, nullable) NSFileHandle *readHandle;
@property (nonatomic, strong, nullable) NSString *tempFilePath;

@property (nonatomic, assign) NSInteger bytesDownloaded;
@property (nonatomic, assign) NSInteger bytesWritten;
@property (nonatomic, assign) NSInteger readOffset;
@property (nonatomic, assign) BOOL downloadComplete;
@property (nonatomic, assign) BOOL downloadFailed;
@property (nonatomic, assign) BOOL isSourceOpen;
@property (nonatomic, assign) BOOL isCancelled;

// Decryption buffer state
@property (nonatomic, strong) NSMutableData *chunkBuffer;
@property (nonatomic, assign) NSInteger chunkIndex;

@end

@implementation DeezerInputSource {
    os_unfair_lock _lock;
    dispatch_semaphore_t _dataSemaphore;
}

- (instancetype)initWithTrackId:(NSString *)trackId
                   encryptedUrl:(NSString *)encryptedUrl
                  contentLength:(int64_t)contentLength {
    // SFBInputSource marks init as unavailable (compile error, not warning).
    // Use objc_msgSendSuper to call NSObject's init at runtime.
    struct objc_super s = { .receiver = self, .super_class = [SFBInputSource class] };
    self = ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&s, @selector(init));
    if (self) {
        _trackId = [trackId copy];
        _encryptedUrl = [encryptedUrl copy];
        _totalContentLength = contentLength;
        _lock = OS_UNFAIR_LOCK_INIT;
        _dataSemaphore = dispatch_semaphore_create(0);
        _bytesDownloaded = 0;
        _bytesWritten = 0;
        _readOffset = 0;
        _downloadComplete = NO;
        _downloadFailed = NO;
        _isSourceOpen = NO;
        _isCancelled = NO;
        _chunkBuffer = [NSMutableData new];
        _chunkIndex = 0;
    }
    return self;
}

- (void)dealloc {
    [self cancelDownload];
    if (_tempFilePath) {
        [[NSFileManager defaultManager] removeItemAtPath:_tempFilePath error:nil];
    }
}

// MARK: - SFBInputSource overrides

- (BOOL)openReturningError:(NSError **)error {
    if (_isSourceOpen) return YES;

    // Create temp file for decrypted output
    NSString *tempDir = NSTemporaryDirectory();
    _tempFilePath = [tempDir stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    [[NSFileManager defaultManager] createFileAtPath:_tempFilePath contents:nil attributes:nil];

    _writeHandle = [NSFileHandle fileHandleForWritingAtPath:_tempFilePath];
    _readHandle = [NSFileHandle fileHandleForReadingAtPath:_tempFilePath];

    if (!_writeHandle || !_readHandle) {
        if (error) {
            *error = [NSError errorWithDomain:@"DeezerInputSource" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create temp file"}];
        }
        return NO;
    }

    // Start download
    NSURL *url = [NSURL URLWithString:_encryptedUrl];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:@"DeezerInputSource" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid encrypted URL"}];
        }
        return NO;
    }

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    _dataTask = [_session dataTaskWithURL:url];
    [_dataTask resume];

    _isSourceOpen = YES;
    return YES;
}

- (BOOL)closeReturningError:(NSError **)error {
    [self cancelDownload];

    [_readHandle closeFile];
    _readHandle = nil;
    [_writeHandle closeFile];
    _writeHandle = nil;

    if (_tempFilePath) {
        [[NSFileManager defaultManager] removeItemAtPath:_tempFilePath error:nil];
        _tempFilePath = nil;
    }

    _isSourceOpen = NO;
    return YES;
}

- (BOOL)isOpen {
    return _isSourceOpen;
}

- (BOOL)readBytes:(void *)buffer length:(NSInteger)length bytesRead:(NSInteger *)bytesRead error:(NSError **)error {
    if (!_isSourceOpen || _isCancelled) {
        if (bytesRead) *bytesRead = 0;
        return YES;
    }

    NSInteger totalRead = 0;

    while (totalRead < length) {
        NSInteger available;
        BOOL complete;
        BOOL failed;

        os_unfair_lock_lock(&_lock);
        available = _bytesWritten - _readOffset;
        complete = _downloadComplete;
        failed = _downloadFailed;
        os_unfair_lock_unlock(&_lock);

        if (failed) {
            if (error) {
                *error = [NSError errorWithDomain:@"DeezerInputSource" code:-2
                                         userInfo:@{NSLocalizedDescriptionKey: @"Download failed"}];
            }
            if (bytesRead) *bytesRead = totalRead;
            return totalRead > 0;
        }

        if (available <= 0 && complete) {
            break; // EOF
        }

        if (available <= 0) {
            dispatch_semaphore_wait(_dataSemaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
            continue;
        }

        NSInteger toRead = MIN(length - totalRead, available);

        @try {
            [_readHandle seekToFileOffset:(unsigned long long)_readOffset];
            NSData *data = [_readHandle readDataOfLength:(NSUInteger)toRead];

            if (data.length == 0) break;

            memcpy((uint8_t *)buffer + totalRead, data.bytes, data.length);
            totalRead += data.length;
            _readOffset += data.length;
        } @catch (NSException *e) {
            if (error) {
                *error = [NSError errorWithDomain:@"DeezerInputSource" code:-3
                                         userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"Read error"}];
            }
            break;
        }
    }

    if (bytesRead) *bytesRead = totalRead;
    return YES;
}

- (BOOL)getOffset:(NSInteger *)offset error:(NSError **)error {
    if (offset) *offset = _readOffset;
    return YES;
}

- (BOOL)getLength:(NSInteger *)length error:(NSError **)error {
    // Return the original content length — the decrypted output is the same size
    if (length) *length = (NSInteger)_totalContentLength;
    return YES;
}

- (BOOL)supportsSeeking {
    return YES;
}

- (BOOL)seekToOffset:(NSInteger)offset error:(NSError **)error {
    // Wait until decrypted data at offset is available
    while (!_isCancelled && !_downloadFailed) {
        os_unfair_lock_lock(&_lock);
        NSInteger written = _bytesWritten;
        BOOL complete = _downloadComplete;
        os_unfair_lock_unlock(&_lock);

        if (offset <= written || complete) break;

        dispatch_semaphore_wait(_dataSemaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
    }

    _readOffset = offset;
    return YES;
}

- (void)cancelDownload {
    _isCancelled = YES;
    [_dataTask cancel];
    _dataTask = nil;
    [_session invalidateAndCancel];
    _session = nil;
    dispatch_semaphore_signal(_dataSemaphore);
}

// MARK: - Chunk decryption

static const NSInteger CHUNK_SIZE = 2048;

- (void)processEncryptedData:(NSData *)data {
    [_chunkBuffer appendData:data];

    // Process complete 2048-byte chunks
    while (_chunkBuffer.length >= CHUNK_SIZE) {
        NSData *chunk = [_chunkBuffer subdataWithRange:NSMakeRange(0, CHUNK_SIZE)];

        // Remove processed data from buffer
        [_chunkBuffer replaceBytesInRange:NSMakeRange(0, CHUNK_SIZE) withBytes:NULL length:0];

        // Decrypt every 3rd chunk (index % 3 == 0)
        NSData *outputChunk;
        if (_chunkIndex % 3 == 0) {
            NSData *decrypted = [DeezerDecryptBridge decryptChunk:_trackId :chunk :_chunkIndex];
            outputChunk = decrypted ?: chunk;
        } else {
            outputChunk = chunk;
        }

        // Write decrypted chunk to temp file
        @try {
            [_writeHandle seekToEndOfFile];
            [_writeHandle writeData:outputChunk];

            os_unfair_lock_lock(&_lock);
            _bytesWritten += outputChunk.length;
            os_unfair_lock_unlock(&_lock);

            dispatch_semaphore_signal(_dataSemaphore);
        } @catch (NSException *e) {
            NSLog(@"[DeezerInputSource] Write error: %@", e.reason);
        }

        _chunkIndex++;
    }
}

- (void)flushRemainingBuffer {
    // Flush any remaining data less than CHUNK_SIZE (last partial chunk, never encrypted)
    if (_chunkBuffer.length > 0) {
        NSData *remaining = [_chunkBuffer copy];
        _chunkBuffer.length = 0;

        @try {
            [_writeHandle seekToEndOfFile];
            [_writeHandle writeData:remaining];

            os_unfair_lock_lock(&_lock);
            _bytesWritten += remaining.length;
            os_unfair_lock_unlock(&_lock);

            dispatch_semaphore_signal(_dataSemaphore);
        } @catch (NSException *e) {
            NSLog(@"[DeezerInputSource] Flush error: %@", e.reason);
        }
    }
}

// MARK: - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {

    os_unfair_lock_lock(&_lock);
    _bytesDownloaded = 0;
    os_unfair_lock_unlock(&_lock);

    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {

    os_unfair_lock_lock(&_lock);
    _bytesDownloaded += data.length;
    os_unfair_lock_unlock(&_lock);

    [self processEncryptedData:data];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(nullable NSError *)error {

    [self flushRemainingBuffer];

    os_unfair_lock_lock(&_lock);
    if (error && !_isCancelled) {
        NSLog(@"[DeezerInputSource] Download error: %@", error.localizedDescription);
        _downloadFailed = YES;
    } else {
        _downloadComplete = YES;
    }
    os_unfair_lock_unlock(&_lock);

    dispatch_semaphore_signal(_dataSemaphore);
}

@end
