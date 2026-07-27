// TextureRuntimeViewController.swift
//
// Asymmetry notes vs VelocityUI AsyncFeed:
// - Texture pre-measures cells off-main via ASRangeController; configured to
//   2 screenfuls lead (≈ 10 items at ~96pt cell height) to approximate
//   VelocityUI's working range. Exact calibration requires a device run.
// - Idiomatic mode: ASNetworkImageNode.url drives PINRemoteImage internally
//   (Texture's native image pipeline). Same-pipeline mode: imageNode.image = UIImage(data:)
//   bypasses PINRemoteImage entirely — verify via zero "pinremoteimage-fetch"
//   spans in Instruments during same-pipeline runs.
// - imageModificationBlock bakes corner rounding at decode time (UIGraphicsImageRenderer),
//   matching VelocityUI's CGContext clip approach — zero extra compositor pass.
// - Texture's last meaningful release was ~2020. iOS 17 may affect safe area inset
//   handling on the underlying UICollectionView; document any observed quirks.

@preconcurrency import AsyncDisplayKit
import os
import UIKit

final class TextureRuntimeViewController: ASDKViewController<ASCollectionNode> {
    private let benchmarkItems: [BenchmarkItem]
    private let imageSource: any ImageSource
    private let harness: BenchmarkHarness
    private let orchestrator: BenchmarkOrchestrator?
    private let isIdiomatic: Bool
    private var liveMetrics: LiveMetricsController?

    init(items: [BenchmarkItem], imageSource: any ImageSource, harness: BenchmarkHarness, orchestrator: BenchmarkOrchestrator? = nil) {
        self.benchmarkItems = items
        self.imageSource = imageSource
        self.harness = harness
        self.orchestrator = orchestrator
        self.isIdiomatic = imageSource is IdiomaticImageSource

        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 2
        layout.sectionInset = .zero
        let collectionNode = ASCollectionNode(collectionViewLayout: layout)
        super.init(node: collectionNode)
        title = "Texture"

        collectionNode.dataSource = self
        collectionNode.delegate = self

        // Approximate VelocityUI's 10-item working range using screenfuls.
        let tuning = ASRangeTuningParameters(leadingBufferScreenfuls: 2, trailingBufferScreenfuls: 1)
        collectionNode.setTuningParameters(tuning, for: .full, rangeType: .preload)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        node.view.backgroundColor = .systemBackground
        node.reloadData()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        orchestrator?.scrollViewReady(node.view)
        if orchestrator == nil, liveMetrics == nil {
            let c = LiveMetricsController(scrollView: node.view, harness: harness, imageMode: LaunchArguments().imageMode, runtimeLabel: "Texture")
            c.start()
            liveMetrics = c
        }
    }
}

extension TextureRuntimeViewController: @preconcurrency ASCollectionDataSource {
    func numberOfSections(in collectionNode: ASCollectionNode) -> Int { 1 }

    func collectionNode(_ collectionNode: ASCollectionNode, numberOfItemsInSection section: Int) -> Int {
        benchmarkItems.count
    }

    func collectionNode(_ collectionNode: ASCollectionNode, nodeBlockForItemAt indexPath: IndexPath) -> ASCellNodeBlock {
        let item = benchmarkItems[indexPath.item]
        let imageSource: any ImageSource = self.imageSource
        let isIdiomatic = self.isIdiomatic
        let harness = self.harness
        return { TextureBenchmarkCellNode(item: item, imageSource: imageSource, isIdiomatic: isIdiomatic, harness: harness) }
    }
}

// @unchecked Sendable: all mutable state (mountState, harness, loadTask, imageNode)
// is accessed exclusively from Texture's main-thread callbacks.
private final class TextureBenchmarkCellNode: ASCellNode, @unchecked Sendable {
    private let item: BenchmarkItem
    private let imageSource: any ImageSource
    private let isIdiomatic: Bool
    private let imageNode = ASNetworkImageNode()
    private var loadTask: Task<Void, Never>?
    private var mountState: OSSignpostIntervalState?
    private weak var harness: BenchmarkHarness?

    init(item: BenchmarkItem, imageSource: any ImageSource, isIdiomatic: Bool, harness: BenchmarkHarness?) {
        self.item = item
        self.imageSource = imageSource
        self.isIdiomatic = isIdiomatic
        self.harness = harness
        super.init()

        imageNode.delegate = self

        let cornerRadius = CGFloat(item.cornerRadius)
        if cornerRadius > 0 {
            imageNode.imageModificationBlock = { [cornerRadius] image, _ in
                let renderer = UIGraphicsImageRenderer(size: image.size)
                return renderer.image { ctx in
                    let rect = CGRect(origin: .zero, size: image.size)
                    UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).addClip()
                    image.draw(in: rect)
                }
            }
        }

        imageNode.contentMode = .scaleAspectFill
        imageNode.backgroundColor = UIColor(hue: item.placeholderHue, saturation: 0.5, brightness: 0.8, alpha: 1)
    }

    override func didEnterVisibleState() {
        super.didEnterVisibleState()
        MainActor.assumeIsolated {
            guard mountState == nil else { return }
            loadTask?.cancel()
            loadTask = nil

            mountState = harness?.beginCellMount()

            if isIdiomatic {
                imageNode.url = item.imageURL
            } else {
                let source = self.imageSource
                let capturedItem = self.item
                loadTask = Task { @MainActor [weak self] in
                    let data = await source.imageData(for: capturedItem)
                    guard let self else { return }
                    guard let data, let image = UIImage(data: data), !Task.isCancelled else {
                        if let s = self.mountState {
                            self.harness?.endCellMount(s)
                            self.mountState = nil
                        }
                        return
                    }
                    self.imageNode.image = image
                    if let s = self.mountState {
                        self.harness?.endCellMount(s)
                        self.mountState = nil
                    }
                }
            }
        }
    }

    override func didExitVisibleState() {
        super.didExitVisibleState()
        MainActor.assumeIsolated {
            loadTask?.cancel()
            loadTask = nil
            if !isIdiomatic {
                imageNode.image = nil
            } else {
                imageNode.url = nil
            }
            if let s = mountState {
                harness?.endCellMount(s)
                mountState = nil
            }
        }
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // ASRatioLayoutSpec makes height = width / aspectRatio — full-width with correct proportions.
        let ratio = 1.0 / CGFloat(item.aspectRatio)
        return ASRatioLayoutSpec(ratio: ratio, child: imageNode)
    }
}

// MARK: - ASCollectionDelegateFlowLayout

extension TextureRuntimeViewController: @preconcurrency ASCollectionDelegateFlowLayout {
    func collectionNode(_ collectionNode: ASCollectionNode, constrainedSizeForItemAt indexPath: IndexPath) -> ASSizeRange {
        // collectionNode.view.bounds may be zero on the first layout pass; fall back
        // to UIScreen width so cells don't collapse to zero before the view has bounds.
        let viewWidth = collectionNode.view.bounds.width
        let width = viewWidth > 0 ? viewWidth : UIScreen.main.bounds.width
        return ASSizeRangeMake(
            CGSize(width: width, height: 0),
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
    }
}

// MARK: - ASNetworkImageNodeDelegate

extension TextureBenchmarkCellNode: ASNetworkImageNodeDelegate {
    @objc func imageNode(_ imageNode: ASNetworkImageNode, didLoad image: UIImage, info: ASNetworkImageLoadInfo) {
        MainActor.assumeIsolated {
            if let s = mountState {
                harness?.endCellMount(s)
                mountState = nil
            }
        }
    }
}
