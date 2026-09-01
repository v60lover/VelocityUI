// CodeBodyScrollAnimator.swift

#if canImport(UIKit)
import UIKit

/// Drives momentum and edge spring-back for one code body's horizontal scroll. Owned as a plain
/// stored property by each `FeedScrollView` — per-feed state, never static or shared, matching
/// `CellPool`/`MediaDispatcher`'s lifetime category rather than going through `RenderEnvironment`
/// (it holds no cross-feed collaborator, only this feed's current gesture/animation target).
///
/// Owns at most one active target: one finger gesture can only ever drag one code body. The
/// target is a weak `RenderCell` plus its `LayerIdentity` and item ID; every tick re-validates
/// all three through `RenderCell.scrollBoundaryInfo`/`setCodeBodyOffset` before writing, so a
/// recycle or item change racing a running animation is a no-op, not a stale write.
@MainActor
final class CodeBodyScrollAnimator {

    private struct Target {
        weak var cell: RenderCell?
        let identity: RenderCell.LayerIdentity
        let itemID: AnyHashable
    }

    /// Which side of the legal range a spring is homing toward. Stored instead of a fixed
    /// `CGFloat` target so the destination tracks a *moving* bound — a code body's content width
    /// (and so `range.upperBound`) keeps growing while text is still streaming in, and a spring
    /// that had already launched toward the right edge needs to keep chasing that edge outward,
    /// not homing in on wherever it happened to be the tick the spring started. `range.lowerBound`
    /// is always `0` and never moves, which is why this asymmetry only ever shows up on the right.
    private enum Edge { case lower, upper }

    private enum State {
        case idle
        case dragging(rawOffset: CGFloat)
        case decelerating(offset: CGFloat, velocity: CGFloat)
        case springing(offset: CGFloat, velocity: CGFloat, edge: Edge)
    }

    private let parameters: CodeBodyScrollPhysics.Parameters
    private var target: Target?
    private var state: State = .idle
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    init(parameters: CodeBodyScrollPhysics.Parameters = .default) {
        self.parameters = parameters
    }

    /// `true` while `cell` is this animator's current target — the recycle path checks this
    /// before returning a cell to the pool, so an in-flight animation on a leaving cell is
    /// stopped instead of ticking a decommissioned target until its next validation failure.
    func isTarget(_ cell: RenderCell) -> Bool {
        target?.cell === cell
    }

    // MARK: - Gesture entry points

    /// Touch-down over a scrollable code body. Stops any running animation (on this or a
    /// previous target — "immediate interruption by a new touch") and seeds the drag's raw
    /// offset from the body's current presented offset, inverting edge resistance if the body
    /// was mid-overdrag so the drag resumes tracking the finger exactly, not the compressed view.
    func beginDrag(cell: RenderCell, identity: RenderCell.LayerIdentity, itemID: AnyHashable) {
        invalidateDisplayLink()
        // A new touch interrupting a previous target's still-running animation: clear its
        // "animating" flag now, since `settle()` won't run before `target` is overwritten below.
        if let previous = target {
            previous.cell?.setCodeBodyAnimating(false, identity: previous.identity)
        }
        guard let info = cell.scrollBoundaryInfo(for: identity) else {
            target = nil
            state = .idle
            return
        }
        target = Target(cell: cell, identity: identity, itemID: itemID)
        cell.setCodeBodyAnimating(true, identity: identity)
        let range = CodeBodyScrollPhysics.legalRange(contentWidth: info.contentWidth, viewportWidth: info.viewportWidth)
        state = .dragging(rawOffset: rawOffset(fromPresented: info.offset, range: range))
    }

    /// One finger-move increment. `dx` is the pan translation delta since the last call (already
    /// zeroed by the caller) — matches the sign convention `offset -= dx`. Outside `range`,
    /// `resistedOffset` compresses the presented write; the raw tracked offset stays uncompressed
    /// so lifting the finger still reports the true overdrag distance/velocity.
    func dragBy(dx: CGFloat) {
        guard case .dragging(let raw) = state, let target, let cell = target.cell,
              let info = cell.scrollBoundaryInfo(for: target.identity)
        else { settle(); return }
        let range = CodeBodyScrollPhysics.legalRange(contentWidth: info.contentWidth, viewportWidth: info.viewportWidth)
        let newRaw = raw - dx
        state = .dragging(rawOffset: newRaw)
        let presented = CodeBodyScrollPhysics.resistedOffset(rawOffset: newRaw, range: range, maxOverdrag: parameters.maxOverdrag)
        guard cell.setCodeBodyOffset(presented, identity: target.identity, itemID: target.itemID) else { settle(); return }
    }

