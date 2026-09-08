#import "RelayDelivery.h"
#import "RelayDiagnostics.h"

NSString *RelayParseCommand(NSString *text) {
    if (!text) return nil;
    NSRange line = [text rangeOfString:@"\n"];
    if (line.location == NSNotFound) return nil;
    NSString *first = [text substringToIndex:line.location];
    if ([first hasSuffix:@"\r"]) first = [first substringToIndex:first.length - 1];
    if (![first isEqualToString:@"# CHATGPT_RUN"]) return nil;
    NSString *command = [[text substringFromIndex:NSMaxRange(line)]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return command.length ? command : nil;
}
static NSString *RelayDataDirectory(void) {
#ifdef RELAY_TESTING
    const char *testDirectory = getenv("RELAY_TEST_DATA_DIR");
    if (testDirectory) return [NSString stringWithUTF8String:testDirectory];
#endif
    NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *path = [base stringByAppendingPathComponent:@"ChatGPT Terminal Relay"];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:nil];
    return path;
}
NSString *RelaySavedResultPath(void) { return [RelayDataDirectory() stringByAppendingPathComponent:@"last-result.txt"]; }
NSString *RelayLogDirectory(void) {
    NSString *path = [RelayDataDirectory() stringByAppendingPathComponent:@"Logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:nil];
    return path;
}
static NSString *Normalize(NSString *text) {
    return [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
}

@interface RelayDelivery ()
@property id<RelayTarget> target;
@property BOOL cancelled;
@property BOOL finished;
@property(copy) void (^completion)(BOOL, NSString *);
@end
@implementation RelayDelivery
- (instancetype)initWithTarget:(id<RelayTarget>)target {
    if ((self = [super init])) _target = target;
    return self;
}
- (void)finish:(BOOL)sent reason:(NSString *)reason {
    if (self.finished) return;
    self.finished = YES;
    RelayLog(@"delivery_completed", @{@"sent":@(sent), @"reason":reason});
    void (^callback)(BOOL, NSString *) = self.completion;
    self.completion = nil;
    if (callback) callback(sent, reason);
}
- (void)cancel { self.cancelled = YES; [self finish:NO reason:@"已停止回傳"]; }
- (void)deliver:(NSString *)text completion:(void (^)(BOOL, NSString *))completion {
    self.completion = completion;
    RelayLog(@"delivery_started", @{@"result_characters":@(text.length)});
    if (self.cancelled || !text.length || ![self.target isValid]) {
        [self finish:NO reason:@"無法確認 ChatGPT 輸入框"]; return;
    }
    NSString *current = [self.target readText];
    if (!current || (current.length && ![Normalize(current) isEqualToString:Normalize(text)])) {
        [self finish:NO reason:@"輸入框已有草稿或無法讀取"]; return;
    }
    if (!current.length && ![self.target writeText:text]) {
        [self finish:NO reason:@"無法填入 ChatGPT 輸入框"]; return;
    }
    [self verify:text attempt:0];
}
- (void)verify:(NSString *)text attempt:(NSInteger)attempt {
    if (self.finished) return;
    if (self.cancelled || ![self.target isValid]) {
        [self finish:NO reason:@"目標視窗已變更，已暫停回傳"]; return;
    }
    NSString *current = [self.target readText];
    BOOL matches = current && [Normalize(current) isEqualToString:Normalize(text)];
    RelayLog(@"delivery_readback", @{@"attempt":@(attempt), @"readable":@(current != nil), @"characters":@(current.length), @"matches_result":@(matches)});
    if (!current || (current.length && !matches)) {
        [self finish:NO reason:@"輸入內容已變更，已暫停回傳"]; return;
    }
    if (matches && [self.target canSend]) {
        // The adapter repeats target/content checks and invokes the specific button.
        BOOL sent = [self.target sendText:text];
        [self finish:sent reason:sent ? @"已交付傳送" : @"無法確認傳送，請先查看 ChatGPT"];
        return;
    }
    if (attempt >= 24) { [self finish:NO reason:@"ChatGPT 尚未就緒，請稍後重試"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ [self verify:text attempt:attempt + 1]; });
}
@end

static id Attr(AXUIElementRef element, CFStringRef attribute) {
    if (!element) return nil;
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (error != kAXErrorSuccess) {
        if (CFEqual(attribute, kAXFocusedWindowAttribute) || CFEqual(attribute, kAXValueAttribute))
            RelayLog(@"ax_read_failed", @{@"attribute":(__bridge NSString *)attribute, @"ax_error":@(error)});
        return nil;
    }
    return CFBridgingRelease(value);
}
static BOOL Settable(AXUIElementRef element, CFStringRef attribute) {
    Boolean result = false;
    return AXUIElementIsAttributeSettable(element, attribute, &result) == kAXErrorSuccess && result;
}
static NSArray *Descendants(AXUIElementRef root) {
    NSMutableArray *queue = [NSMutableArray arrayWithObject:(__bridge id)root];
    // Bound traversal when another app supplies an unusually large/broken AX tree.
    for (NSUInteger i = 0; i < queue.count && queue.count < 3000; i++) {
        NSArray *children = Attr((__bridge AXUIElementRef)queue[i], kAXChildrenAttribute);
        if ([children isKindOfClass:NSArray.class]) {
            for (id child in children) {
                if (queue.count >= 3000) break;
                if (![queue containsObject:child]) [queue addObject:child];
            }
        }
    }
    return queue;
}

@interface RelayAXTarget ()
@property pid_t pid;
@property id appElement;
@property id window;
@property id editor;
@property NSString *windowTitle;
@property NSString *expectedText;
@property id sendButton;
@end
@implementation RelayAXTarget
- (instancetype)initWithPID:(pid_t)pid {
    if (!(self = [super init])) return nil;
    _pid = pid;
    _appElement = CFBridgingRelease(AXUIElementCreateApplication(pid));
    AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)_appElement, 0.5);
    _window = Attr((__bridge AXUIElementRef)_appElement, kAXFocusedWindowAttribute);
    if (!_window) { RelayLog(@"target_window_missing", @{@"target_pid":@(pid), @"trusted":@(AXIsProcessTrusted())}); return self; }
    _windowTitle = Attr((__bridge AXUIElementRef)_window, kAXTitleAttribute) ?: @"";
    NSSet *composerNames = [NSSet setWithArray:@[@"Message ChatGPT", @"Ask anything", @"Send a message", @"Message", @"訊息", @"傳送訊息給 ChatGPT", @"向 ChatGPT 傳送訊息", @"詢問任何問題", @"向 ChatGPT 发送消息"]];
    NSMutableArray *eligible = [NSMutableArray new];
    NSMutableArray *editors = [NSMutableArray new];
    NSMutableArray *identified = [NSMutableArray new];
    NSArray *nodes = Descendants((__bridge AXUIElementRef)_window);
    NSUInteger textAreas = 0, writableAreas = 0;
    for (id node in nodes) {
        AXUIElementRef e = (__bridge AXUIElementRef)node;
        if (![Attr(e, kAXRoleAttribute) isEqual:(__bridge id)kAXTextAreaRole]) continue;
        textAreas++;
        if (!Settable(e, kAXValueAttribute)) continue;
        writableAreas++;
        if ([Attr(e, kAXEnabledAttribute) isEqual:@NO]) continue;
        if (![Attr(e, kAXValueAttribute) isKindOfClass:NSString.class]) continue;
        [eligible addObject:node];
        NSString *name = Attr(e, kAXDescriptionAttribute) ?: @"";
        NSString *placeholder = Attr(e, CFSTR("AXPlaceholderValue")) ?: @"";
        if ([composerNames containsObject:name] || [composerNames containsObject:placeholder]) [editors addObject:node];
        NSString *identifier = Attr(e, kAXIdentifierAttribute);
        if ([identifier isEqualToString:@"prompt-textarea"]) [identified addObject:node];
    }
    // ChatGPT's composer name/identifier varies by app build and language.
    // A sole eligible text area is unambiguous even when those labels are unfamiliar.
    NSString *selection = @"none";
    if (identified.count == 1) { _editor = identified.firstObject; selection = @"identifier"; }
    else if (identified.count == 0 && editors.count == 1) { _editor = editors.firstObject; selection = @"name"; }
    else if (identified.count == 0 && editors.count == 0 && eligible.count == 1) {
        _editor = eligible.firstObject; selection = @"unique_writable_text_area";
    }
    RelayLog(@"editor_discovery", @{@"target_pid":@(pid), @"nodes":@(nodes.count), @"text_areas":@(textAreas), @"writable_text_areas":@(writableAreas), @"matching_names":@(editors.count), @"matching_identifiers":@(identified.count), @"selected":@(_editor != nil), @"selection":selection, @"eligible":@(eligible.count)});
    return self;
}
- (BOOL)isValid {
    pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    if (!self.editor || !self.window || front != self.pid) {
        RelayLog(@"target_invalid", @{@"has_editor":@(self.editor != nil), @"has_window":@(self.window != nil), @"target_pid":@(self.pid), @"frontmost_pid":@(front)});
        return NO;
    }
    id currentWindow = Attr((__bridge AXUIElementRef)self.appElement, kAXFocusedWindowAttribute);
    if (!currentWindow || !CFEqual((__bridge CFTypeRef)self.window, (__bridge CFTypeRef)currentWindow)) {
        RelayLog(@"target_invalid", @{@"reason":@"focused_window_changed"}); return NO;
    }
    if (![self.windowTitle isEqual:Attr((__bridge AXUIElementRef)self.window, kAXTitleAttribute) ?: @""]) {
        RelayLog(@"target_invalid", @{@"reason":@"window_title_changed"}); return NO;
    }
    id parent = self.editor;
    for (int i = 0; parent && i < 40; i++) {
        if (CFEqual((__bridge CFTypeRef)parent, (__bridge CFTypeRef)self.window)) return YES;
        parent = Attr((__bridge AXUIElementRef)parent, kAXParentAttribute);
    }
    return NO;
}
- (NSString *)readText {
    id value = Attr((__bridge AXUIElementRef)self.editor, kAXValueAttribute);
    return [value isKindOfClass:NSString.class] ? value : nil;
}
- (BOOL)writeText:(NSString *)text {
    if (![self isValid] || [self readText].length) return NO;
    self.expectedText = text;
    // Directly address the editor: no shared clipboard and no global keystrokes.
    AXError error = AXUIElementSetAttributeValue((__bridge AXUIElementRef)self.editor, kAXValueAttribute, (__bridge CFTypeRef)text);
    RelayLog(@"editor_write", @{@"ax_error":@(error), @"characters":@(text.length)});
    return error == kAXErrorSuccess;
}
- (BOOL)canSend {
    if (![self isValid]) return NO;
    NSSet *labels = [NSSet setWithArray:@[@"Send", @"Send message", @"Send prompt", @"傳送", @"傳送訊息", @"傳送提示", @"送出", @"发送", @"发送消息", @"发送提示"]];
    NSMutableArray *matches = [NSMutableArray new];
    for (id node in Descendants((__bridge AXUIElementRef)self.window)) {
        AXUIElementRef e = (__bridge AXUIElementRef)node;
        if (![Attr(e, kAXRoleAttribute) isEqual:(__bridge id)kAXButtonRole] || ![Attr(e, kAXEnabledAttribute) isEqual:@YES]) continue;
        NSString *title = Attr(e, kAXTitleAttribute) ?: @"";
        NSString *desc = Attr(e, kAXDescriptionAttribute) ?: @"";
        if (![labels containsObject:title] && ![labels containsObject:desc]) continue;
        CFArrayRef actions = NULL;
        if (AXUIElementCopyActionNames(e, &actions) == kAXErrorSuccess) {
            if ([(__bridge NSArray *)actions containsObject:(__bridge NSString *)kAXPressAction]) [matches addObject:node];
            CFRelease(actions);
        }
    }
    self.sendButton = matches.count == 1 ? matches.firstObject : nil;
    RelayLog(@"send_button_discovery", @{@"matches":@(matches.count), @"selected":@(self.sendButton != nil)});
    return self.sendButton != nil;
}
- (BOOL)sendText:(NSString *)text {
    if (![self isValid] || !self.sendButton || ![Normalize([self readText]) isEqualToString:Normalize(text)]) return NO;
    AXError error = AXUIElementPerformAction((__bridge AXUIElementRef)self.sendButton, kAXPressAction);
    RelayLog(@"send_button_invoked", @{@"ax_error":@(error)});
    return error == kAXErrorSuccess;
}
@end
