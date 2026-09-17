import Foundation

enum PlayerTopControl: String, CaseIterable, Identifiable, Sendable {
    case speed
    case loop
    case mute
    case fullscreen
    case autoplay
    case quality
    case captions

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speed: return "Speed"
        case .loop: return "Loop"
        case .mute: return "Mute"
        case .fullscreen: return "Fullscreen"
        case .autoplay: return "Autoplay"
        case .quality: return "Quality"
        case .captions: return "Captions"
        }
    }

    var systemImage: String {
        switch self {
        case .speed: return "gauge.with.dots.needle.67percent"
        case .loop: return "repeat.1"
        case .mute: return "speaker.slash"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        case .autoplay: return "play.circle"
        case .quality: return "slider.horizontal.3"
        case .captions: return "captions.bubble"
        }
    }

    static let defaultOrder: [PlayerTopControl] = [.autoplay, .loop, .mute, .captions, .quality, .fullscreen, .speed]

    static func decodeOrder(_ rawValue: String) -> [PlayerTopControl] {
        let stored = rawValue.split(separator: ",").compactMap { PlayerTopControl(rawValue: String($0)) }
        var result = stored.reduce(into: [PlayerTopControl]()) { partial, control in
            if !partial.contains(control) { partial.append(control) }
        }
        for control in defaultOrder where !result.contains(control) {
            result.append(control)
        }
        return result
    }

    static func encodeOrder(_ controls: [PlayerTopControl]) -> String {
        controls.map(\.rawValue).joined(separator: ",")
    }

    static func decodeHidden(_ rawValue: String) -> Set<PlayerTopControl> {
        Set(rawValue.split(separator: ",").compactMap { PlayerTopControl(rawValue: String($0)) })
    }

    static func encodeHidden(_ controls: Set<PlayerTopControl>) -> String {
        controls.map(\.rawValue).sorted().joined(separator: ",")
    }
}
