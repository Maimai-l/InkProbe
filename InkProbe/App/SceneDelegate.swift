import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        // 全局强制浅色模式，避免 PencilKit 在深色模式下自动反转墨水颜色。
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = CanvasViewController()
        self.window = window
        window.makeKeyAndVisible()
    }
}
