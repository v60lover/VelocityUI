// SwiftUIListRuntimeViewController.swift

import SwiftUI
import UIKit

final class SwiftUIListRuntimeViewController: UIViewController {
    private let benchmarkItems: [BenchmarkItem]
    private let imageSource: any ImageSource

    init(items: [BenchmarkItem], imageSource: any ImageSource) {
        self.benchmarkItems = items
        self.imageSource = imageSource
        super.init(nibName: nil, bundle: nil)
        title = "SwiftUI List"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let hostVC = UIHostingController(rootView: ListFeedView(items: benchmarkItems, imageSource: imageSource))
        addChild(hostVC)
        hostVC.view.frame = view.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hostVC.view)
        hostVC.didMove(toParent: self)
    }
}

private struct ListFeedView: View {
    let items: [BenchmarkItem]
    let imageSource: any ImageSource

    var body: some View {
        List(items, id: \.id) { item in
            BenchmarkListRowView(item: item, imageSource: imageSource)
        }
        .listStyle(.plain)
    }
}

private struct BenchmarkListRowView: View {
    let item: BenchmarkItem
    let imageSource: any ImageSource
    @State private var imageData: Data?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let data = imageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(hue: item.placeholderHue, saturation: 0.5, brightness: 0.8)
                }
            }
            .frame(width: BenchmarkItem.thumbWidth, height: item.thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: item.cornerRadius))

            if !item.caption.isEmpty {
                Text(item.caption)
                    .font(.body)
            }
        }
        .task {
            imageData = await imageSource.imageData(for: item)
        }
    }
}
