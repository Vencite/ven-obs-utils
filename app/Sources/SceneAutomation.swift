import Foundation

enum SceneTransitionAction: String, Equatable {
    case enterBreak
    case leaveBreak
    case ignore
}

enum ScenePatternError: Error, Equatable {
    case invalidRegex
}

enum SceneTransitionClassifier {
    static func validate(pattern: String) throws {
        do {
            _ = try NSRegularExpression(pattern: pattern)
        } catch {
            throw ScenePatternError.invalidRegex
        }
    }

    static func classify(
        previous: String,
        current: String,
        pattern: String
    ) throws -> SceneTransitionAction {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            throw ScenePatternError.invalidRegex
        }

        let previousIsBreak = matches(previous, regex: regex)
        let currentIsBreak = matches(current, regex: regex)

        switch (previousIsBreak, currentIsBreak) {
        case (false, true): return .enterBreak
        case (true, false): return .leaveBreak
        default: return .ignore
        }
    }

    private static func matches(_ value: String, regex: NSRegularExpression) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return false }
        return match.range == range
    }
}
