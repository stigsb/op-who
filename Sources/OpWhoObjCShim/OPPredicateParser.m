#import "OPPredicateParser.h"

NSErrorDomain const OPPredicateParserErrorDomain = @"OPPredicateParserErrorDomain";

@implementation OPPredicateParser

+ (nullable NSPredicate *)parsePredicateWithFormat:(NSString *)format
                                             error:(NSError * _Nullable * _Nullable)error {
    @try {
        return [NSPredicate predicateWithFormat:format];
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: @"Invalid predicate format";
            NSMutableDictionary<NSErrorUserInfoKey, id> *info =
                [NSMutableDictionary dictionaryWithCapacity:2];
            info[NSLocalizedDescriptionKey] = reason;
            if (exception.name) {
                info[@"NSExceptionName"] = exception.name;
            }
            *error = [NSError errorWithDomain:OPPredicateParserErrorDomain
                                         code:1
                                     userInfo:info];
        }
        return nil;
    }
}

@end
