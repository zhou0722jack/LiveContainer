#import "SSStikDebugBridge.h"
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <signal.h>

// Use LiveContainer's existing, multiple-instance LiveProcess extension.
@interface NSExtension : NSObject
+ (instancetype)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *))completion;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *, NSError *))block;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *))block;
- (void)_kill:(int)signal;
@end

static NSDictionary *SSFailure(NSString *message) { return @{ @"error": message ?: @"内置 JIT 操作失败，未提供错误详情。" }; }
static id SSClassValue(NSString *name, NSString *selector) {
    Class type = NSClassFromString(name);
    return type && [type respondsToSelector:NSSelectorFromString(selector)]
        ? ((id (*)(id, SEL))objc_msgSend)(type, NSSelectorFromString(selector)) : nil;
}
static void SSReply(id receiver, NSString *selector, id value) {
    if ([receiver respondsToSelector:NSSelectorFromString(selector)])
        ((void (*)(id, SEL, id))objc_msgSend)(receiver, NSSelectorFromString(selector), value);
}

@interface SSStikDebugHostSession : NSObject <NSXPCListenerDelegate, SSStikDebugHelperHost>
@property(strong) id receiver;
@property(strong) NSXPCListener *listener;
@property(strong) NSXPCConnection *connection;
@property(strong) NSExtension *child;
@property BOOL finished;
@end

static NSMutableSet *SSActiveSessions;
@implementation SSStikDebugHostSession
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    if (self.connection || self.finished) return NO;
    self.connection = connection;
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SSStikDebugHelperHost)];
    connection.exportedObject = self;
    __weak typeof(self) weakSelf = self;
    connection.invalidationHandler = ^{ dispatch_async(dispatch_get_main_queue(), ^{
        if (!weakSelf.finished) [weakSelf finish:SSFailure(@"内置 JIT 辅助进程连接中断。")];
    }); };
    [connection resume];
    return YES;
}
- (void)reportProgress:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self.finished) SSReply(self.receiver, @"progress:", message); });
}
- (void)reportResult:(NSDictionary *)result withReply:(void (^)(void))reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Acknowledge before tearing down XPC, so the helper can remove its file.
        if (reply) reply();
        [self finish:result];
    });
}
- (void)finish:(NSDictionary *)result {
    if (self.finished) return;
    self.finished = YES;
    SSReply(self.receiver, @"complete:", result);
    self.receiver = nil;
    [self.listener invalidate];
    self.listener = nil;
    NSXPCConnection *connection = self.connection;
    self.connection = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [connection invalidate]; self.child = nil; });
    [SSActiveSessions removeObject:self];
}
@end

