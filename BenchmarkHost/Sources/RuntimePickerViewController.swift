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

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        runtimes.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.textLabel?.text = runtimes[indexPath.row].title
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
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
