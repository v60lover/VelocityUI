// TextureRuntimeViewController.swift

import UIKit

final class TextureRuntimeViewController: UITableViewController {
    private let benchmarkItems: [BenchmarkItem]
    private let imageSource: any ImageSource
    private let harness: BenchmarkHarness
    private let orchestrator: BenchmarkOrchestrator?

    init(items: [BenchmarkItem], imageSource: any ImageSource, harness: BenchmarkHarness, orchestrator: BenchmarkOrchestrator? = nil) {
        self.benchmarkItems = items
        self.imageSource = imageSource
        self.harness = harness
        self.orchestrator = orchestrator
        super.init(style: .plain)
        title = "Texture (stub)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(BenchmarkCell.self, forCellReuseIdentifier: BenchmarkCell.reuseID)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        orchestrator?.scrollViewReady(tableView)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        benchmarkItems.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: BenchmarkCell.reuseID, for: indexPath) as! BenchmarkCell
        cell.configure(item: benchmarkItems[indexPath.row], imageSource: imageSource)
        return cell
    }
}
