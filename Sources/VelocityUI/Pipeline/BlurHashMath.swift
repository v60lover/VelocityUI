// BlurHashMath.swift

import Foundation

// MARK: - BlurHash algorithm shared primitives (public-domain — https://blurha.sh)
//
// No CoreGraphics/UIKit dependency, so PlaceholderDecode.swift (on-device) and
// PlaceholderEncode.swift (also builds as macOS tooling) can share this code.

let blurHashAlphabet: [Character] = Array(
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"
)

let blurHashDigits: [Character: Int] = {
    var d = [Character: Int]()
    for (i, c) in blurHashAlphabet.enumerated() { d[c] = i }
    return d
}()

nonisolated func base83Decode(_ chars: ArraySlice<Character>) -> Int? {
    var value = 0
    for c in chars {
        guard let digit = blurHashDigits[c] else { return nil }
        value = value * 83 + digit
    }
    return value
}

nonisolated func base83Encode(_ value: Int, length: Int) -> String {
    var chars = [Character](repeating: "0", count: length)
    var v = value
    for i in stride(from: length - 1, through: 0, by: -1) {
        chars[i] = blurHashAlphabet[v % 83]
        v /= 83
    }
    return String(chars)
}

nonisolated func sRGBToLinear(_ value: Int) -> Float {
    let v = Float(value) / 255
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

nonisolated func linearToSRGB(_ value: Float) -> UInt8 {
    let v = max(0, min(1, value))
    let s: Float = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    return UInt8(max(0, min(255, (s * 255).rounded())))
}

nonisolated func signPow(_ value: Float, _ exp: Float) -> Float {
    let sign: Float = value < 0 ? -1 : 1
    return sign * pow(abs(value), exp)
}

nonisolated func decodeDC(_ value: Int) -> (Float, Float, Float) {
    let r = (value >> 16) & 255
    let g = (value >> 8) & 255
    let b = value & 255
    return (sRGBToLinear(r), sRGBToLinear(g), sRGBToLinear(b))
}

nonisolated func decodeAC(_ value: Int, maxValue: Float) -> (Float, Float, Float) {
    let quantR = value / (19 * 19)
    let quantG = (value / 19) % 19
    let quantB = value % 19
    return (
        signPow((Float(quantR) - 9) / 9, 2.0) * maxValue,
        signPow((Float(quantG) - 9) / 9, 2.0) * maxValue,
        signPow((Float(quantB) - 9) / 9, 2.0) * maxValue
    )
}

/// Inverse of `decodeDC` — packs a linear-space average color into BlurHash's 24-bit sRGB DC term.
nonisolated func encodeDC(_ color: (Float, Float, Float)) -> Int {
    let r = Int(linearToSRGB(color.0))
    let g = Int(linearToSRGB(color.1))
    let b = Int(linearToSRGB(color.2))
    return (r << 16) + (g << 8) + b
}

/// Inverse of `decodeAC` — quantises a linear-space AC coefficient (already normalised by
/// `maximumValue`) into BlurHash's base-19-per-channel term.
nonisolated func encodeAC(_ color: (Float, Float, Float), maximumValue: Float) -> Int {
    func quantise(_ v: Float) -> Int {
        let signed = signPow(v / maximumValue, 0.5)
        return max(0, min(18, Int(((signed * 9) + 9.5).rounded(.down))))
    }
    return quantise(color.0) * 19 * 19 + quantise(color.1) * 19 + quantise(color.2)
}
