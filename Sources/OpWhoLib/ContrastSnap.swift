import Foundation

/// Nearest color to `color` (same hue; saturation reduced only if that hue
/// can't reach the ratio at any brightness) meeting `ratio` against
/// `background`. Used by the Appearance tab's contrast badges — guide, don't
/// block: the caller decides whether to apply the result.
///
/// Relies on WCAG relative luminance being strictly monotonic in HSB
/// brightness at fixed hue/saturation, so each pass/fail boundary is a single
/// brightness value found by bisection.
public func snapToContrast(
    _ color: (r: Double, g: Double, b: Double),
    against background: (r: Double, g: Double, b: Double),
    ratio: Double = 4.5
) -> (r: Double, g: Double, b: Double) {
    if contrastRatio(color, background) >= ratio { return color }

    let (h, s, v) = rgbToHSB(color)
    // Aim slightly past the requested ratio so 8-bit quantization of the
    // result can't round it back below threshold.
    let target = ratio + 0.06

    var sat = s
    while true {
        if let snapped = snapBrightness(h: h, s: sat, v: v, background: background,
                                        target: target, minimum: ratio) {
            return snapped
        }
        if sat <= 0 { break }
        sat = max(0, sat - 0.05)
    }
    // Unreachable for real backgrounds (grayscale always spans the required
    // luminance), but keep a safe fallback.
    let black = (r: 0.0, g: 0.0, b: 0.0)
    let white = (r: 1.0, g: 1.0, b: 1.0)
    return contrastRatio(black, background) >= contrastRatio(white, background) ? black : white
}

/// At fixed hue/saturation, find the brightness nearest `v` whose color meets
/// `target` against `background`; nil if no brightness at this saturation can.
private func snapBrightness(
    h: Double, s: Double, v: Double,
    background: (r: Double, g: Double, b: Double),
    target: Double, minimum: Double
) -> (r: Double, g: Double, b: Double)? {
    func ratioAt(_ vv: Double) -> Double {
        contrastRatio(hsbToRGB(h: h, s: s, v: vv), background)
    }

    var best: (r: Double, g: Double, b: Double)?
    var bestDist = Double.infinity

    func consider(_ vv: Double) {
        let c = quantize(hsbToRGB(h: h, s: s, v: vv))
        guard contrastRatio(c, background) >= minimum, abs(vv - v) < bestDist else { return }
        best = c
        bestDist = abs(vv - v)
    }

    // Darker-than-background branch: contrast decreases as brightness rises.
    // Feasible iff v=0 (black-ward extreme) passes; bisect to the largest
    // passing brightness (the one nearest the input from below).
    if ratioAt(0) >= target {
        var lo = 0.0, hi = 1.0          // invariant: ratioAt(lo) >= target
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if ratioAt(mid) >= target { lo = mid } else { hi = mid }
        }
        consider(lo)
    }
    // Lighter-than-background branch: contrast increases as brightness rises.
    // Feasible iff v=1 passes; bisect to the smallest passing brightness.
    if ratioAt(1) >= target {
        var lo = 0.0, hi = 1.0          // invariant: ratioAt(hi) >= target
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if ratioAt(mid) >= target { hi = mid } else { lo = mid }
        }
        consider(hi)
    }
    return best
}

/// Round each channel to the nearest 8-bit value, matching what persisting
/// as #RRGGBB will store.
private func quantize(_ c: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
    ((c.r * 255).rounded() / 255, (c.g * 255).rounded() / 255, (c.b * 255).rounded() / 255)
}

func rgbToHSB(_ c: (r: Double, g: Double, b: Double)) -> (h: Double, s: Double, v: Double) {
    let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
    let d = mx - mn
    var h = 0.0
    if d > 0 {
        switch mx {
        case c.r: h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6)
        case c.g: h = (c.b - c.r) / d + 2
        default:  h = (c.r - c.g) / d + 4
        }
        h *= 60
        if h < 0 { h += 360 }
    }
    return (h, mx == 0 ? 0 : d / mx, mx)
}

func hsbToRGB(h: Double, s: Double, v: Double) -> (r: Double, g: Double, b: Double) {
    let c = v * s
    let hp = h / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    let (r1, g1, b1): (Double, Double, Double)
    switch hp {
    case ..<1: (r1, g1, b1) = (c, x, 0)
    case ..<2: (r1, g1, b1) = (x, c, 0)
    case ..<3: (r1, g1, b1) = (0, c, x)
    case ..<4: (r1, g1, b1) = (0, x, c)
    case ..<5: (r1, g1, b1) = (x, 0, c)
    default:   (r1, g1, b1) = (c, 0, x)
    }
    let m = v - c
    return (r1 + m, g1 + m, b1 + m)
}
