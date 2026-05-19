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
    public static func parse(_ format: String) throws -> NSPredicate {
        // Swift bridges `+method:error:` to a throwing call; the ObjC
        // trampoline turns the underlying NSException into the NSError
        // that becomes the thrown error here.
        do {
            return try OPPredicateParser.parsePredicate(withFormat: format)
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
