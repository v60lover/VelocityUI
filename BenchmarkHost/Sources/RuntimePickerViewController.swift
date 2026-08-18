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

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? runtimes.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? nil : Self.streamSectionTitle
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.textLabel?.text = indexPath.section == 0 ? runtimes[indexPath.row].title : Self.streamRowTitle
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0 else {
            let vc = StreamBenchmarkViewController(harness: harness, orchestrator: nil, hotBlockRasterizeEnabled: true)
            navigationController?.pushViewController(vc, animated: true)
            return
        }
        let runtime = runtimes[indexPath.row].runtime
        let vc = makeRuntimeVC(runtime: runtime)
        navigationController?.pushViewController(vc, animated: true)
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
