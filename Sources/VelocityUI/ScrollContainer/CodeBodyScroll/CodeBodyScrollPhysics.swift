// CodeBodyScrollPhysics.swift

import CoreGraphics

/// Pure scalar physics for one code body's horizontal scroll: edge resistance, momentum decay,
/// and spring-back. Every function is `static`, takes its inputs, and returns a new value — no
/// CALayer, no MainActor isolation, no stored/mutable state, no allocation.
///
/// Deceleration and spring both use closed-form solutions (no fixed-step substeps), so a call
/// with any `dt` — 1/60s, 1/120s, or a stalled 1/10s — lands on the exact continuous-time result.
/// That is what makes 60Hz and 120Hz displays converge to the same offset/velocity after the same
/// elapsed wall-clock time.
struct CodeBodyScrollPhysics: Sendable {

    struct Parameters: Sendable {
        /// Time (s) for deceleration velocity to halve. Larger = floatier momentum.
        var decelerationHalfLife: CGFloat = 0.14
        /// Below this release speed (pt/s) momentum never launches — the gesture just settles.
        var minimumLaunchVelocity: CGFloat = 20
        /// Below this speed (pt/s) decay/spring motion is considered stopped.
        var minimumSettleVelocity: CGFloat = 4
        /// Maximum visible overdrag past a content edge, in points.
        var maxOverdrag: CGFloat = 44
        /// Spring response time (s) for the critically-damped edge spring-back.
        var springResponse: CGFloat = 0.35
        /// Spring settled once |offset - target| is under this, in points.
        var settleDistanceEpsilon: CGFloat = 0.25
        /// Largest dt (s) a single tick may consume — caps the jump after a main-thread stall.
        /// Kept above 1/10s so the "exact for a stalled 1/10s" claim above actually holds; only
        /// stalls longer than that (e.g. a resumed-from-background frame) get truncated.
        var maxStepDuration: CGFloat = 0.15

        static let `default` = Parameters()
    }

    /// Legal offset range for content of `contentWidth` in a viewport of `viewportWidth`.
    /// `[0, 0]` when content already fits — nothing to scroll.
    static func legalRange(contentWidth: CGFloat, viewportWidth: CGFloat) -> ClosedRange<CGFloat> {
        0...max(0, contentWidth - viewportWidth)
    }

    /// Nonlinear resistance for a raw (unclamped) offset outside `range`. Monotonic in the excess
    /// past the bound, asymptoting to `bound + maxOverdrag` as the excess grows without bound —
    /// gives the "harder to pull the further you go" rubber-band feel without matching any
    /// undocumented UIKit constant. Offsets inside `range` pass through unchanged.
    static func resistedOffset(rawOffset: CGFloat, range: ClosedRange<CGFloat>, maxOverdrag: CGFloat) -> CGFloat {
        if rawOffset < range.lowerBound {
            return range.lowerBound - resistedExcess(range.lowerBound - rawOffset, limit: maxOverdrag)
        }
        if rawOffset > range.upperBound {
            return range.upperBound + resistedExcess(rawOffset - range.upperBound, limit: maxOverdrag)
        }
        return rawOffset
    }

    /// Inverse of `resistedExcess` — recovers the raw (unclamped) excess a presented, resisted
    /// excess came from. Lets a new touch beginning mid-overdrag resume tracking the finger from
    /// the correct raw offset instead of snapping to the visibly-compressed one.
    static func rawExcess(fromPresentedExcess presented: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0, presented < limit else { return presented }
        return limit * presented / (limit - presented)
    }

    /// f(x) = limit * (1 - 1/(x/limit + 1)): f(0) = 0, monotonic increasing, f(x) -> limit as x -> inf.
    private static func resistedExcess(_ excess: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0, excess > 0 else { return 0 }
        return limit * (1 - 1 / (excess / limit + 1))
    }

    /// Scales a raw velocity to match the position compression `resistedOffset` already applied
    /// at `rawOffset`. `resistedOffset` maps a potentially huge raw excess into the small
    /// `[0, maxOverdrag]` on-screen band; a velocity computed in raw-offset units is now too large
    /// for that compressed band — feeding it unscaled into a spring starting from the compressed
    /// position lets the spring overshoot past `maxOverdrag` before it turns back. This returns
    /// `rawVelocity * f'(excess)`, the analytic derivative of `resistedExcess`, so offset and
    /// velocity enter the spring in the same (compressed) coordinate space.
    static func resistedVelocity(rawVelocity: CGFloat, rawOffset: CGFloat, range: ClosedRange<CGFloat>, maxOverdrag: CGFloat) -> CGFloat {
        let excess: CGFloat
        if rawOffset < range.lowerBound {
            excess = range.lowerBound - rawOffset
        } else if rawOffset > range.upperBound {
            excess = rawOffset - range.upperBound
        } else {
            return rawVelocity
        }
        guard maxOverdrag > 0, excess > 0 else { return rawVelocity }
        let denom = excess / maxOverdrag + 1
        return rawVelocity / (denom * denom)
    }

    /// One frame of exponential momentum decay. `v(t) = v0 * 2^(-t/halfLife)`; the returned
    /// offset is the closed-form integral of that velocity over `dt`, so results are exact for
    /// any `dt` rather than an Euler approximation.
    static func decelerationStep(
        offset: CGFloat, velocity: CGFloat, dt: CGFloat, parameters: Parameters
    ) -> (offset: CGFloat, velocity: CGFloat) {
        let clampedDt = min(max(dt, 0), parameters.maxStepDuration)
        guard clampedDt > 0, parameters.decelerationHalfLife > 0 else { return (offset, velocity) }
        let factor = pow(CGFloat(0.5), clampedDt / parameters.decelerationHalfLife)
        let newVelocity = velocity * factor
        // tau = halfLife / ln(2); integral of v0 * e^(-t/tau) from 0 to dt = v0 * tau * (1 - e^(-dt/tau)).
        let tau = parameters.decelerationHalfLife / CGFloat(log(2.0))
        let displacement = velocity * tau * (1 - factor)
        return (offset + displacement, newVelocity)
    }

    /// One frame of a critically-damped spring toward `target`, closed-form (no oscillation,
    /// no substeps): `x(t) = (x0 + (v0 + omega*x0)*t) * e^(-omega*t)`, `omega = 2*pi/response`.
    static func springStep(
        offset: CGFloat, velocity: CGFloat, target: CGFloat, dt: CGFloat, parameters: Parameters
    ) -> (offset: CGFloat, velocity: CGFloat) {
        let clampedDt = min(max(dt, 0), parameters.maxStepDuration)
        guard clampedDt > 0, parameters.springResponse > 0 else { return (offset, velocity) }
        let omega = CGFloat(2 * Double.pi) / parameters.springResponse
        let x0 = offset - target
        let expTerm = exp(-omega * clampedDt)
        let newX = (x0 + (velocity + omega * x0) * clampedDt) * expTerm
        let newVelocity = (velocity - omega * (velocity + omega * x0) * clampedDt) * expTerm
        return (target + newX, newVelocity)
    }

    static func isDecelerationSettled(velocity: CGFloat, parameters: Parameters) -> Bool {
        abs(velocity) < parameters.minimumSettleVelocity
    }

    static func isSpringSettled(distance: CGFloat, velocity: CGFloat, parameters: Parameters) -> Bool {
        abs(distance) < parameters.settleDistanceEpsilon && abs(velocity) < parameters.minimumSettleVelocity
    }
}
