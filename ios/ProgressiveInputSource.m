/**
 * ProgressiveInputSource - SFBInputSource subclass for HTTP progressive download
 *
 * Downloads audio from HTTP URL to a temporary file while SFBAudioEngine reads it.
 * Read operations block if requesting data beyond what's been downloaded so far.
 * Supports seeking within the downloaded portion.
 */

#import "ProgressiveInputSource.h"
#import <os/lock.h>
#import <objc/message.h>


@interface ProgressiveInputSource () <NSURLSessionDataDelegate>

@property (nonatomic, strong) NSURL *remoteURL;
@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *dataTask;
@property (nonatomic, strong, nullable) NSFileHandle *writeHandle;
@property (nonatomic, strong, nullable) NSFileHandle *readHandle;
@property (nonatomic, strong, nullable) NSString *tempFilePath;

@property (nonatomic, assign) NSInteger contentLength;
@property (nonatomic, assign) NSInteger bytesDownloaded;
@property (nonatomic, assign) NSInteger readOffset;
@property (nonatomic, assign) BOOL downloadComplete;
@property (nonatomic, assign) BOOL downloadFailed;
@property (nonatomic, assign) BOOL isSourceOpen;
@property (nonatomic, assign) BOOL isCancelled;

@end

@implementation ProgressiveInputSource {
    os_unfair_lock _lock;
    dispatch_semaphore_t _dataSemaphore;
}

- (instancetype)initWithRemoteURL:(NSURL *)url {
    // SFBInputSource marks init as unavailable (compile error, not warning).
    // Use objc_msgSendSuper to call NSObject's init at runtime.
    struct objc_super s = { .receiver = self, .super_class = [SFBInputSource class] };
    self = ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&s, @selector(init));
    if (self) {
        _remoteURL = url;
        _lock = OS_UNFAIR_LOCK_INIT;
        _dataSemaphore = dispatch_semaphore_create(0);
        _contentLength = -1;
        _bytesDownloaded = 0;
        _readOffset = 0;
        _downloadComplete = NO;
        _downloadFailed = NO;
        _isSourceOpen = NO;
        _isCancelled = NO;
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

    // Create temp file
    NSString *tempDir = NSTemporaryDirectory();
    _tempFilePath = [tempDir stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    [[NSFileManager defaultManager] createFileAtPath:_tempFilePath contents:nil attributes:nil];

    _writeHandle = [NSFileHandle fileHandleForWritingAtPath:_tempFilePath];
    _readHandle = [NSFileHandle fileHandleForReadingAtPath:_tempFilePath];

    if (!_writeHandle || !_readHandle) {
        if (error) {
            *error = [NSError errorWithDomain:@"ProgressiveInputSource" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create temp file"}];
        }
        return NO;
    }

    // Start download
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    _dataTask = [_session dataTaskWithURL:_remoteURL];
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
        available = _bytesDownloaded - _readOffset;
        complete = _downloadComplete;
        failed = _downloadFailed;
        os_unfair_lock_unlock(&_lock);

        if (failed) {
            if (error) {
                *error = [NSError errorWithDomain:@"ProgressiveInputSource" code:-2
                                         userInfo:@{NSLocalizedDescriptionKey: @"Download failed"}];
            }
            if (bytesRead) *bytesRead = totalRead;
            return totalRead > 0;
        }

        if (available <= 0 && complete) {
            // EOF
            break;
        }

        if (available <= 0) {
            // Wait for more data
            dispatch_semaphore_wait(_dataSemaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
            continue;
        }

        NSInteger toRead = MIN(length - totalRead, available);

        @try {
            [_readHandle seekToFileOffset:(unsigned long long)_readOffset];
            NSData *data = [_readHandle readDataOfLength:(NSUInteger)toRead];

            if (data.length == 0) {
                break;
            }

            memcpy((uint8_t *)buffer + totalRead, data.bytes, data.length);
            totalRead += data.length;
            _readOffset += data.length;
        } @catch (NSException *e) {
            if (error) {
                *error = [NSError errorWithDomain:@"ProgressiveInputSource" code:-3
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
    os_unfair_lock_lock(&_lock);
    NSInteger len = _contentLength;
    os_unfair_lock_unlock(&_lock);

    if (len < 0) {
        // Length not yet known — wait briefly for HTTP response
        for (int i = 0; i < 50; i++) {
            dispatch_semaphore_wait(_dataSemaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
            os_unfair_lock_lock(&_lock);
            len = _contentLength;
            os_unfair_lock_unlock(&_lock);
            if (len >= 0) break;
        }
    }

    if (length) *length = (len >= 0) ? len : 0;
    return len >= 0;
}

- (BOOL)supportsSeeking {
    return YES;
}

- (BOOL)seekToOffset:(NSInteger)offset error:(NSError **)error {
    // Wait until data at offset is available
    while (!_isCancelled && !_downloadFailed) {
        os_unfair_lock_lock(&_lock);
        NSInteger downloaded = _bytesDownloaded;
        BOOL complete = _downloadComplete;
        os_unfair_lock_unlock(&_lock);

        if (offset <= downloaded || complete) {
            break;
        }

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
    // Signal any blocked readers
    dispatch_semaphore_signal(_dataSemaphore);
}

// MARK: - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    NSInteger length = (NSInteger)httpResponse.expectedContentLength;

    os_unfair_lock_lock(&_lock);
    _contentLength = (length > 0) ? length : -1;
    os_unfair_lock_unlock(&_lock);

    dispatch_semaphore_signal(_dataSemaphore);
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {

    @try {
        [_writeHandle seekToEndOfFile];
        [_writeHandle writeData:data];
    } @catch (NSException *e) {
        NSLog(@"[ProgressiveInputSource] Write error: %@", e.reason);
        return;
    }

    os_unfair_lock_lock(&_lock);
    _bytesDownloaded += data.length;
    os_unfair_lock_unlock(&_lock);

    dispatch_semaphore_signal(_dataSemaphore);
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(nullable NSError *)error {
    os_unfair_lock_lock(&_lock);
    if (error && !_isCancelled) {
        NSLog(@"[ProgressiveInputSource] Download error: %@", error.localizedDescription);
        _downloadFailed = YES;
    } else {
        _downloadComplete = YES;
    }
    os_unfair_lock_unlock(&_lock);

    dispatch_semaphore_signal(_dataSemaphore);
}

@end
