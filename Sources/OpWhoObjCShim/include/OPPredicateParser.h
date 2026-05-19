#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for parse failures returned from
/// `+[OPPredicateParser parsePredicateWithFormat:error:]`.
FOUNDATION_EXPORT NSErrorDomain const OPPredicateParserErrorDomain;

/// Wraps `+[NSPredicate predicateWithFormat:]` in `@try`/`@catch` so the
/// `NSException` raised on malformed input becomes a recoverable
/// `NSError` in Swift. Swift can't catch Objective-C exceptions
/// directly, so without this trampoline a typo in a user-authored
/// predicate would crash the app at parse time.
@interface OPPredicateParser : NSObject

+ (nullable NSPredicate *)parsePredicateWithFormat:(NSString *)format
                                             error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
