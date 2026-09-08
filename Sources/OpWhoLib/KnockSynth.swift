import Foundation

/// Synthesises the built-in "knock-knock" alert as an in-memory WAV.
///
/// Generated rather than shipped as an audio file: no SPM resource bundle for
/// `scripts/bundle.sh` to copy, identical behaviour under `swift run` and in
/// tests, and the sample is unambiguously ours to ship under MIT.
///
/// A knuckle rap is a broadband click, not a ringing tone: a burst of noise
/// through a resonant bandpass, damped almost immediately, plus a quiet
/// low-frequency thump for body. Long decays or strong sine modes turn it into
/// a bird call. Two hits `gap` apart, the second softer, read as "knock-knock".
public enum KnockSynth {
    public static let sampleRate = 44100.0

    /// Bandpass centre and Q — the timbre of the wood being struck.
    private static let bandpassHz = 2200.0
    private static let bandpassQ = 1.0
    /// Exponential decay rates (per second) for the click and the body thump.
    private static let clickDecay = 200.0
    private static let bodyHz = 300.0
    private static let bodyDecay = 240.0
    private static let bodyGain = 0.15
    /// Attack rate. Fast enough to stay a click, slow enough to avoid a DC pop.
    private static let attackRate = 4000.0

    private static let hitDuration = 0.055
    private static let gap = 0.095
    private static let secondHitGain = 0.8
    /// Ceiling below full scale — this is meant to be a slight sound.
    private static let peak = 0.85

    /// Mono samples for the full two-hit knock, peak-normalised to `peak`.
    public static func samples() -> [Double] {
        let first = hit(seed: 1, gain: 1)
        let second = hit(seed: 2, gain: secondHitGain)
        let offset = Int(sampleRate * gap)
        var out = [Double](repeating: 0, count: offset + second.count)
        for (i, s) in first.enumerated() { out[i] += s }
        for (i, s) in second.enumerated() { out[offset + i] += s }
        let maxAbs = out.reduce(0) { max($0, abs($1)) }
        guard maxAbs > 0 else { return out }
        return out.map { $0 / maxAbs * peak }
    }

    /// 16-bit mono WAV of `samples()`, ready for `AVAudioPlayer(data:)`.
    public static func wavData() -> Data {
        wav(samples: samples())
    }

    private static func hit(seed: UInt64, gain: Double) -> [Double] {
        let count = Int(sampleRate * hitDuration)
        var rng = SplitMix64(seed: seed)
        var click = bandpass(
            (0..<count).map { _ in rng.nextUnit() },
            centre: bandpassHz,
            q: bandpassQ
        )
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let attack = 1 - exp(-t * attackRate)
            let body = sin(2 * .pi * bodyHz * t) * exp(-t * bodyDecay) * bodyGain
            click[i] = (click[i] * exp(-t * clickDecay) + body) * attack * gain
        }
        return click
    }

    /// RBJ constant-peak-gain bandpass, direct form 1.
    private static func bandpass(_ input: [Double], centre: Double, q: Double) -> [Double] {
        let w0 = 2 * .pi * centre / sampleRate
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let b0 = alpha / a0, b2 = -alpha / a0
        let a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0

        var out = [Double](repeating: 0, count: input.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for (i, x) in input.enumerated() {
            let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            out[i] = y
        }
        return out
    }

    private static func wav(samples: [Double]) -> Data {
        let dataBytes = samples.count * 2
        var data = Data(capacity: 44 + dataBytes)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                       // PCM header size
        append(UInt16(1))                        // format: PCM
        append(UInt16(1))                        // channels: mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)           // byte rate
        append(UInt16(2))                        // block align
        append(UInt16(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * 32767))
        }
        return data
    }
}

/// Deterministic PRNG so every build renders a byte-identical knock.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in −1…1.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53) * 2 - 1
    }
}
