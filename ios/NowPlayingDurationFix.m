/**
 * NowPlayingDurationFix - Corrects doubled duration in Now Playing / Lock Screen
 *
 * YouTube/Invidious audio streams have fragmented MP4 containers that report
 * ~2x the real duration. This swizzles MPNowPlayingInfoCenter's nowPlayingInfo
 * setter to automatically halve the duration when a static flag is enabled.
 *
 * The flag is controlled from JS via AudioRemuxerBridge.setHalveDuration()
 * and is toggled on/off when tracks change based on the playback source.
 */

#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>

// Static flag controlled from JS via AudioRemuxerBridge
static BOOL _harmony_halveDuration = NO;

void HarmonySetHalveDuration(BOOL value) {
    _harmony_halveDuration = value;
}

BOOL HarmonyGetHalveDuration(void) {
    return _harmony_halveDuration;
}

@interface MPNowPlayingInfoCenter (HarmonyDurationFix)
@end

@implementation MPNowPlayingInfoCenter (HarmonyDurationFix)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SEL originalSelector = @selector(setNowPlayingInfo:);
        SEL swizzledSelector = @selector(harmony_setNowPlayingInfo:);

        Method originalMethod = class_getInstanceMethod(self, originalSelector);
        Method swizzledMethod = class_getInstanceMethod(self, swizzledSelector);

        if (originalMethod && swizzledMethod) {
            method_exchangeImplementations(originalMethod, swizzledMethod);
        }
    });
}

- (void)harmony_setNowPlayingInfo:(NSDictionary<NSString *, id> *)nowPlayingInfo {
    NSMutableDictionary *info = nowPlayingInfo ? [nowPlayingInfo mutableCopy] : nil;

    if (info && _harmony_halveDuration) {
        NSNumber *duration = info[MPMediaItemPropertyPlaybackDuration];
        if (duration) {
            info[MPMediaItemPropertyPlaybackDuration] = @(duration.doubleValue / 2.0);
        }
    }

    // Call original implementation (methods are swapped)
    [self harmony_setNowPlayingInfo:info];
}

@end
