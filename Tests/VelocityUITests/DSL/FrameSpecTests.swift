// FrameSpecTests.swift

import Testing
import Foundation
@testable import VelocityUI

// MARK: - FrameSpec unit tests (VelocityUI-x8a)

@Suite("FrameSpec")
struct FrameSpecTests {

    // MARK: isSpecified

    @Test("unspecified is not specified")
    func unspecifiedIsNotSpecified() {
        #expect(FrameSpec.unspecified.isSpecified == false)
    }

    @Test("width-only spec is specified")
    func widthOnlyIsSpecified() {
        #expect(FrameSpec(width: 100).isSpecified)
    }

    @Test("height-only spec is specified")
    func heightOnlyIsSpecified() {
        #expect(FrameSpec(height: 100).isSpecified)
    }

    @Test("alignment-only spec (no width/height) is NOT specified")
    func alignmentOnlyIsNotSpecified() {
        // Alignment alone establishes no slot to align within — isSpecified tracks
        // whether measurement actually changes, not whether any field differs from default.
        #expect(FrameSpec(alignment: .topLeading).isSpecified == false)
    }

    // MARK: merge — per-dimension precedence

    @Test("merge: inner width wins when both specify width")
    func mergeInnerWidthWins() {
        let inner = FrameSpec(width: 100)
        let outer = FrameSpec(width: 200)
        let merged = FrameSpec.merge(inner: inner, outer: outer)
        #expect(merged.width == 100)
    }

    @Test("merge: inner height wins when both specify height")
    func mergeInnerHeightWins() {
        let inner = FrameSpec(height: 50)
        let outer = FrameSpec(height: 300)
        let merged = FrameSpec.merge(inner: inner, outer: outer)
        #expect(merged.height == 50)
    }

    @Test("merge: unspecified inner dimension falls through to outer")
    func mergeUnspecifiedInnerFallsThroughToOuter() {
        let inner = FrameSpec(width: 100)          // height unspecified
        let outer = FrameSpec(width: 999, height: 50)
        let merged = FrameSpec.merge(inner: inner, outer: outer)
        #expect(merged.width == 100)   // inner wins
        #expect(merged.height == 50)   // falls through to outer
    }

    @Test("merge: both unspecified on a dimension stays nil")
    func mergeBothUnspecifiedStaysNil() {
        let merged = FrameSpec.merge(inner: .unspecified, outer: .unspecified)
        #expect(merged.width == nil)
        #expect(merged.height == nil)
    }

    // MARK: merge — alignment precedence

    @Test("merge: inner alignment wins when inner isSpecified")
    func mergeInnerAlignmentWinsWhenInnerSpecified() {
        let inner = FrameSpec(width: 100, alignment: .topLeading)
        let outer = FrameSpec(height: 50, alignment: .bottomTrailing)
        let merged = FrameSpec.merge(inner: inner, outer: outer)
        #expect(merged.alignment == .topLeading)
    }

    @Test("merge: outer alignment applies when inner is not specified")
    func mergeOuterAlignmentAppliesWhenInnerUnspecified() {
        // inner has no width/height (isSpecified == false) — its alignment is inert.
        let inner = FrameSpec(alignment: .topLeading)
        let outer = FrameSpec(width: 200, alignment: .bottomTrailing)
        let merged = FrameSpec.merge(inner: inner, outer: outer)
        #expect(merged.alignment == .bottomTrailing)
    }

    // MARK: layoutHash / appearanceHash folding

    @Test("FrameModifierNode.layoutHash folds spec and content.layoutHash")
    func layoutHashFoldsSpecAndContent() {
        let base = TextNode("hello")
        let framed100 = base.frame(width: 100)
        let framed200 = base.frame(width: 200)
        #expect(framed100.layoutHash != framed200.layoutHash)
        #expect(framed100.layoutHash != base.layoutHash)
    }

    @Test("FrameModifierNode.appearanceHash equals content.appearanceHash")
    func appearanceHashPassesThroughUnchanged() {
        let base = TextNode("hello")
        let framed = base.frame(width: 100)
        #expect(framed.appearanceHash == base.appearanceHash)
    }

    @Test("Two identical .frame() calls produce equal layoutHash")
    func layoutHashDeterministicForEqualSpecs() {
        let a = TextNode("x").frame(width: 100, height: 50, alignment: .top)
        let b = TextNode("x").frame(width: 100, height: 50, alignment: .top)
        #expect(a.layoutHash == b.layoutHash)
    }

    // MARK: .frame() availability across node kinds

    @Test(".frame() is callable on TextNode")
    func frameCallableOnText() {
        let framed = TextNode("x").frame(width: 100)
        #expect(framed.spec.width == 100)
    }

    @Test(".frame() is callable on AsyncImageNode")
    func frameCallableOnImage() {
        let framed = AsyncImageNode(url: nil, aspectRatio: 1.0).frame(height: 200)
        #expect(framed.spec.height == 200)
    }

    @MainActor
    @Test(".frame() is callable on VStackNode")
    func frameCallableOnVStack() {
        let framed = VStackNode { TextNode("x") }.frame(width: 300, height: 400)
        #expect(framed.spec.width == 300)
        #expect(framed.spec.height == 400)
    }
}
