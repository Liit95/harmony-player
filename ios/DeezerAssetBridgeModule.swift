/**
 * DeezerAssetBridgeModule - Expo Module for Deezer asset registration
 *
 * Bridge methods:
 *   registerTrack(trackId, encryptedUrl, contentLength, contentType) -> deezer-enc://{trackId}
 *   unregisterTrack(trackId)
 *
 * Also provides DeezerAssetSetup class (called from ObjC swizzle) to
 * create and attach DeezerResourceLoader to AVURLAsset instances.
 */

import ExpoModulesCore
import AVFoundation
import ObjectiveC

// MARK: - Asset Setup (called from ObjC swizzle)

/// Helper class callable from Objective-C to set up the resource loader
/// on an AVURLAsset with a deezer-enc:// URL.
@objc(DeezerAssetSetup)
class DeezerAssetSetup: NSObject {

    @objc static func setupDeezerResourceLoader(_ asset: AVURLAsset, trackId: String) {
        guard let info = DeezerResourceLoaderRegistry.shared.lookup(trackId: trackId) else {
            print("[DeezerAssetSetup] No registered info for track: \(trackId)")
            return
        }

        let loader = DeezerResourceLoader(trackInfo: info)

        // Set as resource loader delegate on a serial queue
        let queue = DispatchQueue(label: "com.harmony.deezer.asset.\(trackId)")
        asset.resourceLoader.setDelegate(loader, queue: queue)

        // Retain the loader — AVAssetResourceLoader only holds a weak ref to its delegate.
        // Use associated object so the loader lives as long as the asset.
        objc_setAssociatedObject(asset, &AssociatedKeys.loaderKey, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        print("[DeezerAssetSetup] Attached resource loader for track: \(trackId)")
    }

    private struct AssociatedKeys {
        static var loaderKey = "com.harmony.deezer.resourceLoader"
    }
}

// MARK: - Expo Module

public class DeezerAssetBridgeModule: Module {

    public func definition() -> ModuleDefinition {
        Name("DeezerAssetBridge")

        AsyncFunction("registerTrack") { (trackId: String, encryptedUrl: String, contentLength: Int, contentType: String) -> String in
            DeezerResourceLoaderRegistry.shared.register(
                trackId: trackId,
                encryptedUrl: encryptedUrl,
                contentLength: Int64(contentLength),
                contentType: contentType
            )
            return "deezer-enc://\(trackId)"
        }

        AsyncFunction("unregisterTrack") { (trackId: String) in
            DeezerResourceLoaderRegistry.shared.unregister(trackId: trackId)
        }

        Function("isAvailable") {
            return true
        }
    }
}
