// UICollectionViewRuntimeViewController.swift

import UIKit

final class UICollectionViewRuntimeViewController: UIViewController {
    private let benchmarkItems: [BenchmarkItem]
    private let imageSource: any ImageSource
    private let harness: BenchmarkHarness
    private var collectionView: UICollectionView!

    init(items: [BenchmarkItem], imageSource: any ImageSource, harness: BenchmarkHarness) {
        self.benchmarkItems = items
        self.imageSource = imageSource
        self.harness = harness
        super.init(nibName: nil, bundle: nil)
        title = "UICollectionView"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.register(BenchmarkCollectionCell.self, forCellWithReuseIdentifier: BenchmarkCollectionCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        view.addSubview(collectionView)
    }
}

extension UICollectionViewRuntimeViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        benchmarkItems.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: BenchmarkCollectionCell.reuseID, for: indexPath) as! BenchmarkCollectionCell
        cell.configure(item: benchmarkItems[indexPath.item], imageSource: imageSource)
        return cell
    }
}

extension UICollectionViewRuntimeViewController: UICollectionViewDelegate {}

extension UICollectionViewRuntimeViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let item = benchmarkItems[indexPath.item]
        let width = collectionView.bounds.width - 32
        return CGSize(width: width, height: item.thumbHeight + 16)
    }
}

private final class BenchmarkCollectionCell: UICollectionViewCell {
    static let reuseID = "BenchmarkCollectionCell"
    private let thumbImageView = UIImageView()
    private let captionLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private var currentItemID: Int = -1
    private var thumbHeightConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        thumbImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbImageView.contentMode = .scaleAspectFill
        thumbImageView.clipsToBounds = true
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.numberOfLines = 0
        captionLabel.font = .preferredFont(forTextStyle: .body)
        contentView.addSubview(thumbImageView)
        contentView.addSubview(captionLabel)
        thumbHeightConstraint = thumbImageView.heightAnchor.constraint(equalToConstant: BenchmarkItem.thumbWidth)
        NSLayoutConstraint.activate([
            thumbImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumbImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
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
        loadTask?.cancel()
        loadTask = nil
        thumbImageView.image = nil
        thumbImageView.backgroundColor = .secondarySystemBackground
        captionLabel.text = nil
    }

    func configure(item: BenchmarkItem, imageSource: any ImageSource) {
        currentItemID = item.id
        captionLabel.text = item.caption
        thumbImageView.backgroundColor = UIColor(hue: item.placeholderHue, saturation: 0.5, brightness: 0.8, alpha: 1)
        thumbImageView.layer.cornerRadius = CGFloat(item.cornerRadius)
        thumbHeightConstraint.constant = item.thumbHeight
        let itemID = item.id
        loadTask = Task { [weak self] in
            guard let data = await imageSource.imageData(for: item),
                  let image = UIImage(data: data),
                  !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.currentItemID == itemID else { return }
                self?.thumbImageView.image = image
            }
        }
    }
}
