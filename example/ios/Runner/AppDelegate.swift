import Flutter
import UIKit
import trusted_time_nts

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Wire the host app's plugin registrant onto the headless engine that
    // TrustedTime spins up for background syncs. Without this, plugins
    // such as flutter_secure_storage are unavailable in the BG isolate
    // and the persisted anchor write would fail.
    TrustedTimeNtsPlugin.setPluginRegistrantCallback { engine in
      GeneratedPluginRegistrant.register(with: engine)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
