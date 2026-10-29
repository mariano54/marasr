#import "ObjCExceptionCatcher.h"

NSErrorDomain const MRSObjCExceptionErrorDomain = @"com.mariano.marasr.ObjCException";
NSString *const MRSObjCExceptionNameKey = @"MRSObjCExceptionName";
NSString *const MRSObjCExceptionReasonKey = @"MRSObjCExceptionReason";
NSString *const MRSObjCExceptionCallStackKey = @"MRSObjCExceptionCallStack";

@implementation MRSObjCExceptionCatcher

+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block
               error:(NSError *_Nullable *_Nullable)error {
  @try {
    block();
    return YES;
  } @catch (NSException *exception) {
    if (error) {
      NSString *reason = exception.reason ?: exception.name;
      *error = [NSError errorWithDomain:MRSObjCExceptionErrorDomain
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey : reason,
                                 MRSObjCExceptionNameKey : exception.name,
                                 MRSObjCExceptionReasonKey : reason,
                                 MRSObjCExceptionCallStackKey :
                                     exception.callStackSymbols ?: @[],
                               }];
    }
    return NO;
  }
}

@end
