#import "../src/RelayDelivery.h"
#define AXIsProcessTrusted() YES
#define main RelayOriginalMain
#import "../src/Relay.m"
#undef main
#undef AXIsProcessTrusted

@interface FakeTarget : NSObject <RelayTarget>
@property BOOL valid;
@property BOOL writable;
@property BOOL ready;
@property BOOL changeAfterWrite;
@property BOOL blurAfterWrite;
@property NSString *text;
@property int writes;
@property int sends;
@end
@implementation FakeTarget
- (instancetype)init { if ((self = [super init])) { _valid = YES; _writable = YES; _ready = YES; _text = @""; } return self; }
- (BOOL)isValid { return self.valid; }
- (NSString *)readText { return self.text; }
- (BOOL)writeText:(NSString *)text { self.writes++; if (!self.writable) return NO; self.text = self.changeAfterWrite ? @"user changed draft" : text; if (self.blurAfterWrite) self.valid = NO; return YES; }
- (BOOL)canSend { return self.ready; }
- (BOOL)sendText:(NSString *)text { if (!self.valid || ![self.text isEqualToString:text]) return NO; self.sends++; return YES; }
@end
@interface PendingDelegate : RelayAppDelegate
@property(copy) void (^lookup)(NSRunningApplication *);
@end
@implementation PendingDelegate
- (void)updateStatus:(NSString *)status {}
- (void)findOrLaunchChatGPTWithAttempt:(NSInteger)attempt completion:(void (^)(NSRunningApplication *))completion { self.lookup = completion; }
@end
static int passed = 0;
static void Check(BOOL value, NSString *name) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", name.UTF8String); exit(1); }
    printf("PASS: %s\n", name.UTF8String); passed++;
}
static void Pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static BOOL Deliver(FakeTarget *target) {
    __block BOOL sent = NO;
    RelayDelivery *d = [[RelayDelivery alloc] initWithTarget:target];
    [d deliver:@"result" completion:^(BOOL success, NSString *reason) { sent = success; }];
    return sent;
}
int main(void) {
    @autoreleasepool {
        Check([RelayParseCommand(@"# CHATGPT_RUN\nprintf hello") isEqual:@"printf hello"], @"LF marker");
        Check([RelayParseCommand(@"# CHATGPT_RUN\r\nprintf hello") isEqual:@"printf hello"], @"CRLF marker");
        Check(!RelayParseCommand(@"# CHATGPT_RUN echo no"), @"reject inline marker");
        Check(!RelayParseCommand(@"# CHATGPT_RUNNING\necho no"), @"reject marker prefix");
        Check(!RelayParseCommand(@"# CHATGPT_RUN\n  "), @"reject empty command");
        FakeTarget *t = [FakeTarget new];
        Check(Deliver(t) && t.sends == 1 && t.writes == 1, @"deliver exact result once");
        t = [FakeTarget new]; t.valid = NO;
        Check(!Deliver(t) && !t.sends && !t.writes, @"wrong foreground prevents every write");
        t = [FakeTarget new]; t.text = @"existing draft";
        Check(!Deliver(t) && !t.sends && !t.writes, @"preserve user draft");
        t = [FakeTarget new]; t.changeAfterWrite = YES;
        Check(!Deliver(t) && !t.sends, @"changed content never sent");
        t = [FakeTarget new]; t.blurAfterWrite = YES;
        Check(!Deliver(t) && !t.sends, @"focus change after write never sent");
        t = [FakeTarget new]; t.writable = NO;
        Check(!Deliver(t) && !t.sends, @"inaccessible editor fails safely");
        t = [FakeTarget new]; t.text = @"result";
        Check(Deliver(t) && !t.writes && t.sends == 1, @"explicit retry does not duplicate text");
        t = [FakeTarget new]; t.ready = NO;
        RelayDelivery *d = [[RelayDelivery alloc] initWithTarget:t];
        __block int callbacks = 0;
        [d deliver:@"result" completion:^(BOOL sent, NSString *reason) { callbacks++; }];
        [d cancel]; t.ready = YES; Pump(0.25);
        Check(!t.sends && callbacks == 1, @"cancel pending delivery and callback once");
        t = [FakeTarget new]; t.ready = NO;
        d = [[RelayDelivery alloc] initWithTarget:t];
        [d deliver:@"result" completion:^(BOOL sent, NSString *reason) {}];
        t.ready = YES; Pump(0.25);
        Check(t.sends == 1, @"wait for ready send button");
        PendingDelegate *pending = [PendingDelegate new];
        pending.monitoring = YES; pending.executing = YES; pending.lastResult = @"result";
        [pending beginReturn];
        [pending stopMonitoring:nil];
        Check(!pending.executing, @"stop during app lookup releases pending return");
        pending.monitoring = YES; pending.executing = YES;
        pending.lookup(nil);
        Check(pending.executing, @"stale lookup cannot alter newer operation after restart");
        RelayAppDelegate *app = [RelayAppDelegate new];
        NSDictionary *r = [app runShellCommand:@"printf 'out\\n'; printf 'err\\n' >&2; exit 7"];
        Check([r[@"exitCode"] intValue] == 7 && [r[@"output"] isEqual:@"out\nerr\n"], @"real zsh stdout stderr exit");
        r = [app runShellCommand:@"printf '繁體中文 😀\\n'"];
        Check([r[@"output"] isEqual:@"繁體中文 😀\n"], @"real zsh Unicode");
        r = [app runShellCommand:@"/usr/bin/head -c 2097152 /dev/zero | /usr/bin/tr '\\000' A"];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:r[@"logPath"] error:nil];
        Check([r[@"output"] length] < 66000 && [attrs[NSFileSize] unsignedLongLongValue] == 2097152, @"bounded preview and complete 2MiB log");
        r = [app runShellCommand:@"/usr/bin/head -c 65535 /dev/zero | /usr/bin/tr '\\000' A; printf '中😀尾'"];
        Check([r[@"output"] characterAtIndex:65535] == '\n', @"UTF8 preview boundary never corrupts valid text");
        RelayLog(@"diagnostic_test", @{@"trusted":@NO, @"note":@"換行\n測試"});
        NSString *diagnostics = [NSString stringWithContentsOfFile:RelayDiagnosticsPath() encoding:NSUTF8StringEncoding error:nil];
        BOOL validJSON = YES;
        for (NSString *line in [diagnostics componentsSeparatedByString:@"\n"]) {
            if (!line.length) continue;
            NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if (!entry[@"event"] || !entry[@"timestamp"] || !entry[@"pid"]) validJSON = NO;
        }
        Check(validJSON && [diagnostics containsString:@"diagnostic_test"], @"diagnostics are valid JSON lines with metadata");
        Check(![diagnostics containsString:@"existing draft"] && ![diagnostics containsString:@"user changed draft"], @"diagnostics omit editor contents");
        [[NSMutableData dataWithLength:1048576] writeToFile:RelayDiagnosticsPath() atomically:YES];
        RelayLog(@"rotation_test", @{});
        Check([[NSFileManager defaultManager] fileExistsAtPath:[RelayDiagnosticsPath() stringByAppendingString:@".previous"]] &&
              [[[NSFileManager defaultManager] attributesOfItemAtPath:RelayDiagnosticsPath() error:nil][NSFileSize] unsignedLongLongValue] < 2048, @"diagnostics rotate at 1MiB");
        printf("%d tests passed\n", passed);
    }
    return 0;
}