void SSStikDebugExecuteInHelper(NSDictionary *request) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id receiver = request[@"reply"];
        if (!receiver) return;
        SEL shouldStart = NSSelectorFromString(@"shouldStartHelper");
        if ([receiver respondsToSelector:shouldStart] && !((BOOL (*)(id, SEL))objc_msgSend)(receiver, shouldStart)) return;
        if (SSActiveSessions.count > 0) { SSReply(receiver, @"complete:", SSFailure(@"已有内置 JIT 任务正在运行，请等待完成。")); return; }
        if (@available(iOS 17.4, *)) {} else { SSReply(receiver, @"complete:", SSFailure(@"内置 JIT 需要 iOS 17.4 或更新版本。")); return; }
        NSString *hostPath = request[@"hostBundlePath"];
        NSBundle *host = [hostPath isKindOfClass:NSString.class] ? [NSBundle bundleWithPath:hostPath] : nil;
        if (!host.builtInPlugInsURL) { SSReply(receiver, @"complete:", SSFailure(@"无法定位当前二合一宿主及扩展目录。")); return; }
        NSBundle *extension = [NSBundle bundleWithURL:[host.builtInPlugInsURL URLByAppendingPathComponent:@"LiveProcess.appex"]];
        NSError *error;
        NSExtension *child = extension ? [NSExtension extensionWithIdentifier:extension.bundleIdentifier error:&error] : nil;
        if (!child) { SSReply(receiver, @"complete:", SSFailure(error.localizedDescription ?: @"缺少 LiveProcess 扩展。请保留原有扩展重新安装。")); return; }
        NSMutableDictionary *payload = request.mutableCopy;
        [payload removeObjectForKey:@"reply"];
        [payload removeObjectForKey:@"hostBundlePath"];
        if (![request[@"operation"] isEqual:@"reset"]) {
            NSData *pairing = [NSData dataWithContentsOfFile:request[@"pairingPath"] options:0 error:&error];
            if (!pairing || pairing.length == 0 || pairing.length > 1024 * 1024) {
                SSReply(receiver, @"complete:", SSFailure(error.localizedDescription ?: @"Remote Pairing 文件为空或过大。")); return;
            }
            payload[@"pairingData"] = pairing;
        }
        [payload removeObjectForKey:@"pairingPath"];
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SSActiveSessions = [NSMutableSet new]; });
        SSStikDebugHostSession *session = [SSStikDebugHostSession new];
        session.receiver = receiver;
        session.child = child;
        session.listener = [NSXPCListener anonymousListener];
        session.listener.delegate = session;
        [session.listener resume];
        [SSActiveSessions addObject:session];
        NSBundle *core = [NSBundle bundleForClass:NSClassFromString(@"SSStikDebugCore")];
        if (!core.executablePath) { [session finish:SSFailure(@"无法定位内置 JIT 核心可执行文件。")]; return; }
        NSExtensionItem *item = [NSExtensionItem new];
        item.userInfo = @{ @"customPayloadDylib": core.executablePath,
            @"customPayloadEntry": @"SSStikDebugHelperMain", @"SSStikDebugRequest": payload,
            @"SSStikDebugEndpoint": session.listener.endpoint };
        __weak SSStikDebugHostSession *weakSession = session;
        [child setRequestCancellationBlock:^(NSUUID *identifier, NSError *failure) { dispatch_async(dispatch_get_main_queue(), ^{
            [weakSession finish:SSFailure(failure.localizedDescription ?: @"内置 JIT 辅助进程被取消。")];
        }); }];
        [child setRequestInterruptionBlock:^(NSUUID *identifier) { dispatch_async(dispatch_get_main_queue(), ^{
            [weakSession finish:SSFailure(@"内置 JIT 辅助进程提前退出。")];
        }); }];
        [child beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *identifier) {
            if (!identifier) dispatch_async(dispatch_get_main_queue(), ^{ [weakSession finish:SSFailure(@"无法启动内置 JIT 辅助进程。")]; });
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            SSStikDebugHostSession *active = weakSession;
            if (active && !active.finished) {
                [active.child _kill:SIGKILL];
                [active finish:SSFailure(@"内置 JIT 超时，辅助进程已结束。请检查目标 App 的 JIT 协议和连接。")];
            }
        });
    });
}

// The host changes HOME, Bundle.main and preference domains while loading the
// guest. Capture absolute host URLs now; never resolve them in late callbacks.
@interface SSStikDebugMainReply : NSObject
@property(strong) NSURL *reportURL;
@property(strong) NSDictionary *identity;
@property BOOL finished;
@property(copy) NSString *error;
- (BOOL)record:(NSString *)state error:(NSString *)error;
- (void)complete:(NSDictionary *)result;
@end
@implementation SSStikDebugMainReply
- (BOOL)shouldStartHelper { return !self.finished; }
- (BOOL)record:(NSString *)state error:(NSString *)error {
    NSMutableDictionary *report = self.identity.mutableCopy;
    report[@"state"] = state;
    if (error) report[@"error"] = error;
    return [report writeToURL:self.reportURL atomically:YES];
}
- (void)progress:(NSString *)message { /* Device/script progress is not JIT success. */ }
- (void)complete:(NSDictionary *)result {
    if (self.finished) return;
    self.finished = YES;
    self.error = result[@"error"];
    [self record:self.error ? @"failed" : @"complete" error:self.error];
}
@end

static void SSCancelMainHelper(SSStikDebugMainReply *receiver, NSString *error) {
    [receiver complete:SSFailure(error)];
    // Even an apparent helper success is not sufficient if the target never
    // observed attachment. Do not leave a misleading success receipt behind.
    receiver.error = error;
    [receiver record:@"failed" error:error];
    // Cancel only this startup's session. Never kill a later/unrelated helper.
    for (SSStikDebugHostSession *session in SSActiveSessions.copy) {
        if (session.receiver != receiver) continue;
        [session.child _kill:SIGKILL];
        [session finish:SSFailure(error)];
    }
}

