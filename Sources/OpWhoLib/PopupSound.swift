import AVFoundation
import AppKit

/// A choice in the Settings "Sound" popup: silence, the built-in knock-knock,
/// or one of the macOS alert sounds.
public struct PopupSound: Equatable {
    public enum Source: Equatable {
        case silent
        /// A `.wav` in `Sources/OpWhoLib/Resources` (see its README for
        /// provenance), resolved through `Bundle.module`.
        case bundled(String)
        /// Synthesised in-process; see `KnockSynth`.
        case knockKnock
        /// An `NSSound(named:)` alert sound.
        case system(String)
    }

    /// Stable identifier persisted in UserDefaults.
    public let id: String
    /// Menu-item label.
    public let title: String
    public let source: Source

    public static let off = PopupSound(id: "off", title: "Off", source: .silent)
    public static let tripleTone = PopupSound(
        id: "triple-tone", title: "Triple tone", source: .bundled("triple-tone")
    )
    public static let knockKnock = PopupSound(
        id: "knock", title: "Knock-knock", source: .knockKnock
    )

    public static func system(_ name: String) -> PopupSound {
        PopupSound(id: "sound:\(name)", title: name, source: .system(name))
    }

    /// Off and the two built-ins first, then the installed alert sounds in
    /// the order given.
    public static func catalog(systemSoundNames: [String] = installedSystemSoundNames())
        -> [PopupSound] {
        [.off, .tripleTone, .knockKnock] + systemSoundNames.map(system)
    }

    /// Look up a persisted id. An id naming a sound that is no longer
    /// installed falls back to the default rather than to silence — a missing
    /// file should not quietly turn the alert off.
    public static func resolve(
        id: String,
        systemSoundNames: [String] = installedSystemSoundNames()
    ) -> PopupSound {
        catalog(systemSoundNames: systemSoundNames).first { $0.id == id } ?? .tripleTone
    }

    /// Alert sounds visible to `NSSound(named:)`, sorted, user sounds first-class.
    public static func installedSystemSoundNames() -> [String] {
        let directories = [
            "/System/Library/Sounds",
            NSHomeDirectory() + "/Library/Sounds",
        ]
        var names = Set<String>()
        for directory in directories {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for entry in entries where NSSound(named: (entry as NSString).deletingPathExtension) != nil {
                names.insert((entry as NSString).deletingPathExtension)
            }
        }
        return names.sorted()
    }

    /// Which sound an approval plays: a matched rule's override wins over
    /// the global setting, nil falls through to it.
    public static func effectiveID(ruleSoundID: String?, globalSoundID: String) -> String {
        ruleSoundID ?? globalSoundID
    }

    /// Bytes for a bundled sound, or nil if the resource is missing.
    static func bundledData(_ name: String) -> Data? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "wav") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// Fire and forget. Safe to call for `.silent`. Main thread.
    public func play() {
        switch source {
        case .silent:
            return
        case .bundled(let name):
            SoundKeeper.shared.play(key: "bundled:\(name)", data: Self.bundledData(name))
        case .knockKnock:
            SoundKeeper.shared.play(key: "knock", data: KnockSynth.wavData())
        case .system(let name):
            NSSound(named: name)?.play()
        }
    }
}

/// Holds players alive across async playback and reuses the decoded buffer —
/// approvals can arrive back to back. `data` is only evaluated on a cache miss.
private final class SoundKeeper {
    static let shared = SoundKeeper()
    private var players: [String: AVAudioPlayer] = [:]

    func play(key: String, data: @autoclosure () -> Data?) {
        if players[key] == nil, let bytes = data(),
           let player = try? AVAudioPlayer(data: bytes) {
            player.prepareToPlay()
            players[key] = player
        }
        players[key]?.currentTime = 0
        players[key]?.play()
    }
}
