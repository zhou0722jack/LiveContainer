#import <Foundation/Foundation.h>
#import "SSStikDebugBridge.h"
#import <objc/runtime.h>

static NSURL *groupDirectory;
static NSUserDefaults *testDefaults;
static NSUInteger launchCount;
@interface LCSharedUtils : NSObject
+ (NSURL *)appGroupPath;
+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)mode;
@end
@implementation LCSharedUtils
+ (NSURL *)appGroupPath { return groupDirectory; }
+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)mode { launchCount++; return YES; }
@end
@interface NSUserDefaults (ContainerTest)
+ (instancetype)lcUserDefaults;
@end
@implementation NSUserDefaults (ContainerTest)
+ (instancetype)lcUserDefaults { return testDefaults; }
@end

@interface TestJITReply : NSObject
@property NSUInteger progressCount;
@property NSUInteger resultCount;
@property(strong) NSDictionary *result;
@end
@implementation TestJITReply
- (void)progress:(NSString *)message { self.progressCount++; }
- (void)complete:(NSDictionary *)result { self.resultCount++; self.result = result; }
@end

// Keep the real bridge and anonymous XPC transport. Substitute only iOS's
// private extension launcher and the target's csops probe on this macOS host.
@interface SSStikDebugCore : NSObject @end
@implementation SSStikDebugCore @end
static BOOL fakeAttached;
static BOOL attachOnLaunch;
static NSDictionary *resultOnLaunch;
static NSUInteger helperLaunches;
static NSUInteger helperKills;
static NSDictionary *helperPayload;
static NSXPCConnection *helperConnection;
@interface FakeLiveProcess : NSObject
+ (id)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
@end
@implementation FakeLiveProcess
+ (id)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error { return [self new]; }
- (void)setRequestCancellationBlock:(id)block {}
- (void)setRequestInterruptionBlock:(id)block {}
- (void)_kill:(int)signal { helperKills++; [helperConnection invalidate]; helperConnection = nil; }
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *))completion {
    helperLaunches++;
    NSDictionary *info = [items.firstObject userInfo];
    helperPayload = info[@"SSStikDebugRequest"];
    helperConnection = [[NSXPCConnection alloc] initWithListenerEndpoint:info[@"SSStikDebugEndpoint"]];
    helperConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SSStikDebugHelperHost)];
    [helperConnection resume];
    [[helperConnection remoteObjectProxy] reportProgress:@"Debugger preparing"];
    if (resultOnLaunch) [[helperConnection remoteObjectProxy] reportResult:resultOnLaunch withReply:^{}];
    fakeAttached = attachOnLaunch;
    completion(NSUUID.UUID);
}
@end