    /// Finger lifted. `gestureVelocity` is `UIPanGestureRecognizer.velocity(in:).x` (points/second,
    /// finger-coordinate sign); flipped here to content-offset sign (`offset -= dx` convention).
    /// Launches momentum when inside the legal range and above the launch threshold; goes
    /// straight to the edge spring when released mid-overdrag; otherwise settles at rest.
    func endDrag(gestureVelocity: CGFloat) {
        guard case .dragging(let raw) = state, let target, let cell = target.cell,
              let info = cell.scrollBoundaryInfo(for: target.identity)
        else { settle(); return }
        let range = CodeBodyScrollPhysics.legalRange(contentWidth: info.contentWidth, viewportWidth: info.viewportWidth)
        let contentVelocity = -gestureVelocity

        if raw < range.lowerBound || raw > range.upperBound {
            let edge: Edge = raw < range.lowerBound ? .lower : .upper
            let presented = CodeBodyScrollPhysics.resistedOffset(rawOffset: raw, range: range, maxOverdrag: parameters.maxOverdrag)
            let presentedVelocity = CodeBodyScrollPhysics.resistedVelocity(rawVelocity: contentVelocity, rawOffset: raw, range: range, maxOverdrag: parameters.maxOverdrag)
            startSpring(offset: presented, velocity: presentedVelocity, edge: edge)
        } else if abs(contentVelocity) >= parameters.minimumLaunchVelocity {
            startDeceleration(offset: raw, velocity: contentVelocity)
        } else {
            settle()
        }
    }

    /// Gesture cancelled (system interruption, not a normal lift). No momentum — settle to the
    /// nearest legal offset, springing back first if the drag had left the legal range.
    func cancelDrag() {
        guard case .dragging(let raw) = state, let target, let cell = target.cell,
              let info = cell.scrollBoundaryInfo(for: target.identity)
        else { settle(); return }
        let range = CodeBodyScrollPhysics.legalRange(contentWidth: info.contentWidth, viewportWidth: info.viewportWidth)
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        if clamped != raw {
            let edge: Edge = raw < range.lowerBound ? .lower : .upper
            let presented = CodeBodyScrollPhysics.resistedOffset(rawOffset: raw, range: range, maxOverdrag: parameters.maxOverdrag)
            startSpring(offset: presented, velocity: 0, edge: edge)
        } else {
            _ = cell.setCodeBodyOffset(clamped, identity: target.identity, itemID: target.itemID)
            settle()
        }
    }

    /// Stops any running animation without touching layer state — call when the target cell is
    /// about to be recycled or torn down. `RenderCell.prepareForReuse` resets the clip layer's
    /// own offset on cross-item recycle; this just stops the animator from ticking a target that
    /// is no longer this feed's concern.
    func cancelInFlightWork() {
        settle()
    }

    // MARK: - Private

    private func rawOffset(fromPresented presented: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        if presented < range.lowerBound {
            return range.lowerBound - CodeBodyScrollPhysics.rawExcess(fromPresentedExcess: range.lowerBound - presented, limit: parameters.maxOverdrag)
        }
        if presented > range.upperBound {
            return range.upperBound + CodeBodyScrollPhysics.rawExcess(fromPresentedExcess: presented - range.upperBound, limit: parameters.maxOverdrag)
        }
        return presented
    }

    private func startDeceleration(offset: CGFloat, velocity: CGFloat) {
        state = .decelerating(offset: offset, velocity: velocity)
        startDisplayLink()
    }

