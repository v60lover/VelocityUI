// RenderNodeBuilderTests.swift

import Testing
import Foundation
@testable import VelocityUI

// MARK: - Result builder tests

@Suite("RenderNodeBuilder")
struct RenderNodeBuilderTests {

    // MARK: Multi-child

    @Test("buildBlock produces all children")
    func multiChild() {
        let stack = VStackNode {
            TextNode("a")
            TextNode("b")
            TextNode("c")
        }
        #expect(stack.children.count == 3)
    }

    @Test("Single child compiles without group wrapper")
    func singleChild() {
        let stack = VStackNode {
            TextNode("only")
        }
        #expect(stack.children.count == 1)
    }

    // MARK: if/else (buildEither)

    @Test("buildEither true branch included")
    func conditionalTrue() {
        let flag = true
        let stack = VStackNode {
            if flag {
                TextNode("yes")
            } else {
                TextNode("no")
            }
        }
        #expect(stack.children.count == 1)
        let text = stack.children[0] as? TextNode
        #expect(text?.content == "yes")
    }

    @Test("buildEither false branch included")
    func conditionalFalse() {
        let flag = false
        let stack = VStackNode {
            if flag {
                TextNode("yes")
            } else {
                TextNode("no")
            }
        }
        #expect(stack.children.count == 1)
        let text = stack.children[0] as? TextNode
        #expect(text?.content == "no")
    }

    // MARK: optional (buildOptional)

    @Test("buildOptional includes node when condition is true")
    func optionalPresent() {
        let show = true
        let stack = VStackNode {
            if show {
                TextNode("visible")
            }
        }
        #expect(stack.children.count == 1)
    }

    @Test("buildOptional omits node when condition is false")
    func optionalAbsent() {
        let show = false
        let stack = VStackNode {
            if show {
                TextNode("hidden")
            }
        }
        #expect(stack.children.isEmpty)
    }

    // MARK: for-loop (buildArray)

    @Test("buildArray produces correct child count from for loop")
    func forLoopChildCount() {
        let items = ["a", "b", "c", "d"]
        let stack = VStackNode {
            for item in items {
                TextNode(item)
            }
        }
        #expect(stack.children.count == 4)
    }

    @Test("buildArray preserves child types from for loop")
    func forLoopChildTypes() {
        let urls = [
            URL(string: "https://example.com/1.jpg")!,
            URL(string: "https://example.com/2.jpg")!,
        ]
        let stack = VStackNode {
            for url in urls {
                AsyncImageNode(url: url)
            }
        }
        #expect(stack.children.count == 2)
        #expect(stack.children[0] is AsyncImageNode)
        #expect(stack.children[1] is AsyncImageNode)
    }

    // MARK: Mixed children types

    @Test("Stack accepts mixed node types")
    func mixedTypes() {
        let url = URL(string: "https://example.com/img.jpg")!
        let stack = VStackNode {
            AsyncImageNode(url: url).cornerRadius(12)
            TextNode("caption")
            SpacerNode(minLength: 8)
        }
        #expect(stack.children.count == 3)
        #expect(stack.children[0] is AsyncImageNode)
        #expect(stack.children[1] is TextNode)
        #expect(stack.children[2] is SpacerNode)
    }
}

// MARK: - Hash tests

@Suite("Node hashes")
struct NodeHashTests {

    // MARK: Hash stability (two independent instances)

    @Test("Same inputs produce same layoutHash on independent instances")
    func layoutHashStability() {
        let a = TextNode("hello", font: VFontDescriptor(size: 17, weight: 0), lineLimit: 2)
        let b = TextNode("hello", font: VFontDescriptor(size: 17, weight: 0), lineLimit: 2)
        #expect(a.layoutHash == b.layoutHash)
    }

    @Test("Same inputs produce same appearanceHash on independent instances")
    func appearanceHashStability() {
        let color = VColorDescriptor(red: 1, green: 0, blue: 0, alpha: 1)
        let a = TextNode("hello", color: color)
        let b = TextNode("hello", color: color)
        #expect(a.appearanceHash == b.appearanceHash)
    }

    // MARK: TextNode hash rules

    @Test("TextNode: content change perturbs layoutHash")
    func textContentPerturbsLayout() {
        let a = TextNode("hello")
        let b = TextNode("world")
        #expect(a.layoutHash != b.layoutHash)
    }

    @Test("TextNode: font size change perturbs layoutHash")
    func textFontSizePerturbsLayout() {
        let a = TextNode("hello", font: VFontDescriptor(size: 14, weight: 0))
        let b = TextNode("hello", font: VFontDescriptor(size: 18, weight: 0))
        #expect(a.layoutHash != b.layoutHash)
    }

    @Test("TextNode: font weight change perturbs layoutHash")
    func textFontWeightPerturbsLayout() {
        let a = TextNode("hello", font: VFontDescriptor(size: 17, weight: 0))
        let b = TextNode("hello", font: VFontDescriptor(size: 17, weight: 700))
        #expect(a.layoutHash != b.layoutHash)
    }