static void finishMainHelper(NSDictionary *result) {
    __block BOOL acknowledged = NO;
    [[helperConnection remoteObjectProxy] reportResult:result withReply:^{ acknowledged = YES; }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!acknowledged && deadline.timeIntervalSinceNow > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    assert(acknowledged);
    [helperConnection invalidate];
    helperConnection = nil;
}

static void checkMainBootstrap(NSURL *home) {
    Class extension = NSClassFromString(@"NSExtension");
    if (!extension) { extension = objc_allocateClassPair(NSObject.class, "NSExtension", 0); objc_registerClassPair(extension); }
    Method replacement = class_getClassMethod(FakeLiveProcess.class, @selector(extensionWithIdentifier:error:));
    // Return FakeLiveProcess objects, including if the system defines NSExtension.
    IMP makeHelper = imp_implementationWithBlock(^id(id self, NSString *identifier, NSError **error) { return [FakeLiveProcess new]; });
    class_replaceMethod(object_getClass(extension), @selector(extensionWithIdentifier:error:), makeHelper, method_getTypeEncoding(replacement));
    NSURL *host = [home URLByAppendingPathComponent:@"Host.app"];
    [NSFileManager.defaultManager createDirectoryAtURL:host withIntermediateDirectories:YES attributes:nil error:nil];
    [@{ @"CFBundleIdentifier": @"test.host", @"CFBundlePackageType": @"APPL" } writeToURL:[host URLByAppendingPathComponent:@"Info.plist"] atomically:YES];
    NSBundle *bundle = [NSBundle bundleWithURL:host];
    assert(bundle.builtInPlugInsURL != nil);
    NSURL *plugin = [bundle.builtInPlugInsURL URLByAppendingPathComponent:@"LiveProcess.appex"];
    [NSFileManager.defaultManager createDirectoryAtURL:plugin withIntermediateDirectories:YES attributes:nil error:nil];
    [@{ @"CFBundleIdentifier": @"test.host.LiveProcess" } writeToURL:[plugin URLByAppendingPathComponent:@"Info.plist"] atomically:YES];
    NSURL *pairing = [home URLByAppendingPathComponent:@"Documents/SideStore/Documents/PairingFile_RemoteRP.plist"];
    [NSFileManager.defaultManager createDirectoryAtURL:pairing.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [@{ @"test": @YES } writeToURL:pairing atomically:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:[home URLByAppendingPathComponent:@"Library"] withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *report = [home URLByAppendingPathComponent:@"Library/SSBuiltInJITLaunchStatus.plist"];
    NSMutableDictionary *handoff = [@{ @"app": @"Visible.app", @"container": @"data-uuid", @"created": NSDate.date,
        @"originPID": @(getpid() + 1), @"scriptData": @"dGVzdA==" } mutableCopy];
    NSDictionary *request = @{ @"handoff": handoff, @"selectedApp": @"Visible.app", @"selectedContainer": @"data-uuid",
        @"hostHome": home.path, @"hostBundlePath": host.path };
    BOOL (^probe)(void) = ^{ return fakeAttached; };

    attachOnLaunch = YES;
    NSString *error = SSStikDebugStartMainProcess(request, 1, probe);
    assert(error == nil && helperLaunches == 1 && helperKills == 0);
    assert([helperPayload[@"targetPID"] intValue] == getpid());
    assert([helperPayload[@"operation"] isEqual:@"enablePID"]);
    assert([helperPayload[@"scriptData"] isEqual:@"dGVzdA=="]);
    assert(helperPayload[@"pairingPath"] == nil && helperPayload[@"pairingData"] != nil);
    assert([[NSDictionary dictionaryWithContentsOfURL:report][@"state"] isEqual:@"running"]);
    // Attachment unblocks guest startup, but is not reported as script success.
    finishMainHelper(@{ @"error": @"script failure after guest main" });
    assert([[NSDictionary dictionaryWithContentsOfURL:report][@"error"] isEqual:@"script failure after guest main"]);

    fakeAttached = NO;
    error = SSStikDebugStartMainProcess(request, 1, probe);
    assert(error == nil && helperLaunches == 2);
    finishMainHelper(@{ @"message": @"script finished" });
    assert([[NSDictionary dictionaryWithContentsOfURL:report][@"state"] isEqual:@"complete"]);

    fakeAttached = NO; attachOnLaunch = NO;
    error = SSStikDebugStartMainProcess(request, 0.08, probe);
    assert(error != nil && helperLaunches == 3 && helperKills == 1);
    assert([[NSDictionary dictionaryWithContentsOfURL:report][@"state"] isEqual:@"failed"]);

    // A success callback without observed target attachment must stay a failure.
    resultOnLaunch = @{ @"message": @"misleading helper success" };
    error = SSStikDebugStartMainProcess(request, 1, probe);
    assert(error != nil && helperLaunches == 4 && helperKills == 1);
    assert([[NSDictionary dictionaryWithContentsOfURL:report][@"state"] isEqual:@"failed"]);
    [helperConnection invalidate]; helperConnection = nil;
    resultOnLaunch = nil;

    handoff[@"created"] = [NSDate dateWithTimeIntervalSinceNow:-61];
    assert(SSStikDebugStartMainProcess(request, 1, probe) != nil && helperLaunches == 4);
    handoff[@"created"] = NSDate.date; handoff[@"originPID"] = @(getpid());
    assert(SSStikDebugStartMainProcess(request, 1, probe) != nil && helperLaunches == 4);
    handoff[@"originPID"] = @(getpid() + 1); handoff[@"container"] = @"other-container";
    assert(SSStikDebugStartMainProcess(request, 1, probe) != nil && helperLaunches == 4);
    puts("PASS: main-process PID, attachment gate, delayed script result, scoped timeout and stale-target rejection");
}

static void checkXPCReply(void) {
    NSObject *session = [NSClassFromString(@"SSStikDebugHostSession") new];
    assert(session != nil);
    TestJITReply *receiver = [TestJITReply new];
    [session setValue:receiver forKey:@"receiver"];
    NSXPCListener *listener = [NSXPCListener anonymousListener];
    listener.delegate = (id<NSXPCListenerDelegate>)session;
    [session setValue:listener forKey:@"listener"];
    [listener resume];
    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithListenerEndpoint:listener.endpoint];
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SSStikDebugHelperHost)];
    [connection resume];
    __block BOOL acknowledged = NO;
    __block NSError *failure;
    id<SSStikDebugHelperHost> remote = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) { failure = error; }];
    [remote reportProgress:@"Preparing"];
    [remote reportResult:@{ @"message": @"Complete" } withReply:^{ acknowledged = YES; }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!acknowledged && !failure && deadline.timeIntervalSinceNow > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    assert(failure == nil && acknowledged);
    assert(receiver.progressCount == 1 && receiver.resultCount == 1);
    assert([receiver.result[@"message"] isEqual:@"Complete"]);
    __block BOOL duplicateAcknowledged = NO;
    [(id<SSStikDebugHelperHost>)session reportResult:@{ @"error": @"Late failure" } withReply:^{ duplicateAcknowledged = YES; }];
    deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (!duplicateAcknowledged && deadline.timeIntervalSinceNow > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    assert(duplicateAcknowledged && receiver.resultCount == 1);
    [connection invalidate];
    puts("PASS: actual XPC progress, completion acknowledgement and exactly-once result");
}

static void makeApp(NSURL *root, NSString *folder, NSDictionary *config, id name) {
    NSURL *app = [root URLByAppendingPathComponent:folder];
    assert([NSFileManager.defaultManager createDirectoryAtURL:app withIntermediateDirectories:YES attributes:nil error:nil]);
    assert(([@{ @"CFBundleIdentifier": [@"test." stringByAppendingString:folder], @"CFBundleDisplayName": name }
        writeToURL:[app URLByAppendingPathComponent:@"Info.plist"] atomically:YES]));
    assert([config writeToURL:[app URLByAppendingPathComponent:@"LCAppInfo.plist"] atomically:YES]);
}

int main(void) {
    @autoreleasepool {
        NSURL *temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        NSURL *home = [temporary URLByAppendingPathComponent:@"home"];
        groupDirectory = [temporary URLByAppendingPathComponent:@"group"];
        NSURL *privateApps = [home URLByAppendingPathComponent:@"Documents/Applications"];
        NSURL *sharedApps = [groupDirectory URLByAppendingPathComponent:@"LiveContainer/Applications"];
        NSString *suite = [@"SideStore.StikContainerTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        testDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        @try {
            makeApp(privateApps, @"Visible.app", @{}, @"本地 App");
            makeApp(sharedApps, @"Visible.app", @{}, @"共享 App");
            makeApp(privateApps, @"Hidden.app", @{ @"isHidden": @YES }, @"Hidden");
            makeApp(privateApps, @"Locked.app", @{ @"isLocked": @YES }, @"Locked");
            makeApp(privateApps, @"BadName.app", @{}, @42);
            NSURL *bad = [privateApps URLByAppendingPathComponent:@"Malformed.app"];
            [NSFileManager.defaultManager createDirectoryAtURL:bad withIntermediateDirectories:YES attributes:nil error:nil];
            [@"bad plist" writeToURL:[bad URLByAppendingPathComponent:@"Info.plist"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSDictionary *request = @{ @"hostHome": home.path };
            NSArray *apps = SSStikDebugContainerApps(request)[@"apps"];
            assert(apps.count == 3);
            assert(([apps filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name IN %@", @[@"Hidden", @"Locked"]]].count == 0));
            assert(([apps filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"shared == %@", @"true"]].count == 1));
            NSDictionary *badLaunch = @{ @"hostHome": home.path, @"folderName": @"../../outside.app", @"shared": @"false" };
            assert(SSStikDebugLaunchContainer(badLaunch)[@"error"] != nil && launchCount == 0);
            NSDictionary *wrongStorage = @{ @"hostHome": home.path, @"folderName": @"BadName.app", @"shared": @"true" };
            assert(SSStikDebugLaunchContainer(wrongStorage)[@"error"] != nil && launchCount == 0);
            NSDictionary *valid = @{ @"hostHome": home.path, @"folderName": @"Visible.app", @"shared": @"true" };
            assert(SSStikDebugLaunchContainer(valid)[@"error"] == nil && launchCount == 1);
            assert([[testDefaults stringForKey:@"selected"] isEqual:@"ui"]);
            NSDictionary *pending = [testDefaults dictionaryForKey:@"SSBuiltInJITPendingContainer"];
            assert([pending[@"folderName"] isEqual:@"Visible.app"] && [pending[@"shared"] isEqual:@"true"]);
            assert(![testDefaults boolForKey:@"LCOpenSideStore"]);
            puts("PASS: actual native container enumeration and launch handoff");
            checkXPCReply();
            checkMainBootstrap(home);
        } @finally {
            [testDefaults removePersistentDomainForName:suite];
            [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
        }
    }
    return 0;
}