    private func startSpring(offset: CGFloat, velocity: CGFloat, edge: Edge) {
        state = .springing(offset: offset, velocity: velocity, edge: edge)
        startDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        lastTimestamp = nil
        let proxy = CodeBodyScrollDisplayLinkProxy(animator: self)
        let link = CADisplayLink(target: proxy, selector: #selector(CodeBodyScrollDisplayLinkProxy.tick(_:)))
        // Without this, ProMotion devices can run the spring/momentum tick at a lower cadence
        // than the native 120Hz scroll happening alongside it, which reads as the animation
        // lagging the finger even though the physics itself is correct.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func invalidateDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    /// Single choke point for stopping an animation. Clears the "animating" flag on the outgoing
    /// target's cell (if it's still alive) before dropping `target` -- every exit path (drag end,
    /// cancel, deceleration/spring settling, a stale target failing re-validation) funnels through
    /// here, so `RenderCell.reclampCodeBodyOffset` is never left permanently suppressed.
    private func settle() {
        invalidateDisplayLink()
        if let target {
            target.cell?.setCodeBodyAnimating(false, identity: target.identity)
        }
        target = nil
        state = .idle
    }

    /// CADisplayLink tick — physics-only, one `setCodeBodyOffset` write per frame. No Task,
    /// await, allocation, layout, hit-testing, tokenization, or rasterization on this path.
    fileprivate func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard let last = lastTimestamp else { return }
        let dt = CGFloat(link.timestamp - last)
        guard dt > 0, let target, let cell = target.cell,
              let info = cell.scrollBoundaryInfo(for: target.identity)
        else { settle(); return }

        let range = CodeBodyScrollPhysics.legalRange(contentWidth: info.contentWidth, viewportWidth: info.viewportWidth)

        switch state {
        case .idle, .dragging:
            settle()

        case .decelerating(_, let velocity):
            // Read the offset back from the layer rather than trusting the value this enum case
            // stored last tick: `applyLayout`/`applyCodeBodyTile` may have re-clamped
            // `clip.bounds.origin.x` in between ticks (a content/viewport width change mid-
            // momentum) via `reclampCodeBodyOffset`. Stepping from the stale stored value would
            // silently overwrite that clamp on this tick.
            let offset = info.offset
            let stepped = CodeBodyScrollPhysics.decelerationStep(offset: offset, velocity: velocity, dt: dt, parameters: parameters)
            if stepped.offset < range.lowerBound || stepped.offset > range.upperBound {
                let bound = stepped.offset < range.lowerBound ? range.lowerBound : range.upperBound
                let presented = CodeBodyScrollPhysics.resistedOffset(rawOffset: stepped.offset, range: range, maxOverdrag: parameters.maxOverdrag)
                let presentedVelocity = CodeBodyScrollPhysics.resistedVelocity(rawVelocity: stepped.velocity, rawOffset: stepped.offset, range: range, maxOverdrag: parameters.maxOverdrag)
                guard cell.setCodeBodyOffset(presented, identity: target.identity, itemID: target.itemID) else { settle(); return }
                let edge: Edge = bound == range.lowerBound ? .lower : .upper
                state = .springing(offset: presented, velocity: presentedVelocity, edge: edge)
            } else if CodeBodyScrollPhysics.isDecelerationSettled(velocity: stepped.velocity, parameters: parameters) {
                _ = cell.setCodeBodyOffset(stepped.offset, identity: target.identity, itemID: target.itemID)
                settle()
            } else {
                guard cell.setCodeBodyOffset(stepped.offset, identity: target.identity, itemID: target.itemID) else { settle(); return }
                state = .decelerating(offset: stepped.offset, velocity: stepped.velocity)
            }

        case .springing(_, let velocity, let edge):
            // Same ground-truth resync as the decelerating case. The target is re-derived from
            // the current `range` every tick (not carried over as a stored number) so a spring
            // homing on the right edge keeps tracking `range.upperBound` outward while a code
            // block is still streaming in content -- otherwise it homes in on wherever the edge
            // happened to be the tick the spring launched and visibly falls behind on that side.
            let offset = info.offset
            let currentTarget = edge == .lower ? range.lowerBound : range.upperBound
            let stepped = CodeBodyScrollPhysics.springStep(offset: offset, velocity: velocity, target: currentTarget, dt: dt, parameters: parameters)
            if CodeBodyScrollPhysics.isSpringSettled(distance: stepped.offset - currentTarget, velocity: stepped.velocity, parameters: parameters) {
                _ = cell.setCodeBodyOffset(currentTarget, identity: target.identity, itemID: target.itemID)
                settle()
            } else {
                guard cell.setCodeBodyOffset(stepped.offset, identity: target.identity, itemID: target.itemID) else { settle(); return }
                state = .springing(offset: stepped.offset, velocity: stepped.velocity, edge: edge)
            }
        }
    }
}

/// The only strong reference a running `CADisplayLink` holds. `CADisplayLink` retains its
/// target strongly for as long as it's scheduled — targeting `CodeBodyScrollAnimator` directly
/// would keep it (and its owning `FeedScrollView`) alive for the life of any momentum animation.
@MainActor
private final class CodeBodyScrollDisplayLinkProxy: NSObject {
    private weak var animator: CodeBodyScrollAnimator?
    init(animator: CodeBodyScrollAnimator) {
        self.animator = animator
        super.init()
    }
    @objc func tick(_ link: CADisplayLink) { animator?.tick(link) }
}
#endif
