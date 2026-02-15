/**
 * DeezerResourceLoaderSwizzle - AVURLAsset swizzle for deezer-enc:// scheme
 *
 * Intercepts AVURLAsset creation to detect deezer-enc:// URLs.
 * When found, extracts the trackId from the host, looks up track info
 * from the registry, creates a DeezerResourceLoader, sets it as the
 * asset's resourceLoader delegate, and retains it via associated object
 * (since AVAssetResourceLoader only keeps a weak reference to its delegate).
 */

#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// Forward declaration — implemented in DeezerAssetBridge.swift
@interface DeezerAssetSetup : NSObject
+ (void)setupDeezerResourceLoader:(AVURLAsset *)asset trackId:(NSString *)trackId;
@end

static const void *kDeezerResourceLoaderKey = &kDeezerResourceLoaderKey;

@interface AVURLAsset (HarmonyDeezerLoader)
@end

@implementation AVURLAsset (HarmonyDeezerLoader)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SEL originalSelector = @selector(initWithURL:options:);
        SEL swizzledSelector = @selector(initHarmony_WithURL:options:);

        Method originalMethod = class_getInstanceMethod(self, originalSelector);
        Method swizzledMethod = class_getInstanceMethod(self, swizzledSelector);

        if (originalMethod && swizzledMethod) {
            method_exchangeImplementations(originalMethod, swizzledMethod);
        }
    });
}

// Method name must start with "init" so the compiler allows `self = ...` assignment
- (instancetype)initHarmony_WithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
    // Call original implementation (methods are swapped)
    self = [self initHarmony_WithURL:URL options:options];

    if (self && URL && [URL.scheme isEqualToString:@"deezer-enc"]) {
        NSString *trackId = URL.host;
        if (trackId && trackId.length > 0) {
            [DeezerAssetSetup setupDeezerResourceLoader:self trackId:trackId];
        }
    }

    return self;
}

@end
