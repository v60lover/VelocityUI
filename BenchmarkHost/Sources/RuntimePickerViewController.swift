// RuntimePickerViewController.swift

import UIKit

final class RuntimePickerViewController: UITableViewController {
    private let items: [BenchmarkItem]
    private let imageSource: any ImageSource
    private let harness: BenchmarkHarness

    private let runtimes: [(title: String, runtime: LaunchArguments.Runtime)] = [
        ("VelocityUI AsyncFeed", .velocityUI),
        ("SwiftUI LazyVStack", .swiftUILazyVStack),
        ("SwiftUI List", .swiftUIList),
        ("UICollectionView", .uiCollectionView),
        ("Texture ASCollectionNode", .texture),
    ]

    /// VelocityUI-xxf7's `stream` scenario isn't a `LaunchArguments.Runtime` — it's VelocityUI-only
    /// and isn't driven by scrolling, so it doesn't belong in `runtimes` above (which
    /// `makeRuntimeVC` treats generically across every library) or in `AppDelegate.makeRuntimeVC`'s
    /// switch. It gets its own table section instead, pushing `StreamBenchmarkViewController`
    /// directly.
    private static let streamSectionTitle = "Scenarios"
    private static let streamRowTitle = "VelocityUI — Streaming Text"
    /// VelocityUI-0tbi: a second "Scenarios" row so the user can flip gesture-gated deferral
    /// ON/OFF in one on-device session (dragging under each) without relaunching the app.
    private static let streamDeferralRowTitle = "VelocityUI — Streaming Text (gesture-gated deferral)"
    private static let streamRowCount = 2

    /// VelocityUI-0c5's `.grid(columns:spacing:)` DSL — same shape as the `Scenarios` section
    /// above (live-only, not part of the `runtimes` matrix `makeRuntimeVC` drives generically):
    /// there's no headless/measured path for it yet, just "open it, scroll it".
    private static let gridSectionTitle = "Grid"
    private static let gridRowTitle = "VelocityUI — Grid"

    init(items: [BenchmarkItem], imageSource: any ImageSource, harness: BenchmarkHarness) {
        self.items = items
        self.imageSource = imageSource
        self.harness = harness
        super.init(style: .insetGrouped)
        title = "BenchmarkHost"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return runtimes.count
        case 1: return Self.streamRowCount
        default: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return nil
        case 1: return Self.streamSectionTitle
        default: return Self.gridSectionTitle
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        switch indexPath.section {
        case 0:
            cell.textLabel?.text = runtimes[indexPath.row].title
        case 1:
            cell.textLabel?.text = indexPath.row == 0 ? Self.streamRowTitle : Self.streamDeferralRowTitle
        default:
            cell.textLabel?.text = Self.gridRowTitle
        }
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.section {
        case 0:
            let runtime = runtimes[indexPath.row].runtime
            let vc = makeRuntimeVC(runtime: runtime)
            navigationController?.pushViewController(vc, animated: true)
        case 1:
            // VelocityUI-0tbi: hot-rasterize/rate/text-only now read from LaunchArguments (were
            // hardcoded before this bead) — without this, configs C (--hot-rasterize off) and D
            // (--stream-rate 5) from the bead's measurement protocol had no manual/on-device path
            // at all, since the headless matrix can't drive a real gesture for this scenario.
            let args = LaunchArguments()
            let vc = StreamBenchmarkViewController(
                harness: harness,
                orchestrator: nil,
                hotBlockRasterizeEnabled: args.hotBlockRasterizeMode == .on,
                gestureGatedDeferralEnabled: indexPath.row == 1,
                includeInterleavedBlocks: !args.streamTextOnly,
                tokensPerSecond: args.streamTokensPerSecond
            )
            navigationController?.pushViewController(vc, animated: true)
        default:
            let vc = VelocityUIGridRuntimeViewController(items: items, harness: harness)
            navigationController?.pushViewController(vc, animated: true)
        }
    }

    private func makeRuntimeVC(runtime: LaunchArguments.Runtime) -> UIViewController {
        switch runtime {
        case .velocityUI:        return VelocityUIRuntimeViewController(items: items, imageSource: imageSource, harness: harness)
        case .swiftUILazyVStack: return SwiftUILazyVStackRuntimeViewController(items: items, imageSource: imageSource, harness: harness)
        case .swiftUIList:       return SwiftUIListRuntimeViewController(items: items, imageSource: imageSource, harness: harness)
        case .uiCollectionView:  return UICollectionViewRuntimeViewController(items: items, imageSource: imageSource, harness: harness)
        case .texture:           return TextureRuntimeViewController(items: items, imageSource: imageSource, harness: harness)
        }
    }
}
