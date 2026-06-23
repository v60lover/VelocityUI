// AppDelegate.swift

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    private var dataset: [BenchmarkItem] = []
    private let harness = BenchmarkHarness()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let args = LaunchArguments()
        dataset = BenchmarkDataset.generate(count: args.itemCount)

        let imageSource: any ImageSource
        switch args.imageMode {
        case .idiomatic:
            imageSource = IdiomaticImageSource()
        case .samePipeline:
            let source = SamePipelineImageSource(items: dataset)
            imageSource = source
        }

        let rootVC: UIViewController
        if let runtime = args.runtime {
            rootVC = makeRuntimeVC(runtime: runtime, items: dataset, imageSource: imageSource)
        } else {
            rootVC = RuntimePickerViewController(items: dataset, imageSource: imageSource, harness: harness)
        }

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UINavigationController(rootViewController: rootVC)
        window?.makeKeyAndVisible()
        return true
    }

    private func makeRuntimeVC(
        runtime: LaunchArguments.Runtime,
        items: [BenchmarkItem],
        imageSource: any ImageSource
    ) -> UIViewController {
        switch runtime {
        case .velocityUI:        return VelocityUIRuntimeViewController(items: items, imageSource: imageSource, harness: harness)
        case .swiftUILazyVStack: return SwiftUILazyVStackRuntimeViewController(items: items, imageSource: imageSource, harness: harness)
        case .swiftUIList:       return SwiftUIListRuntimeViewController(items: items, imageSource: imageSource, harness: harness)
        case .uiCollectionView:  return UICollectionViewRuntimeViewController(items: items, imageSource: imageSource, harness: harness)
        case .texture:           return TextureRuntimeViewController(items: items, imageSource: imageSource, harness: harness)
        }
    }
}
