// UICollectionViewRuntimeViewController.swift
//
// Asymmetry notes vs VelocityUI AsyncFeed:
// - UIImageView layer.cornerRadius + masksToBounds triggers offscreen rendering
//   (verifiable via Core Animation's 'Color Offscreen-Rendered Yellow' debug toggle).
//   VelocityUI bakes the clip into a CGContext at decode time — zero extra compositor pass.
// - UICollectionViewCell pool size is UIKit-managed; not tuned here.

import Nuke
import os
import UIKit

final class UICollectionViewRuntimeViewController: UIViewController {
    private let benchmarkItems: [BenchmarkItem]
    private let itemsByID: [BenchmarkItem.ID: BenchmarkItem]
    private let imageSource: any ImageSource
    private let harness: BenchmarkHarness
    private let orchestrator: BenchmarkOrchestrator?
    private let prefetchWindow: Int
    private var dataSource: UICollectionViewDiffableDataSource<Int, BenchmarkItem.ID>!
    // Prefetches into .benchmark pipeline's memory cache; no-op for same-pipeline mode.
    private lazy var prefetcher = ImagePrefetcher(pipeline: .benchmark)
    var collectionView: UICollectionView!

    private var isIdiomatic: Bool { imageSource is IdiomaticImageSource }

    init(items: [BenchmarkItem], imageSource: any ImageSource, harness: BenchmarkHarness, orchestrator: BenchmarkOrchestrator? = nil) {
        self.benchmarkItems = items
        self.itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        self.imageSource = imageSource
        self.harness = harness
        self.orchestrator = orchestrator
        self.prefetchWindow = LaunchArguments().prefetchWindow
        super.init(nibName: nil, bundle: nil)
        title = "UICollectionView"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCollectionView()
        applyInitialSnapshot()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        orchestrator?.scrollViewReady(collectionView)
    }

    // MARK: - Setup

    private func setupCollectionView() {
        let layout = makeCompositionalLayout()
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.prefetchDataSource = self

        let isIdiomatic = self.isIdiomatic
        let imageSource = self.imageSource
        let harness = self.harness
        let itemsByID = self.itemsByID

        let registration = UICollectionView.CellRegistration<BenchmarkCollectionCell, BenchmarkItem.ID> {
            cell, _, itemID in
            guard let item = itemsByID[itemID] else { return }
            cell.configure(item: item, imageSource: imageSource, harness: harness, isIdiomatic: isIdiomatic)
        }

        dataSource = UICollectionViewDiffableDataSource<Int, BenchmarkItem.ID>(
            collectionView: collectionView
        ) { collectionView, indexPath, itemID in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: itemID)
        }

        view.addSubview(collectionView)
    }

    private func makeCompositionalLayout() -> UICollectionViewCompositionalLayout {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(80)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(80)
        )
        let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 8
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        return UICollectionViewCompositionalLayout(section: section)
    }

    private func applyInitialSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, BenchmarkItem.ID>()
        snapshot.appendSections([0])
        snapshot.appendItems(benchmarkItems.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

// MARK: - Prefetch

extension UICollectionViewRuntimeViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard isIdiomatic else { return }
        let urls = indexPaths.prefix(prefetchWindow).compactMap { ip -> URL? in
            guard ip.item < benchmarkItems.count else { return nil }
            return benchmarkItems[ip.item].imageURL
        }
        prefetcher.startPrefetching(with: urls)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        guard isIdiomatic else { return }
        let urls = indexPaths.compactMap { ip -> URL? in
            guard ip.item < benchmarkItems.count else { return nil }
            return benchmarkItems[ip.item].imageURL
        }
        prefetcher.stopPrefetching(with: urls)
    }
}

// MARK: - Cell

private final class BenchmarkCollectionCell: UICollectionViewCell {
    private let thumbImageView = UIImageView()
    private let captionLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private var currentItemID: Int = -1
    private var thumbHeightConstraint: NSLayoutConstraint!
    private var mountState: OSSignpostIntervalState?
    private weak var harness: BenchmarkHarness?

    override init(frame: CGRect) {
        super.init(frame: frame)
        thumbImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbImageView.contentMode = .scaleAspectFill
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.numberOfLines = 0
        captionLabel.font = .preferredFont(forTextStyle: .body)
        contentView.addSubview(thumbImageView)
        contentView.addSubview(captionLabel)
        thumbHeightConstraint = thumbImageView.heightAnchor.constraint(equalToConstant: BenchmarkItem.thumbWidth)
        NSLayoutConstraint.activate([
            thumbImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumbImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            thumbImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            thumbImageView.widthAnchor.constraint(equalToConstant: BenchmarkItem.thumbWidth),
            thumbHeightConstraint,
            captionLabel.leadingAnchor.constraint(equalTo: thumbImageView.trailingAnchor, constant: 12),
            captionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            captionLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        // End any mount span that didn't complete (image never arrived before reuse).
        if let s = mountState {
            harness?.endCellMount(s)
            mountState = nil
        }
        let recycleState = harness?.beginCellRecycle()
        loadTask?.cancel()
        loadTask = nil
        thumbImageView.image = nil
        thumbImageView.backgroundColor = .secondarySystemBackground
        captionLabel.text = nil
        if let s = recycleState {
            harness?.endCellRecycle(s)
        }
    }

    func configure(item: BenchmarkItem, imageSource: any ImageSource, harness: BenchmarkHarness, isIdiomatic: Bool) {
        self.harness = harness
        currentItemID = item.id
        captionLabel.text = item.caption.isEmpty ? nil : item.caption
        thumbImageView.backgroundColor = UIColor(hue: item.placeholderHue, saturation: 0.5, brightness: 0.8, alpha: 1)
        thumbImageView.layer.cornerRadius = CGFloat(item.cornerRadius)
        thumbImageView.layer.masksToBounds = true
        thumbHeightConstraint.constant = item.thumbHeight
        mountState = harness.beginCellMount()

        let itemID = item.id
        if isIdiomatic {
            loadTask = Task { [weak self] in
                guard let response = try? await ImagePipeline.benchmark.image(for: item.imageURL),
                      !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.currentItemID == itemID else { return }
                    self.thumbImageView.image = response
                    if let s = self.mountState {
                        self.harness?.endCellMount(s)
                        self.mountState = nil
                    }
                }
            }
        } else {
            loadTask = Task { [weak self] in
                guard let data = await imageSource.imageData(for: item),
                      let image = UIImage(data: data),
                      !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.currentItemID == itemID else { return }
                    self.thumbImageView.image = image
                    if let s = self.mountState {
                        self.harness?.endCellMount(s)
                        self.mountState = nil
                    }
                }
            }
        }
    }
}
