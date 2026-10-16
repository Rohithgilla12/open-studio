import Foundation
import Timeline

public enum AudioSource: String, Sendable, Hashable, CaseIterable {
    case microphone
    case systemAudio

    /// The sources the take has, in a fixed order.
    public static func recorded(in source: SourceRecording) -> [AudioSource] {
        allCases.filter { $0.movie(in: source) != nil }
    }

    /// As a label shows it, in sentence case.
    public var name: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System audio"
        }
    }

    public func movie(in source: SourceRecording) -> URL? {
        switch self {
        case .microphone: source.microphoneMovie
        case .systemAudio: source.systemAudioMovie
        }
    }
}

public struct AudioLevel: Sendable, Hashable {
    /// Linear gain, the scale `AVAudioMix` takes, so 0.5 is about -6 dB.
    public var volume: Double
    public var isMuted: Bool

    public init(volume: Double = 1, isMuted: Bool = false) {
        self.volume = volume
        self.isMuted = isMuted
    }

    public static let full = AudioLevel()
    public static let volumeRange: ClosedRange<Double> = 0...1

    public var gain: Double { isMuted ? 0 : volume }
}

public struct AudioLevels: Sendable, Hashable {
    public var microphone: AudioLevel
    public var systemAudio: AudioLevel

    public init(microphone: AudioLevel = .full, systemAudio: AudioLevel = .full) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    public static let `default` = AudioLevels()

    public subscript(source: AudioSource) -> AudioLevel {
        get {
            switch source {
            case .microphone: microphone
            case .systemAudio: systemAudio
            }
        }
        set {
            switch source {
            case .microphone: microphone = newValue
            case .systemAudio: systemAudio = newValue
            }
        }
    }

    var problem: String? {
        for source in AudioSource.allCases where !AudioLevel.volumeRange.contains(self[source].volume) {
            return "\(source.rawValue) volume \(self[source].volume) is not in \(AudioLevel.volumeRange)"
        }
        return nil
    }
}

extension AudioLevel: Codable {
    private enum CodingKeys: String, CodingKey {
        case volume, isMuted
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            volume: try c.decodeIfPresent(Double.self, forKey: .volume) ?? AudioLevel.full.volume,
            isMuted: try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? AudioLevel.full.isMuted)
    }
}

extension AudioLevels: Codable {
    private enum CodingKeys: String, CodingKey {
        case microphone, systemAudio
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            microphone: try c.decodeIfPresent(AudioLevel.self, forKey: .microphone) ?? .full,
            systemAudio: try c.decodeIfPresent(AudioLevel.self, forKey: .systemAudio) ?? .full)
    }
}