NSString *SSStikDebugStartMainProcess(NSDictionary *request, NSTimeInterval timeout, BOOL (^isDebugged)(void)) {
    if (!NSThread.isMainThread) return @"内置 JIT 全屏启动必须在主线程执行。";
    NSDictionary *handoff = request[@"handoff"];
    if (![handoff isKindOfClass:NSDictionary.class]) return @"缺少内置 JIT 全屏启动交接。";
    NSDate *created = handoff[@"created"];
    NSNumber *origin = handoff[@"originPID"];
    if (![created isKindOfClass:NSDate.class] || created.timeIntervalSinceNow > 0 || created.timeIntervalSinceNow < -60 ||
        ![origin isKindOfClass:NSNumber.class] || origin.intValue <= 0 || origin.intValue == getpid() ||
        ![handoff[@"app"] isKindOfClass:NSString.class] || ![handoff[@"app"] isEqual:request[@"selectedApp"]] ||
        ![handoff[@"container"] isKindOfClass:NSString.class] || ![handoff[@"container"] isEqual:request[@"selectedContainer"]]) {
        return @"内置 JIT 启动交接过期或目标不一致，已取消；请重新选择 App。";
    }
    NSString *home = request[@"hostHome"];
    NSString *bundle = request[@"hostBundlePath"];
    if (![home isKindOfClass:NSString.class] || !home.isAbsolutePath ||
        ![bundle isKindOfClass:NSString.class] || !bundle.isAbsolutePath || timeout <= 0 || timeout > 15) {
        return @"无法确定全屏启动的宿主目录或等待时限。";
    }
    NSURL *library = [NSURL fileURLWithPath:[home stringByAppendingPathComponent:@"Library"]];
    SSStikDebugMainReply *receiver = [SSStikDebugMainReply new];
    receiver.reportURL = [library URLByAppendingPathComponent:@"SSBuiltInJITLaunchStatus.plist"];
    receiver.identity = @{ @"pid": @(getpid()), @"app": handoff[@"app"], @"container": handoff[@"container"] };
    if (![receiver record:@"attaching" error:nil]) return @"无法保存内置 JIT 启动状态，请检查宿主存储空间。";
    NSString *sideStore = [home stringByAppendingPathComponent:@"Documents/SideStore"];
    NSString *pairing = [sideStore stringByAppendingPathComponent:@"Documents/PairingFile_RemoteRP.plist"];
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:[sideStore stringByAppendingPathComponent:@"Library/Preferences/SSBuiltInJITConnection.plist"]] ?: @{};
    NSMutableDictionary *operation = [@{ @"operation": @"enablePID", @"targetPID": @(getpid()),
        @"hostBundlePath": bundle, @"pairingPath": pairing, @"reply": receiver,
        @"address": config[@"address"] ?: @"10.7.0.1", @"port": config[@"port"] ?: @49152 } mutableCopy];
    if (handoff[@"scriptData"]) operation[@"scriptData"] = handoff[@"scriptData"];
    SSStikDebugExecuteInHelper(operation);
    // No UIKit app or guest code has been initialized yet. Pump the main run
    // loop so the extension and XPC callbacks can run; never block it on a sem.
    // On TXM, waiting for SCRIPT completion here would deadlock: the script
    // needs the guest to enter main and issue its JIT memory-region requests.
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    BOOL attached = NO;
    while (!receiver.error && !(attached = isDebugged()) && !receiver.finished && CFAbsoluteTimeGetCurrent() < deadline) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    }
    if (receiver.error) return receiver.error;
    if (!attached) {
        NSString *error = @"全屏启动未在时限内确认调试器附加，已取消本次 JIT。请检查 Remote Pairing、LocalDevVPN 和调试权限后重试。";
        SSCancelMainHelper(receiver, error);
        return error;
    }
    if (!receiver.finished) [receiver record:@"running" error:nil];
    // SSActiveSessions retains the receiver/listener until the actual script
    // result. The main process proceeds into the guest without any restart.
    return nil;
}

@interface SSStikDebugChildReply : NSObject
@property(strong) NSXPCConnection *connection;
@property(strong) NSURL *pairingURL;
@property BOOL finished;
@end
@implementation SSStikDebugChildReply
- (void)progress:(NSString *)message { [[self.connection remoteObjectProxy] reportProgress:message]; }
- (void)complete:(NSDictionary *)result {
    if (self.pairingURL) [NSFileManager.defaultManager removeItemAtURL:self.pairingURL error:nil];
    __weak typeof(self) weakSelf = self;
    id<SSStikDebugHelperHost> proxy = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) { weakSelf.finished = YES; }];
    [proxy reportResult:result withReply:^{ weakSelf.finished = YES; }];
}
@end

