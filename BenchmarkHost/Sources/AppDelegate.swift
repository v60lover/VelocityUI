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
            imageSource = SamePipelineImageSource()
        }

        let rootVC: UIViewController
        if let runtime = args.runtime, args.liveHUD {
            // Interactive live-HUD mode: open this runtime directly with no orchestrator,
            // so its LiveMetricsHUD attaches for hand-scroll profiling (no measured pass).
            harness.runtimeLabel = runtime.rawValue
            rootVC = makeRuntimeVC(runtime: runtime, items: dataset, imageSource: imageSource)
        } else if let runtime = args.runtime {
            harness.runtimeLabel = runtime.rawValue
            let orchestrator = BenchmarkOrchestrator(args: args, harness: harness)
            orchestrator.onComplete = { report in
                // Delimiters let the orchestrator extract the JSON from a console stream
                // that also contains UIKit chatter, harness warnings, and MetricKit noise.
                if let data = try? JSONEncoder().encode(report),
                   let json = String(data: data, encoding: .utf8) {
                    print("<<<BENCHMARK_REPORT_BEGIN>>>")
                    print(json)
                    print("<<<BENCHMARK_REPORT_END>>>")
                }
                exit(0)
            }
            orchestrator.onAbort = { message in
                FileHandle.standardError.write(Data("BenchmarkOrchestrator abort: \(message)\n".utf8))
                exit(1)
            }
            rootVC = makeRuntimeVC(runtime: runtime, items: dataset, imageSource: imageSource, orchestrator: orchestrator)
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
        imageSource: any ImageSource,
        orchestrator: BenchmarkOrchestrator? = nil
    ) -> UIViewController {
        switch runtime {
        case .velocityUI:        return VelocityUIRuntimeViewController(items: items, imageSource: imageSource, harness: harness, orchestrator: orchestrator)
        case .swiftUILazyVStack: return SwiftUILazyVStackRuntimeViewController(items: items, imageSource: imageSource, harness: harness, orchestrator: orchestrator)
        case .swiftUIList:       return SwiftUIListRuntimeViewController(items: items, imageSource: imageSource, harness: harness, orchestrator: orchestrator)
        case .uiCollectionView:  return UICollectionViewRuntimeViewController(items: items, imageSource: imageSource, harness: harness, orchestrator: orchestrator)
        case .texture:           return TextureRuntimeViewController(items: items, imageSource: imageSource, harness: harness, orchestrator: orchestrator)
        }
    }
}
