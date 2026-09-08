import Foundation
import Testing
@testable import OpWhoLib

@Suite("PopupSound")
struct PopupSoundTests {
    private let names = ["Glass", "Ping", "Tink"]

    @Test("catalog leads with Off and the built-ins, then one entry per system sound")
    func catalogOrder() {
        let catalog = PopupSound.catalog(systemSoundNames: names)
        #expect(catalog.count == names.count + 3)
        #expect(catalog[0] == .off)
        #expect(catalog[1] == .tripleTone)
        #expect(catalog[2] == .knockKnock)
        #expect(catalog.dropFirst(3).map(\.title) == names)
    }

    @Test("every catalog id round-trips through resolve")
    func idRoundTrip() {
        for sound in PopupSound.catalog(systemSoundNames: names) {
            #expect(PopupSound.resolve(id: sound.id, systemSoundNames: names) == sound)
        }
    }

    @Test("an id for a missing sound falls back to the default, not silence")
    func unknownFallback() {
        #expect(PopupSound.resolve(id: "sound:Chartreuse", systemSoundNames: names) == .tripleTone)
        #expect(PopupSound.resolve(id: "", systemSoundNames: names) == .tripleTone)
    }

    @Test("sources are distinct")
    func sources() {
        #expect(PopupSound.off.source == .silent)
        #expect(PopupSound.tripleTone.source == .bundled("triple-tone"))
        #expect(PopupSound.knockKnock.source == .knockKnock)
        #expect(PopupSound.system("Glass").source == .system("Glass"))
    }

    /// Guards the SPM resource declaration: without `resources:` in
    /// Package.swift this is the only thing that fails, and the app just goes
    /// quiet.
    @Test("every bundled sound resolves to real audio data")
    func bundledResourcesExist() {
        for sound in PopupSound.catalog(systemSoundNames: []) {
            guard case .bundled(let name) = sound.source else { continue }
            let data = PopupSound.bundledData(name)
            #expect(data != nil, "missing resource \(name).wav")
            #expect(data?.starts(with: Array("RIFF".utf8)) == true)
        }
    }

    @Test("a rule override wins; nil falls through to the global setting")
    func precedence() {
        #expect(PopupSound.effectiveID(
            ruleSoundID: PopupSound.off.id, globalSoundID: PopupSound.tripleTone.id
        ) == PopupSound.off.id)
        #expect(PopupSound.effectiveID(
            ruleSoundID: nil, globalSoundID: PopupSound.tripleTone.id
        ) == PopupSound.tripleTone.id)
        // A silenced global is not resurrected by a rule that sets nothing.
        #expect(PopupSound.effectiveID(
            ruleSoundID: nil, globalSoundID: PopupSound.off.id
        ) == PopupSound.off.id)
    }

    @Test("the stock macOS sounds are discovered, sorted")
    func installedSounds() {
        let installed = PopupSound.installedSystemSoundNames()
        #expect(installed.contains("Tink"))
        #expect(installed == installed.sorted())
    }
}

@Suite("KnockSynth")
struct KnockSynthTests {
    @Test("renders two distinct taps inside a short buffer")
    func shape() {
        let samples = KnockSynth.samples()
        let duration = Double(samples.count) / KnockSynth.sampleRate
        #expect(duration > 0.08 && duration < 0.35)

        // Count onsets off a 5 ms peak envelope — the raw signal oscillates
        // through zero every cycle, so hysteresis has to run on the envelope.
        let block = Int(KnockSynth.sampleRate * 0.005)
        let envelope = stride(from: 0, to: samples.count, by: block).map { start in
            samples[start..<min(start + block, samples.count)].map(abs).max() ?? 0
        }
        var onsets = 0
        var armed = true
        for level in envelope {
            if armed, level > 0.25 { onsets += 1; armed = false }
            if !armed, level < 0.08 { armed = true }
        }
        #expect(onsets == 2)
    }

    @Test("peak-normalised with headroom")
    func level() {
        let peak = KnockSynth.samples().map(abs).max() ?? 0
        #expect(peak > 0.4 && peak <= 1.0)
    }

    @Test("deterministic across calls")
    func deterministic() {
        #expect(KnockSynth.samples() == KnockSynth.samples())
    }

    @Test("wav data has a RIFF/WAVE header sized to the samples")
    func wavHeader() {
        let data = KnockSynth.wavData()
        #expect(data.starts(with: Array("RIFF".utf8)))
        #expect(data.count == 44 + KnockSynth.samples().count * 2)
        let wave = data.subdata(in: 8..<12)
        #expect(wave == Data("WAVE".utf8))
    }
}
