#import "RelayDiagnostics.h"

NSString *RelayDiagnosticsPath(void) {
#ifdef RELAY_TESTING
    const char *testRoot = getenv("RELAY_TEST_DATA_DIR");
    if (testRoot) return [[NSString stringWithUTF8String:testRoot] stringByAppendingPathComponent:@"diagnostics.jsonl"];
#endif
    NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *directory = [base stringByAppendingPathComponent:@"ChatGPT Terminal Relay"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:nil];
    return [directory stringByAppendingPathComponent:@"diagnostics.jsonl"];
}

void RelayLog(NSString *event, NSDictionary *fields) {
    // Logging failures must never interrupt clipboard monitoring or command execution.
    @synchronized ([NSProcessInfo class]) {
        @try {
            NSMutableDictionary *record = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
            record[@"event"] = event;
            record[@"timestamp"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
            record[@"pid"] = @(NSProcessInfo.processInfo.processIdentifier);
            NSData *json = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
            if (!json) return;
            NSMutableData *line = [json mutableCopy];
            [line appendBytes:"\n" length:1];
            NSString *path = RelayDiagnosticsPath();
            NSFileManager *fm = NSFileManager.defaultManager;
            if ([[fm attributesOfItemAtPath:path error:nil][NSFileSize] unsignedLongLongValue] + line.length > 1048576) {
                NSString *previous = [path stringByAppendingString:@".previous"];
                [fm removeItemAtPath:previous error:nil];
                [fm moveItemAtPath:path toPath:previous error:nil];
            }
            if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:@{NSFilePosixPermissions:@0600}];
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            [handle seekToEndOfFile];
            [handle writeData:line];
            [handle closeFile];
        } @catch (NSException *exception) {
            NSLog(@"[Relay] Diagnostic log unavailable (%@)", exception.name);
        }
    }
}