__attribute__((visibility("default")))
int SSStikDebugHelperMain(int argc, char **argv, char **envp, char **apple) {
    @autoreleasepool {
        NSDictionary *info = SSClassValue(@"LiveProcessHandler", @"retrievedAppInfo");
        NSExtensionContext *context = SSClassValue(@"LiveProcessHandler", @"extensionContext");
        NSXPCListenerEndpoint *endpoint = info[@"SSStikDebugEndpoint"];
        if (!endpoint) return 1;
        SSStikDebugChildReply *reply = [SSStikDebugChildReply new];
        reply.connection = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
        reply.connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SSStikDebugHelperHost)];
        __weak SSStikDebugChildReply *weakReply = reply;
        reply.connection.invalidationHandler = ^{ weakReply.finished = YES; };
        [reply.connection resume];
        NSMutableDictionary *request = [info[@"SSStikDebugRequest"] mutableCopy];
        NSError *error;
        if (request[@"pairingData"]) {
            reply.pairingURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
            NSData *pairing = request[@"pairingData"];
            if (![pairing writeToURL:reply.pairingURL options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:&error]) {
                [reply complete:SSFailure(error.localizedDescription)];
            } else {
                [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:reply.pairingURL.path error:nil];
                request[@"pairingPath"] = reply.pairingURL.path;
            }
            [request removeObjectForKey:@"pairingData"];
        }
        if (!error) {
            request[@"reply"] = reply;
            id core = SSClassValue(@"SSStikDebugCore", @"shared");
            SSReply(core, @"execute:", request);
        }
        while (!reply.finished) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
        if (reply.pairingURL) [NSFileManager.defaultManager removeItemAtURL:reply.pairingURL error:nil];
        [reply.connection invalidate];
        [context completeRequestReturningItems:@[] completionHandler:nil];
        return 0;
    }
}

NSDictionary *SSStikDebugContainerApps(NSDictionary *request) {
    NSString *home = request[@"hostHome"];
    if (![home isKindOfClass:NSString.class] || !home.isAbsolutePath) return SSFailure(@"无法确定 LiveContainer 主目录。请在二合一主实例中操作。");
    NSURL *privateApps = [NSURL fileURLWithPath:[home stringByAppendingPathComponent:@"Documents/Applications"]];
    NSURL *group = SSClassValue(@"LCSharedUtils", @"appGroupPath");
    NSMutableArray *roots = [NSMutableArray arrayWithObject:privateApps];
    if (group) [roots addObject:[group URLByAppendingPathComponent:@"LiveContainer/Applications"]];
    NSMutableArray *apps = [NSMutableArray new];
    for (NSURL *root in roots) {
        for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
            if (![url.pathExtension isEqual:@"app"]) continue;
            NSDictionary *config = [NSDictionary dictionaryWithContentsOfURL:[url URLByAppendingPathComponent:@"LCAppInfo.plist"]];
            if ((config[@"isHidden"] && ![config[@"isHidden"] isKindOfClass:NSNumber.class]) ||
                (config[@"isLocked"] && ![config[@"isLocked"] isKindOfClass:NSNumber.class])) continue;
            if ([config[@"isHidden"] boolValue] || [config[@"isLocked"] boolValue]) continue;
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[url URLByAppendingPathComponent:@"Info.plist"]];
            NSString *identifier = info[@"CFBundleIdentifier"];
            if (![identifier isKindOfClass:NSString.class]) continue;
            NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: identifier;
            if (![name isKindOfClass:NSString.class]) name = identifier;
            [apps addObject:@{ @"name": name, @"bundleID": identifier,
                @"folderName": url.lastPathComponent, @"source": @"container",
                @"shared": [root isEqual:privateApps] ? @"false" : @"true" }];
        }
    }
    return @{ @"apps": apps };
}

NSDictionary *SSStikDebugLaunchContainer(NSDictionary *request) {
    NSString *folder = request[@"folderName"];
    NSArray *apps = SSStikDebugContainerApps(request)[@"apps"];
    BOOL found = NO;
    for (NSDictionary *app in apps) if ([app[@"folderName"] isEqual:folder] && [app[@"shared"] isEqual:request[@"shared"]]) { found = YES; break; }
    if (!found) return SSFailure(@"容器 App 已不存在或不可见，请重新读取列表。");
    NSUserDefaults *defaults = SSClassValue(@"NSUserDefaults", @"lcUserDefaults");
    Class utilities = NSClassFromString(@"LCSharedUtils");
    if (!defaults || !utilities) return SSFailure(@"当前实例无法切换到 LiveContainer。");
    [defaults setObject:@{ @"folderName": folder, @"shared": request[@"shared"] } forKey:@"SSBuiltInJITPendingContainer"];
    [defaults setObject:@"ui" forKey:@"selected"];
    [defaults removeObjectForKey:@"selectedContainer"];
    [defaults removeObjectForKey:@"launchAppUrlScheme"];
    [defaults setBool:NO forKey:@"LCOpenSideStore"];
    BOOL result = ((BOOL (*)(id, SEL, NSUInteger))objc_msgSend)(utilities, NSSelectorFromString(@"launchToGuestAppWithClassicMode:"), 0);
    return result ? @{} : SSFailure(@"切换到 LiveContainer 失败。");
}
