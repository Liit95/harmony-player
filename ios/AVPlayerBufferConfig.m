/**
 * AVPlayerBufferConfig - Sets preferredForwardBufferDuration on AVPlayerItems
 *
 * SwiftAudioEx couples bufferDuration (preferredForwardBufferDuration) with
 * automaticallyWaitsToMinimizeStalling. Setting bufferDuration > 0 forces
 * automaticallyWaitsToMinimizeStalling = false, which causes AVPlayer to enter
 * .paused state (instead of .waitingToPlayAtSpecifiedRate) when it can't play
 * immediately. SwiftAudioEx then interprets this as an external pause and
 * permanently stops playback.
 *
 * This workaround swizzles AVPlayer.replaceCurrentItem(with:) to set
 * preferredForwardBufferDuration directly on each AVPlayerItem, bypassing
 * SwiftAudioEx's coupled setter and keeping automaticallyWaitsToMinimizeStalling
 * at its default (true).
 */

#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static const NSTimeInterval kPreferredForwardBufferDuration = 30.0;

@interface AVPlayer (HarmonyBufferConfig)
@end

@implementation AVPlayer (HarmonyBufferConfig)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SEL originalSelector = @selector(replaceCurrentItemWithPlayerItem:);
        SEL swizzledSelector = @selector(harmony_replaceCurrentItemWithPlayerItem:);

        Method originalMethod = class_getInstanceMethod(self, originalSelector);
        Method swizzledMethod = class_getInstanceMethod(self, swizzledSelector);

        if (originalMethod && swizzledMethod) {
            method_exchangeImplementations(originalMethod, swizzledMethod);
        }
    });
}

- (void)harmony_replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    if (item) {
        item.preferredForwardBufferDuration = kPreferredForwardBufferDuration;
    }
    // Calls the original implementation (methods are swapped)
    [self harmony_replaceCurrentItemWithPlayerItem:item];
}

@end