    @Test("TextNode: lineLimit change perturbs layoutHash")
    func textLineLimitPerturbsLayout() {
        let a = TextNode("hello", lineLimit: 1)
        let b = TextNode("hello", lineLimit: 3)
        #expect(a.layoutHash != b.layoutHash)
    }

    @Test("TextNode: lineBreakMode change perturbs layoutHash")
    func textLineBreakModePerturbsLayout() {
        let a = TextNode("x", lineBreakMode: .byWordWrapping)
        let b = TextNode("x", lineBreakMode: .byTruncatingTail)
        #expect(a.layoutHash != b.layoutHash)
    }

    @Test("TextNode: color change perturbs appearanceHash only")
    func textColorPerturbsAppearanceOnly() {
        let red = VColorDescriptor(red: 1, green: 0, blue: 0, alpha: 1)
        let blue = VColorDescriptor(red: 0, green: 0, blue: 1, alpha: 1)
        let a = TextNode("hello", color: red)
        let b = TextNode("hello", color: blue)
        #expect(a.layoutHash == b.layoutHash)
        #expect(a.appearanceHash != b.appearanceHash)
    }

    // MARK: AsyncImageNode hash rules

    @Test("AsyncImageNode: url change perturbs layoutHash")
    func imageUrlPerturbsLayout() {
        let url1 = URL(string: "https://example.com/a.jpg")!
        let url2 = URL(string: "https://example.com/b.jpg")!
        let a = AsyncImageNode(url: url1)
        let b = AsyncImageNode(url: url2)
        #expect(a.layoutHash != b.layoutHash)
    }

    @Test("AsyncImageNode: aspectRatio change perturbs layoutHash")
    func imageAspectRatioPerturbsLayout() {
        let url = URL(string: "https://example.com/img.jpg")!
        let a = AsyncImageNode(url: url, aspectRatio: 1.0)
        let b = AsyncImageNode(url: url, aspectRatio: 1.5)
        #expect(a.layoutHash != b.layoutHash)
    }

    @Test("AsyncImageNode: contentMode change perturbs layoutHash")
    func imageContentModePerturbsLayout() {
        let url = URL(string: "https://example.com/img.jpg")!
        let a = AsyncImageNode(url: url, contentMode: .fit)
        let b = AsyncImageNode(url: url, contentMode: .fill)
        #expect(a.layoutHash != b.layoutHash)
    }

    @Test("AsyncImageNode: cornerRadius change perturbs appearanceHash only")
    func imageCornerRadiusPerturbsAppearanceOnly() {
        let url = URL(string: "https://example.com/img.jpg")!
        let a = AsyncImageNode(url: url)
        let b = a.cornerRadius(12)
        #expect(a.layoutHash == b.layoutHash)
        #expect(a.appearanceHash != b.appearanceHash)
    }

    @Test("AsyncImageNode: custom placeholder payload change perturbs appearanceHash only")
    func imageCustomPlaceholderPerturbsAppearanceOnly() {
        let url = URL(string: "https://example.com/img.jpg")!
        let a = AsyncImageNode(url: url).placeholder(custom: "dominant-red")
        let b = AsyncImageNode(url: url).placeholder(custom: "dominant-blue")
        #expect(a.layoutHash == b.layoutHash)
        #expect(a.appearanceHash != b.appearanceHash)
    }

    @Test("AsyncImageNode: placeholder(custom: nil) clears the custom payload")
    func imageCustomPlaceholderNilClears() {
        let url = URL(string: "https://example.com/img.jpg")!
        let withPayload = AsyncImageNode(url: url).placeholder(custom: "dominant-red")
        let cleared = withPayload.placeholder(custom: nil)  // resolves to the non-generic overload
        #expect(cleared.customPlaceholderPayload == nil)
        #expect(withPayload.appearanceHash != cleared.appearanceHash)
    }

    // MARK: VStackNode hash rules

    @Test("VStackNode: alignment change perturbs layoutHash")
    func vstackAlignmentPerturbsLayout() {
        let a = VStackNode(alignment: .leading) { TextNode("x") }
        let b = VStackNode(alignment: .trailing) { TextNode("x") }
        #expect(a.layoutHash != b.layoutHash)
    }

    @Test("VStackNode: spacing change perturbs layoutHash")
    func vstackSpacingPerturbsLayout() {
        let a = VStackNode(spacing: 0) { TextNode("x") }
        let b = VStackNode(spacing: 8) { TextNode("x") }
        #expect(a.layoutHash != b.layoutHash)
    }

    @Test("VStackNode: child layoutHash change propagates to parent layoutHash")
    func vstackChildLayoutPropagates() {
        let a = VStackNode { TextNode("hello") }
        let b = VStackNode { TextNode("world") }
        #expect(a.layoutHash != b.layoutHash)
    }

