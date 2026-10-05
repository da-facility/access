import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  let flutterEngine = FlutterEngine(name: "rustdesk")

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    flutterEngine.run()
    GeneratedPluginRegistrant.register(with: flutterEngine)
    KvmKeychain.register(with: flutterEngine.binaryMessenger)
    dummyMethodToEnforceBundling();
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
    
  public func dummyMethodToEnforceBundling() {
      dummy_method_to_enforce_bundling();
    session_get_rgba(nil, 0);
  }
}
