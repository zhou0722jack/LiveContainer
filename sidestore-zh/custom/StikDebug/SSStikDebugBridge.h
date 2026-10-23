#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@protocol SSStikDebugHelperHost <NSObject>
- (void)reportProgress:(NSString *)message;
- (void)reportResult:(NSDictionary *)result withReply:(void (^)(void))reply;
@end
FOUNDATION_EXPORT void SSStikDebugExecuteInHelper(NSDictionary<NSString *, id> *request);
// Called in the NEW ordinary host process, before guest identity/path hooks.
// Returning nil means attached, not that the target's JIT script has finished.
FOUNDATION_EXPORT NSString * _Nullable SSStikDebugStartMainProcess(
    NSDictionary<NSString *, id> *request, NSTimeInterval timeout, BOOL (^isDebugged)(void));
FOUNDATION_EXPORT NSDictionary<NSString *, id> *SSStikDebugContainerApps(NSDictionary<NSString *, id> *request);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *SSStikDebugLaunchContainer(NSDictionary<NSString *, id> *request);
NS_ASSUME_NONNULL_END
