// BenchmarkCell.swift

import UIKit

final class BenchmarkCell: UITableViewCell {
    static let reuseID = "BenchmarkCell"
    private let thumbImageView = UIImageView()
    private let captionLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private var currentItemID: Int = -1
    private var thumbHeightConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
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
            thumbImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            thumbImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            thumbImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            thumbImageView.widthAnchor.constraint(equalToConstant: BenchmarkItem.thumbWidth),
            thumbHeightConstraint,
            captionLabel.leadingAnchor.constraint(equalTo: thumbImageView.trailingAnchor, constant: 12),
            captionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
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
        captionLabel.text = item.caption.isEmpty ? nil : item.caption
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
