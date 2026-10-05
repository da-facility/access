import UIKit
import Flutter

// Flutter 3.24 predates FlutterSceneDelegate; Xcode 27 requires scene adoption.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  private var appDelegate: AppDelegate? {
    UIApplication.shared.delegate as? AppDelegate
  }

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
             options connectionOptions: UIScene.ConnectionOptions) {
    guard let windowScene = scene as? UIWindowScene,
          let delegate = appDelegate else { return }
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = FlutterViewController(
      engine: delegate.flutterEngine, nibName: nil, bundle: nil)
    self.window = window
    delegate.window = window
    window.makeKeyAndVisible()
    self.scene(scene, openURLContexts: connectionOptions.urlContexts)
    for activity in connectionOptions.userActivities {
      self.scene(scene, continue: activity)
    }
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    appDelegate?.flutterEngine.lifecycleChannel.sendMessage("AppLifecycleState.resumed")
  }

  func sceneWillResignActive(_ scene: UIScene) {
    appDelegate?.flutterEngine.lifecycleChannel.sendMessage("AppLifecycleState.inactive")
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    appDelegate?.flutterEngine.lifecycleChannel.sendMessage("AppLifecycleState.paused")
  }

  func sceneWillEnterForeground(_ scene: UIScene) {
    appDelegate?.flutterEngine.lifecycleChannel.sendMessage("AppLifecycleState.inactive")
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      _ = appDelegate?.application(UIApplication.shared, open: context.url, options: [
        .sourceApplication: context.options.sourceApplication as Any,
        .annotation: context.options.annotation as Any,
        .openInPlace: context.options.openInPlace
      ])
    }
  }

  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    _ = appDelegate?.application(UIApplication.shared, continue: userActivity,
                                restorationHandler: { _ in })
  }
}
