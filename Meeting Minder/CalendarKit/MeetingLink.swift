import Foundation

enum MeetingProvider: String, Equatable {
    case googleMeet
    case microsoftTeams
    case zoom
    case webex
    case other

    var displayName: String {
        switch self {
        case .googleMeet: return "Google Meet"
        case .microsoftTeams: return "Microsoft Teams"
        case .zoom: return "Zoom"
        case .webex: return "Webex"
        case .other: return "Meeting"
        }
    }

    var joinButtonTitle: String {
        switch self {
        case .other: return "Join Meeting"
        default: return "Join \(displayName)"
        }
    }

    var symbolName: String {
        switch self {
        case .googleMeet, .zoom, .microsoftTeams, .webex: return "video.fill"
        case .other: return "link"
        }
    }
}

struct MeetingLink: Equatable {
    let provider: MeetingProvider
    let url: URL
}

/// Finds a joinable conference URL for an event.
///
/// Structured `conferenceData` is authoritative when present; otherwise the location
/// and description are scanned, which is how most cross-platform invites (Zoom, Teams)
/// arrive in a Google Calendar.
enum MeetingLinkDetector {

    private struct Pattern {
        let provider: MeetingProvider
        let regex: NSRegularExpression
    }

    private static let patterns: [Pattern] = {
        let definitions: [(MeetingProvider, String)] = [
            (.googleMeet, #"https://meet\.google\.com/[a-zA-Z0-9\-_/?=&.]+"#),
            (.microsoftTeams, #"https://teams\.microsoft\.com/l/meetup-join/[^\s<>"')\]]+"#),
            (.microsoftTeams, #"https://teams\.microsoft\.com/meet/[^\s<>"')\]]+"#),
            (.microsoftTeams, #"https://teams\.live\.com/meet/[^\s<>"')\]]+"#),
            (.zoom, #"https://[a-zA-Z0-9.\-]*zoom\.us/(?:j|my|w|s)/[^\s<>"')\]]+"#),
            (.zoom, #"https://[a-zA-Z0-9.\-]*zoom\.us/[a-zA-Z0-9]+/[0-9]{6,}[^\s<>"')\]]*"#),
            (.webex, #"https://[a-zA-Z0-9.\-]*webex\.com/[^\s<>"')\]]+"#),
        ]
        return definitions.compactMap { provider, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return Pattern(provider: provider, regex: regex)
        }
    }()

    static func provider(for urlString: String) -> MeetingProvider {
        let lower = urlString.lowercased()
        if lower.contains("meet.google.com") { return .googleMeet }
        if lower.contains("teams.microsoft.com") || lower.contains("teams.live.com") { return .microsoftTeams }
        if lower.contains("zoom.us") || lower.contains("zoom.com") { return .zoom }
        if lower.contains("webex.com") { return .webex }
        return .other
    }

    /// Scans free text (location or description) for the first recognisable conference link.
    static func firstLink(in text: String?) -> MeetingLink? {
        guard let text, !text.isEmpty else { return nil }
        let cleaned = text.decodingBasicHTMLEntities()
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)

        var best: (location: Int, link: MeetingLink)?
        for pattern in patterns {
            guard let match = pattern.regex.firstMatch(in: cleaned, options: [], range: range),
                  let matchRange = Range(match.range, in: cleaned)
            else { continue }

            let raw = String(cleaned[matchRange]).trimmingTrailingPunctuation()
            guard let url = URL(string: raw) else { continue }

            if best == nil || match.range.location < best!.location {
                best = (match.range.location, MeetingLink(provider: pattern.provider, url: url))
            }
        }
        return best?.link
    }
}

extension String {
    /// Google's event descriptions are HTML fragments; entities would otherwise corrupt URLs.
    func decodingBasicHTMLEntities() -> String {
        var result = self
        let entities = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    /// Strips punctuation a URL picked up from surrounding prose.
    func trimmingTrailingPunctuation() -> String {
        var s = self
        while let last = s.last, ".,;:!?)]}>\"'".contains(last) {
            s.removeLast()
        }
        return s
    }

    /// Removes HTML tags and collapses whitespace, for showing a description safely.
    func strippingHTML() -> String {
        let withoutTags = replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return withoutTags
            .decodingBasicHTMLEntities()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func truncated(to maxLength: Int) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let cutoff = trimmed.index(trimmed.startIndex, offsetBy: max(1, maxLength - 1))
        return trimmed[trimmed.startIndex..<cutoff].trimmingCharacters(in: .whitespaces) + "…"
    }
}
