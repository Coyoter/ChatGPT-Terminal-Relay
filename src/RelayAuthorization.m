#import "RelayAuthorization.h"
#import "RelayDiagnostics.h"
#import <CommonCrypto/CommonDigest.h>

BOOL RelayPrepareAuthorization(NSString *fingerprint, NSString *statePath, BOOL (^reset)(void)) {
    if (!fingerprint.length) return NO;
    NSData *saved = [NSData dataWithContentsOfFile:statePath];
    id state = saved ? [NSJSONSerialization JSONObjectWithData:saved options:0 error:nil] : nil;
    if ([state isKindOfClass:NSDictionary.class] && [state[@"fingerprint"] isEqual:fingerprint]) {
        RelayLog(@"authorization_build_unchanged", @{});
        return YES;
    }
    RelayLog(@"authorization_reset_started", @{@"reason":@"new_or_changed_installed_build"});
    if (!reset()) { RelayLog(@"authorization_reset_failed", @{}); return NO; }
    NSData *record = [NSJSONSerialization dataWithJSONObject:@{@"fingerprint":fingerprint} options:0 error:nil];
    BOOL savedOK = [record writeToFile:statePath atomically:YES];
    if (savedOK) [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:statePath error:nil];
    RelayLog(@"authorization_reset_completed", @{@"state_saved":@(savedOK)});
    return savedOK;
}
BOOL RelayEnsureAuthorizationForInstalledBuild(void) {
    NSData *binary = [NSData dataWithContentsOfFile:NSBundle.mainBundle.executablePath];
    if (!binary.length || binary.length > UINT32_MAX) return NO;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(binary.bytes, (CC_LONG)binary.length, hash);
    NSMutableString *digest = [NSMutableString new];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [digest appendFormat:@"%02x", hash[i]];
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    NSString *fingerprint = [NSString stringWithFormat:@"%@|%@|%@", version, digest, NSBundle.mainBundle.bundlePath];
    NSString *statePath = [[RelayDiagnosticsPath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"authorization-build.json"];
    return RelayPrepareAuthorization(fingerprint, statePath, ^BOOL {
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/tccutil"];
        // Reset only Relay's accessibility grant, never every app or any other permission.
        task.arguments = @[@"reset", @"Accessibility", @"com.coyoter.chatgpt-terminal-relay"];
        task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
        task.standardError = NSFileHandle.fileHandleWithNullDevice;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        task.terminationHandler = ^(NSTask *ended) { dispatch_semaphore_signal(done); };
        NSError *error = nil;
        if (![task launchAndReturnError:&error]) { RelayLog(@"authorization_reset_launch_failed", @{@"code":@(error.code)}); return NO; }
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
            if (task.running) [task terminate];
            RelayLog(@"authorization_reset_timeout", @{}); return NO;
        }
        RelayLog(@"authorization_reset_process", @{@"exit_code":@(task.terminationStatus)});
        return task.terminationStatus == 0;
    });
}
