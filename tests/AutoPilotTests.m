#import "../src/RelayAutoPilot.h"
#import "../src/RelayAuthorization.h"

@interface AutoFixture : NSObject <RelayAutoSource>
@property RelayAutoSnapshot *current;
@property NSString *text;
@property NSInteger changes;
@property NSUInteger copies;
@property BOOL axNoOp;
@property BOOL mouseNoOp;
@property NSUInteger clicks;
@end
@implementation AutoFixture
- (instancetype)init {
    if ((self = [super init])) {
        _current = [RelayAutoSnapshot new]; _current.available = YES; _current.idle = YES;
        _current.windowTitle = @"Project A"; _current.responseCopyButton = @"old";
        _text = @"Purpose\n```zsh\n# CHATGPT_RUN\nprintf ok\n```\n";
    }
    return self;
}
- (RelayAutoSnapshot *)snapshot { return self.current; }
- (BOOL)copyResponse:(id)button windowTitle:(NSString *)title { self.copies++; if (!self.axNoOp) self.changes++; return YES; }
- (BOOL)clickResponse:(id)button windowTitle:(NSString *)title stillActive:(BOOL (^)(void))active {
    if (!active()) return NO;
    self.clicks++; if (!self.mouseNoOp) self.changes++; return YES;
}
- (NSInteger)clipboardChangeCount { return self.changes; }
- (NSString *)clipboardText { return self.text; }
@end
@interface RelayAutoPilot (StressHarness)
- (void)acceptSnapshot:(RelayAutoSnapshot *)snapshot generation:(NSUInteger)generation;
- (void)awaitClipboard:(NSInteger)before attempt:(NSUInteger)attempt generation:(NSUInteger)generation;
@end
static int passed;
static void Check(BOOL condition, const char *name) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", name); exit(1); }
    printf("PASS: %s\n", name); passed++;
}
static void Pump(void) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:0.06];
    while (end.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static void Tick(RelayAutoPilot *pilot, int count) { for (int i = 0; i < count; i++) { [pilot poll]; Pump(); } }
int main(void) {
    @autoreleasepool {
        Check([RelayCommandFromResponse(@"# CHATGPT_RUN\nprintf ok") isEqual:@"printf ok"], "direct copied code is accepted");
        Check([RelayCommandFromResponse(@"Purpose\n```zsh\n# CHATGPT_RUN\nprintf ok\n```\n") isEqual:@"printf ok"], "whole assistant response yields one complete command");
        Check(!RelayCommandFromResponse(@"Purpose\n```zsh\n# CHATGPT_RUN\nprintf incomplete"), "unfinished Markdown fence is rejected");
        Check(!RelayCommandFromResponse(@"```zsh\n# CHATGPT_RUN\necho one\n```\n```zsh\n# CHATGPT_RUN\necho two\n```"), "multiple blocks never execute automatically");
        Check(!RelayCommandFromResponse(@"Task completed."), "completion prose is not a command");
        AutoFixture *source = [AutoFixture new];
        RelayAutoPilot *pilot = [[RelayAutoPilot alloc] initWithSource:source];
        __block int commands = 0;
        [pilot startWithCommand:^(NSString *command) { commands++; } status:^(NSString *status) {}];
        Pump(); Tick(pilot, 4);
        Check(commands == 0 && source.copies == 0, "enabling auto mode does not replay old responses");
        source.current.generating = YES; source.current.idle = NO; source.current.responseCopyButton = @"new";
        Tick(pilot, 5);
        Check(commands == 0 && source.copies == 0, "streaming response is not copied or executed");
        source.current.generating = NO; source.current.idle = YES;
        Tick(pilot, 4);
        Check(commands == 1 && source.copies == 1, "completed response is copied and dispatched automatically");
        Tick(pilot, 5);
        Check(commands == 1, "same completed response is dispatched once");
        source.current.generating = YES; source.current.idle = NO; Tick(pilot, 1);
        source.current.generating = NO; source.current.idle = YES; Tick(pilot, 4);
        Check(commands == 1, "spurious busy cycle cannot replay the same copied response");
        source.current.responseCopyButton = @"next"; Tick(pilot, 4);
        Check(commands == 2, "a new response may intentionally repeat a command");
        [pilot suspend]; source.current.responseCopyButton = @"during-shell"; Tick(pilot, 4);
        Check(commands == 2, "no automatic copy while a command is in progress");
        [pilot resume]; source.current.windowTitle = @"Different conversation"; Tick(pilot, 2);
        Check(!pilot.enabled && commands == 2, "conversation switch stops automatic execution");
        [pilot stop]; Tick(pilot, 2); Check(commands == 2, "stopped mode never dispatches");

        source = [AutoFixture new]; pilot = [[RelayAutoPilot alloc] initWithSource:source];
        [pilot startWithCommand:^(NSString *command) { commands++; } status:^(NSString *status) {}]; Pump();
        source.text = @"Task is complete."; source.current.responseCopyButton = @"completion"; Tick(pilot, 4);
        Check(!pilot.enabled && commands == 2, "no-command final answer ends the loop");

        source = [AutoFixture new]; source.axNoOp = YES;
        pilot = [[RelayAutoPilot alloc] initWithSource:source];
        __block int fallbackCommands = 0;
        [pilot startWithCommand:^(NSString *command) { fallbackCommands++; } status:^(NSString *status) {}]; Pump();
        source.current.responseCopyButton = @"ax-noop-response"; Tick(pilot, 4);
        Check(source.copies == 1 && fallbackCommands == 0, "AX success without clipboard update is not counted as a copy");
        [pilot awaitClipboard:0 attempt:20 generation:[[pilot valueForKey:@"generation"] unsignedIntegerValue]];
        Pump();
        Check(source.clicks == 1 && fallbackCommands == 1, "no-op AX action falls back to a verified mouse click");
        Tick(pilot, 3);
        Check(source.clicks == 1 && fallbackCommands == 1, "mouse fallback dispatches once despite old polling callbacks");
        [pilot stop];

        source = [AutoFixture new]; source.axNoOp = YES; source.mouseNoOp = YES;
        pilot = [[RelayAutoPilot alloc] initWithSource:source];
        [pilot startWithCommand:^(NSString *command) { fallbackCommands++; } status:^(NSString *status) {}]; Pump();
        source.current.responseCopyButton = @"both-noop"; Tick(pilot, 4);
        NSUInteger noopGeneration = [[pilot valueForKey:@"generation"] unsignedIntegerValue];
        [pilot awaitClipboard:0 attempt:20 generation:noopGeneration]; Pump();
        [pilot awaitClipboard:0 attempt:20 generation:noopGeneration]; Pump();
        Check(!pilot.enabled && fallbackCommands == 1 && source.clicks == 1, "failed physical copy stops without executing or clicking repeatedly");

        NSString *state = [[NSString stringWithUTF8String:getenv("RELAY_TEST_DATA_DIR")] stringByAppendingPathComponent:@"auth-test.json"];
        __block int resets = 0;
        Check(RelayPrepareAuthorization(@"build-a", state, ^BOOL { resets++; return YES; }) && resets == 1, "first installed build clears old authorization");
        Check(RelayPrepareAuthorization(@"build-a", state, ^BOOL { resets++; return YES; }) && resets == 1, "same build restart does not erase fresh authorization");
        Check(RelayPrepareAuthorization(@"build-b", state, ^BOOL { resets++; return YES; }) && resets == 2, "updated build clears old authorization again");
        Check(!RelayPrepareAuthorization(@"build-c", state, ^BOOL { resets++; return NO; }), "failed permission reset is not marked successful");
        Check(RelayPrepareAuthorization(@"build-c", state, ^BOOL { resets++; return YES; }) && resets == 4, "failed reset is retried on the next launch");
        source = [AutoFixture new]; pilot = [[RelayAutoPilot alloc] initWithSource:source];
        __block int stressCommands = 0;
        [pilot startWithCommand:^(NSString *command) { stressCommands++; } status:^(NSString *status) {}]; Pump();
        NSUInteger generation = [[pilot valueForKey:@"generation"] unsignedIntegerValue];
        for (int round = 1; round <= 1000; round++) {
            @autoreleasepool {
                source.current.generating = YES; source.current.idle = NO;
                source.current.responseCopyButton = [NSString stringWithFormat:@"response-%d", round];
                source.text = [NSString stringWithFormat:@"Round %d\n```zsh\n# CHATGPT_RUN\nprintf 'ROUND_%04d\\n'\n```\n", round, round];
                [pilot acceptSnapshot:source.current generation:generation];
                source.current.generating = NO; source.current.idle = YES;
                for (int stable = 0; stable < 3; stable++) [pilot acceptSnapshot:source.current generation:generation];
                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
                while (stressCommands < round && deadline.timeIntervalSinceNow > 0)
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
                if (stressCommands != round) { fprintf(stderr, "Stress failed at round %d\n", round); return 1; }
                [pilot acceptSnapshot:source.current generation:generation];
                if (stressCommands != round) return 1;
                if (round % 100 == 0) printf("SIMULATED_ROUNDS: %d\n", round);
            }
        }
        Check(stressCommands == 1000 && source.copies == 1000, "1000 simulated responses dispatch exactly 1000 commands");
        source.current.responseCopyButton = @"finished"; source.text = @"RELAY_DONE: 1000_ROUNDS_OK";
        for (int stable = 0; stable < 3; stable++) [pilot acceptSnapshot:source.current generation:generation];
        Pump();
        Check(!pilot.enabled && stressCommands == 1000, "1000-round loop stops on completion without an extra execution");
        printf("%d auto-loop and authorization tests passed\n", passed);
    }
    return 0;
}
