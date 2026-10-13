import UIKit
import Flutter
import HiddifyCore
import Sentry
@main
// UIScene lifecycle (iOS 27 SDK / Xcode 27 — иначе краш на запуске, Apple TN3187; гайд Flutter «UIScene adoption»):
// плагины и наши MethodChannel-хендлеры регистрируются в didInitializeImplicitFlutterEngine,
// сцену ведёт FlutterSceneDelegate (Info.plist → UIApplicationSceneManifest).
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        setupFileManager()
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
        registerHandlers(with: engineBridge.pluginRegistry)
    }
    
    func setupFileManager() {
        try? FileManager.default.createDirectory(at: FilePath.workingDirectory, withIntermediateDirectories: true)
        FileManager.default.changeCurrentDirectoryPath(FilePath.sharedDirectory.path)
    }
    
    func registerHandlers(with registry: FlutterPluginRegistry) {
        MethodHandler.register(with: registry.registrar(forPlugin: MethodHandler.name)!)
        PlatformMethodHandler.register(with: registry.registrar(forPlugin: PlatformMethodHandler.name)!)
        FileMethodHandler.register(with: registry.registrar(forPlugin: FileMethodHandler.name)!)
        StatusEventHandler.register(with: registry.registrar(forPlugin: StatusEventHandler.name)!)
        AlertsEventHandler.register(with: registry.registrar(forPlugin: AlertsEventHandler.name)!)
//        LogsEventHandler.register(with: self.registrar(forPlugin: LogsEventHandler.name)!)
//        GroupsEventHandler.register(with: self.registrar(forPlugin: GroupsEventHandler.name)!)
//        ActiveGroupsEventHandler.register(with: self.registrar(forPlugin: ActiveGroupsEventHandler.name)!)
//        StatsEventHandler.register(with: self.registrar(forPlugin: StatsEventHandler.name)!)
    }
}

