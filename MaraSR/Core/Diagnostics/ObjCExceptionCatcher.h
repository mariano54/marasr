#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const MRSObjCExceptionErrorDomain;

/// Error userInfo keys describing the caught exception.
extern NSString *const MRSObjCExceptionNameKey;
extern NSString *const MRSObjCExceptionReasonKey;
extern NSString *const MRSObjCExceptionCallStackKey;

/// Runs a block and turns an Objective-C exception into an NSError.
///
/// Swift cannot catch NSExceptions. One that unwinds through Swift frames
/// (AVAudioEngine throws them for format mismatches) leaves the Swift
/// runtime in an undefined state and crashes later somewhere unrelated.
@interface MRSObjCExceptionCatcher : NSObject

+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block
               error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(perform(_:));

@end

NS_ASSUME_NONNULL_END
