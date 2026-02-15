import ExpoModulesCore

public class DownloadManagerAppDelegate: ExpoAppDelegateSubscriber {
    public func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadManager.shared.setBackgroundCompletionHandler(completionHandler)
    }
}