    @Test("VStackNode: child appearanceHash change propagates to parent appearanceHash")
    func vstackChildAppearancePropagates() {
        let red = VColorDescriptor(red: 1, green: 0, blue: 0, alpha: 1)
        let blue = VColorDescriptor(red: 0, green: 0, blue: 1, alpha: 1)
        let a = VStackNode { TextNode("x", color: red) }
        let b = VStackNode { TextNode("x", color: blue) }
        #expect(a.layoutHash == b.layoutHash)
        #expect(a.appearanceHash != b.appearanceHash)
    }

    // MARK: HStackNode hash rules

    @Test("HStackNode: alignment change perturbs layoutHash")
    func hstackAlignmentPerturbsLayout() {
        let a = HStackNode(alignment: .top) { TextNode("x") }
        let b = HStackNode(alignment: .bottom) { TextNode("x") }
        #expect(a.layoutHash != b.layoutHash)
    }

    @Test("HStackNode: spacing change perturbs layoutHash")
    func hstackSpacingPerturbsLayout() {
        let a = HStackNode(spacing: 0) { TextNode("x") }
        let b = HStackNode(spacing: 8) { TextNode("x") }
        #expect(a.layoutHash != b.layoutHash)
    }

    @Test("HStackNode: child appearanceHash change propagates to parent appearanceHash")
    func hstackChildAppearancePropagates() {
        let red = VColorDescriptor(red: 1, green: 0, blue: 0, alpha: 1)
        let blue = VColorDescriptor(red: 0, green: 0, blue: 1, alpha: 1)
        let a = HStackNode { TextNode("x", color: red) }
        let b = HStackNode { TextNode("x", color: blue) }
        #expect(a.layoutHash == b.layoutHash)
        #expect(a.appearanceHash != b.appearanceHash)
    }

    // MARK: ZStackNode hash rules

    @Test("ZStackNode: alignment change perturbs layoutHash")
    func zstackAlignmentPerturbsLayout() {
        let a = ZStackNode(alignment: .topLeading) { TextNode("x") }
        let b = ZStackNode(alignment: .bottomTrailing) { TextNode("x") }
        #expect(a.layoutHash != b.layoutHash)
    }

    @Test("ZStackNode: child appearanceHash change propagates to parent appearanceHash")
    func zstackChildAppearancePropagates() {
        let red = VColorDescriptor(red: 1, green: 0, blue: 0, alpha: 1)
        let blue = VColorDescriptor(red: 0, green: 0, blue: 1, alpha: 1)
        let a = ZStackNode { TextNode("x", color: red) }
        let b = ZStackNode { TextNode("x", color: blue) }
        #expect(a.layoutHash == b.layoutHash)
        #expect(a.appearanceHash != b.appearanceHash)
    }

    // MARK: SpacerNode

    @Test("SpacerNode: minLength change perturbs layoutHash")
    func spacerMinLengthPerturbsLayout() {
        let a = SpacerNode(minLength: 8)
        let b = SpacerNode(minLength: 16)
        #expect(a.layoutHash != b.layoutHash)
    }

    @Test("SpacerNode: appearanceHash is always 0")
    func spacerAppearanceHashIsZero() {
        let a = SpacerNode()
        let b = SpacerNode(minLength: 99)
        #expect(a.appearanceHash == 0)
        #expect(b.appearanceHash == 0)
    }
}

// MARK: - RenderView conformance test

private struct SampleCell: RenderView {
    let url: URL
    let caption: String

    @MainActor var renderBody: VStackNode {
        VStackNode(spacing: 8) {
            AsyncImageNode(url: url, aspectRatio: 16.0 / 9.0).cornerRadius(12)
            TextNode(caption)
        }
    }
}

@Suite("RenderView")
struct RenderViewTests {
    @Test("SampleCell renderBody compiles and has expected structure")
    @MainActor func sampleCellStructure() {
        let url = URL(string: "https://example.com/img.jpg")!
        let cell = SampleCell(url: url, caption: "Hello")
        let body = cell.renderBody
        #expect(body.children.count == 2)
        let image = body.children[0] as? AsyncImageNode
        #expect(image?.cornerRadius == 12)
        #expect(image?.aspectRatio == CGFloat(16.0 / 9.0))
        let text = body.children[1] as? TextNode
        #expect(text?.content == "Hello")
    }

    @Test("cornerRadius change affects only appearanceHash of parent cell")
    @MainActor func cornerRadiusAppearsOnlyInAppearanceHash() {
        let url = URL(string: "https://example.com/img.jpg")!
        let stackA = VStackNode(spacing: 8) {
            AsyncImageNode(url: url, aspectRatio: 16.0 / 9.0).cornerRadius(0)
            TextNode("Hello")
        }
        let stackB = VStackNode(spacing: 8) {
            AsyncImageNode(url: url, aspectRatio: 16.0 / 9.0).cornerRadius(12)
            TextNode("Hello")
        }
        #expect(stackA.layoutHash == stackB.layoutHash)
        #expect(stackA.appearanceHash != stackB.appearanceHash)
    }
}
