#import <Foundation/Foundation.h>
#import "SSStikDebugBridge.h"

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
        } @finally {
            [testDefaults removePersistentDomainForName:suite];
            [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
        }
    }
    return 0;
}
