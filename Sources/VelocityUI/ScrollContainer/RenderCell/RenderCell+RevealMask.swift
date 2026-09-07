// RenderCell+RevealMask.swift

#if canImport(UIKit)
import UIKit

extension RenderCell {
    /// Duration of the downward reveal ramp, tuned for ~20 tok/s streaming (VelocityUI-gpex).
    private static let revealRampDuration: CFTimeInterval = 0.15
    /// Height of the soft fade band, as a fraction of the block's current total height. Clamped
    /// to a minimum in points so a very short first append still gets a visible ramp.
    private static let revealRampBandFraction: CGFloat = 0.06
    private static let revealRampMinBandPoints: CGFloat = 4

    /// Applies a downward-rising opacity ramp over each fragment's newly-appended tail, keyed by
    /// fragment id. `region.from`/`region.to` are local Y offsets within that fragment's own
    /// sublayer (0 == the block's top), computed by `FeedScrollView.revealRegions(previous:new:)`
    /// from the previous vs. new fragment height -- text above `from` is already on screen and
    /// must stay at opacity 1 (a fresh `CAGradientLayer` per call would restart it from 0).
    ///
    /// Must only be called off the active-gesture path (see `growHotBlock`'s doc comment) --
    /// running this while a scroll gesture is in progress would put per-token CoreAnimation work
    /// back on the path VelocityUI-zgdg's gesture-gated deferral exists to clear.
    func applyRevealRegions(_ regions: [Int: (from: CGFloat, to: CGFloat)]) {
        guard !regions.isEmpty else { return }
        let instant = UIAccessibility.isReduceMotionEnabled
        for (fragmentID, region) in regions {
            guard let identity = layerIdentityByFragmentID[fragmentID],
                  let sub = sublayers[identity],
                  region.to > 0, region.from < region.to
            else { continue }

            let generation = (revealGeneration[identity] ?? 0) + 1
            revealGeneration[identity] = generation

            if instant {
                revealMaskLayers.removeValue(forKey: identity)?.removeFromSuperlayer()
                sub.mask = nil
                continue
            }

            let mask = revealMaskLayers[identity] ?? {
                let gradient = CAGradientLayer()
                gradient.startPoint = CGPoint(x: 0, y: 0)
                gradient.endPoint = CGPoint(x: 0, y: 1)
                gradient.colors = [
                    UIColor.white.cgColor, UIColor.white.cgColor,
                    UIColor.clear.cgColor, UIColor.clear.cgColor,
                ]
                sub.mask = gradient
                revealMaskLayers[identity] = gradient
                return gradient
            }()

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.frame = CGRect(x: 0, y: 0, width: sub.bounds.width, height: region.to)
            CATransaction.commit()

            let bandFraction = max(Self.revealRampMinBandPoints, region.to * Self.revealRampBandFraction) / region.to
            let startOpaqueEdge = min(1, max(0, region.from / region.to))
            let startClearEdge = min(1, startOpaqueEdge + bandFraction)
            let fromLocations: [NSNumber] = [0, NSNumber(value: Double(startOpaqueEdge)), NSNumber(value: Double(startClearEdge)), 1]
            let toLocations: [NSNumber] = [0, 1, 1, 1]

            mask.locations = toLocations
            let anim = CABasicAnimation(keyPath: "locations")
            anim.fromValue = fromLocations
            anim.toValue = toLocations
            anim.duration = Self.revealRampDuration
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)

            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.revealGeneration[identity] == generation else { return }
                if self.sublayers[identity]?.mask === mask {
                    self.sublayers[identity]?.mask = nil
                }
                self.revealMaskLayers.removeValue(forKey: identity)
            }
            mask.add(anim, forKey: "revealRamp")
            CATransaction.commit()
        }
    }
}
#endif
