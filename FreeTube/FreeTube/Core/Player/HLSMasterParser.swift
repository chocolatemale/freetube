import Foundation

/// Picks a default audio media playlist out of an HLS master.
///
/// Music playback prefers this URL over YouTube's progressive itag 140 DASH
/// `m4a`, whose empty `stts` atom makes AVPlayer report a doubled duration.
nonisolated enum HLSMasterParser {
    static func preferredAudioURL(playlist: String, baseURL: URL) -> URL? {
        var renditions: [AudioRendition] = []

        for rawLine in playlist.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-MEDIA:") else { continue }
            let attributes = parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
            guard attributes["TYPE"] == "AUDIO",
                  let uri = attributes["URI"],
                  let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else { continue }
            renditions.append(
                AudioRendition(
                    url: url,
                    name: attributes["NAME"] ?? attributes["LANGUAGE"] ?? "Audio",
                    isDefault: attributes["DEFAULT"] == "YES",
                    isAutoSelect: attributes["AUTOSELECT"] == "YES"
                )
            )
        }

        return preferredAudio(from: renditions)?.url
    }

    private static func preferredAudio(from renditions: [AudioRendition]) -> AudioRendition? {
        renditions.first { $0.isDefault && !$0.name.localizedCaseInsensitiveContains("dubbed") }
            ?? renditions.first { $0.isDefault }
            ?? renditions.first { $0.isAutoSelect && !$0.name.localizedCaseInsensitiveContains("dubbed") }
            ?? renditions.first { !$0.name.localizedCaseInsensitiveContains("dubbed") }
            ?? renditions.first
    }

    private static func parseAttributes(_ input: String) -> [String: String] {
        var result: [String: String] = [:]
        var start = input.startIndex
        var inQuotes = false
        var pieces: [Substring] = []
        for index in input.indices {
            if input[index] == "\"" { inQuotes.toggle() }
            if input[index] == ",", !inQuotes {
                pieces.append(input[start..<index])
                start = input.index(after: index)
            }
        }
        pieces.append(input[start...])
        for piece in pieces {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<equals].trimmingCharacters(in: .whitespaces)
            var value = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            result[key] = value
        }
        return result
    }

    private struct AudioRendition {
        let url: URL
        let name: String
        let isDefault: Bool
        let isAutoSelect: Bool
    }
}
