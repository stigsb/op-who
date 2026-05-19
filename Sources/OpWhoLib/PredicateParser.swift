import Foundation
import OpWhoObjCShim

/// Swift-throwing facade over `OPPredicateParser`. The underlying ObjC
/// trampoline catches the `NSException` that `NSPredicate(format:)`
/// raises on malformed input and surfaces it as an `NSError`; we
/// re-shape that into `PredicateParseError` so call sites can pattern-
/// match in Swift the normal way.
public enum PredicateParseError: Error, Equatable {
    /// NSPredicate's parser rejected the input. `message` is whatever
    /// reason text the parser produced — typically informative ("Unable
    /// to parse the format string …") but without column offsets.
    case invalidFormat(message: String)

    public var localizedDescription: String {
        switch self {
        case .invalidFormat(let message):
            return message
        }
    }
}

public enum PredicateParser {
    /// Parse `format` into an `NSPredicate`, or throw
    /// `PredicateParseError.invalidFormat` if NSPredicate's parser
    /// rejects it. Safe to call with arbitrary user input.
    ///
    /// `~/…` and a lone `~` at the start of any single- or double-quoted
    /// string literal are expanded to the current user's home directory
    /// before parsing — `triggerCwd BEGINSWITH "~/git/foo"` is a much
    /// nicer thing for a user to type than the literal `/Users/stig/…`,
    /// and NSPredicate has no built-in for it.
    public static func parse(_ format: String) throws -> NSPredicate {
        let expanded = expandLeadingTildes(in: format)
        // Swift bridges `+method:error:` to a throwing call; the ObjC
        // trampoline turns the underlying NSException into the NSError
        // that becomes the thrown error here.
        do {
            return try OPPredicateParser.parsePredicate(withFormat: expanded)
        } catch {
            throw PredicateParseError.invalidFormat(message: error.localizedDescription)
        }
    }

    /// Convenience: parse-and-discard. Returns nil on success, the parse
    /// error otherwise. Useful for editor-side validation where the
    /// caller doesn't want to keep the resulting predicate.
    public static func validate(_ format: String) -> PredicateParseError? {
        do {
            _ = try parse(format)
            return nil
        } catch let error as PredicateParseError {
            return error
        } catch {
            return .invalidFormat(message: String(describing: error))
        }
    }
}

/// Rewrite `"~/…"` and `"~"` (also single-quoted) to the absolute home
/// directory path. Only expanded at the very start of a string literal,
/// so `"foo~bar"` stays literal. Backslash-escaped quotes inside string
/// literals are tracked so `"\""` doesn't fool the state machine into
/// thinking the string ended early.
///
/// Exposed at file scope (not nested in PredicateParser) so the test
/// suite can target it directly.
func expandLeadingTildes(in format: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var result = ""
    var i = format.startIndex
    var stringOpener: Character? = nil

    while i < format.endIndex {
        let c = format[i]

        if let opener = stringOpener {
            // Inside a string literal. Track \-escapes so a \" doesn't
            // close the string prematurely; bail back to .normal on the
            // unescaped closing quote.
            if c == "\\" {
                let next = format.index(after: i)
                result.append(c)
                if next < format.endIndex {
                    result.append(format[next])
                    i = format.index(after: next)
                } else {
                    i = next
                }
                continue
            }
            if c == opener {
                stringOpener = nil
            }
            result.append(c)
            i = format.index(after: i)
            continue
        }

        if c == "\"" || c == "'" {
            // Opening quote. Peek for ~ followed by /, end-of-string, or
            // the matching closer.
            result.append(c)
            stringOpener = c
            let next = format.index(after: i)
            if next < format.endIndex, format[next] == "~" {
                let afterTilde = format.index(after: next)
                let atBoundary: Bool = {
                    if afterTilde == format.endIndex { return true }
                    let following = format[afterTilde]
                    return following == "/" || following == c
                }()
                if atBoundary {
                    result.append(home)
                    i = afterTilde
                    continue
                }
            }
            i = next
            continue
        }

        result.append(c)
        i = format.index(after: i)
    }
    return result
}
