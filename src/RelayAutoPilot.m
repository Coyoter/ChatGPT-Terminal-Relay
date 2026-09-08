#import "RelayAutoPilot.h"
#import "RelayDelivery.h"
#import "RelayDiagnostics.h"
#import <ApplicationServices/ApplicationServices.h>

NSString *RelayCommandFromResponse(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([trimmed hasPrefix:@"RELAY_DONE:"] || [trimmed hasPrefix:@"RELAY_PAUSE:"]) return nil;
    NSString *direct = RelayParseCommand(text);
    if (direct) return direct;
    if (!text) return nil;
    NSString *normalized = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    NSRegularExpression *fences = [NSRegularExpression regularExpressionWithPattern:@"(?ms)^```[^\\n]*\\n(.*?)^```[ \\t]*$" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *blocks = [fences matchesInString:normalized options:0 range:NSMakeRange(0, normalized.length)];
    // The operating protocol requires exactly one complete executable block per response.
    if (blocks.count != 1) return nil;
    return RelayParseCommand([normalized substringWithRange:[blocks.firstObject rangeAtIndex:1]]);
}

@implementation RelayAutoSnapshot
@end

@interface RelayAutoPilot ()
@property id<RelayAutoSource> source;
@property BOOL copying;
@property BOOL enabled;
@property BOOL scanning;
@property BOOL suspended;
@property BOOL initialized;
@property BOOL sawGenerating;
@property id previousCopy;
@property id stableCopy;
@property NSString *boundTitle;
@property NSUInteger stableCount;
@property NSUInteger generation;
@property NSString *lastStatus;
@property NSString *lastResponseText;
@property id lastDispatchedCopy;
@property BOOL mouseFallbackUsed;
@property BOOL preferMouse;
@property(copy) void (^commandHandler)(NSString *);
@property(copy) void (^statusHandler)(NSString *);
@end
@implementation RelayAutoPilot
- (instancetype)initWithSource:(id<RelayAutoSource>)source {
    if ((self = [super init])) _source = source;
    return self;
}
- (void)status:(NSString *)status {
    if ([self.lastStatus isEqualToString:status]) return;
    self.lastStatus = status;
    RelayLog(@"auto_status", @{@"text":status});
    if (self.statusHandler) self.statusHandler(status);
}
- (void)startWithCommand:(void (^)(NSString *))command status:(void (^)(NSString *))status {
    self.commandHandler = command; self.statusHandler = status;
    self.enabled = YES; self.initialized = NO; self.generation++;
    self.suspended = NO; self.sawGenerating = NO; self.boundTitle = nil;
    self.previousCopy = nil; self.stableCopy = nil; self.stableCount = 0;
    self.lastResponseText = nil; self.lastDispatchedCopy = nil;
    [self status:@"全自動已就緒：請在 ChatGPT 送出任務"];
    [self poll];
}
- (void)stop {
    self.enabled = NO; self.generation++; self.copying = NO;
    self.commandHandler = nil; self.statusHandler = nil;
    RelayLog(@"auto_stopped", @{});
}
- (void)suspend { self.suspended = YES; self.generation++; self.copying = NO; }
- (void)resume { self.suspended = NO; self.stableCount = 0; }
- (void)poll {
    if (!self.enabled || self.suspended || self.copying || self.scanning) return;
    self.scanning = YES;
    NSUInteger generation = self.generation;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        RelayAutoSnapshot *snapshot;
        @try { snapshot = [self.source snapshot]; }
        @catch (NSException *exception) { snapshot = [RelayAutoSnapshot new]; RelayLog(@"auto_snapshot_exception", @{@"name":exception.name}); }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanning = NO;
            if (!self.enabled || generation != self.generation) return;
            [self acceptSnapshot:snapshot generation:generation];
        });
    });
}
- (void)acceptSnapshot:(RelayAutoSnapshot *)snapshot generation:(NSUInteger)generation {
    if (!snapshot.available) { self.stableCount = 0; [self status:@"全自動等待：請保持原 ChatGPT 視窗在前景"]; return; }
    if (self.boundTitle && ![self.boundTitle isEqualToString:snapshot.windowTitle]) {
        [self status:@"對話已切換，全自動已停止"]; [self stop]; return;
    }
    if (!self.initialized) { self.previousCopy = snapshot.responseCopyButton; self.initialized = YES; }
    if (snapshot.generating) {
        self.sawGenerating = YES; self.stableCount = 0;
        [self status:@"全自動：等待 ChatGPT 回答完成"]; return;
    }
    if (!snapshot.idle) { self.stableCount = 0; [self status:@"全自動：尚未確認 ChatGPT 回答完成"]; return; }
    if (!snapshot.responseCopyButton || (!self.sawGenerating && [self.previousCopy isEqual:snapshot.responseCopyButton])) {
        [self status:@"全自動：等待下一次回答"]; return;
    }
    if (![self.stableCopy isEqual:snapshot.responseCopyButton]) { self.stableCopy = snapshot.responseCopyButton; self.stableCount = 1; return; }
    if (++self.stableCount < 3) return;
    self.boundTitle = snapshot.windowTitle;
    self.previousCopy = snapshot.responseCopyButton;
    self.sawGenerating = NO; self.stableCount = 0;
    self.copying = YES;
    self.mouseFallbackUsed = NO;
    NSInteger before = [self.source clipboardChangeCount];
    [self status:@"全自動：複製 ChatGPT 的完整回答"];
    if (self.preferMouse) { [self tryMouseCopy:before generation:generation]; return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!self.enabled || generation != self.generation) return;
        BOOL copied = NO;
        @try { copied = [self.source copyResponse:snapshot.responseCopyButton windowTitle:snapshot.windowTitle]; }
        @catch (NSException *exception) { RelayLog(@"auto_copy_exception", @{@"name":exception.name}); }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.enabled || generation != self.generation) return;
            if (!copied) { [self tryMouseCopy:before generation:generation]; return; }
            [self awaitClipboard:before attempt:0 generation:generation];
        });
    });
}
- (void)tryMouseCopy:(NSInteger)before generation:(NSUInteger)generation {
    if (!self.enabled || generation != self.generation) return;
    if (self.mouseFallbackUsed || ![self.source respondsToSelector:@selector(clickResponse:windowTitle:stillActive:)]) {
        self.copying = NO; [self status:@"複製未完成，全自動已停止"]; [self stop]; return;
    }
    self.mouseFallbackUsed = YES;
    RelayLog(@"auto_copy_mouse_fallback", @{@"previous_mouse_copy_verified":@(self.preferMouse)});
    [self status:@"全自動：驗證並點擊複製按鈕"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL (^active)(void) = ^BOOL { return self.enabled && generation == self.generation; };
        BOOL clicked = NO;
        @try { if (active()) clicked = [self.source clickResponse:self.stableCopy windowTitle:self.boundTitle stillActive:active]; }
        @catch (NSException *exception) { RelayLog(@"auto_mouse_copy_exception", @{@"name":exception.name}); }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!active()) return;
            RelayLog(@"auto_mouse_copy_result", @{@"clicked":@(clicked)});
            if (!clicked) { self.copying = NO; [self status:@"找不到可安全點擊的複製按鈕，全自動已停止"]; [self stop]; return; }
            [self awaitClipboard:before attempt:0 generation:generation];
        });
    });
}
- (void)awaitClipboard:(NSInteger)before attempt:(NSUInteger)attempt generation:(NSUInteger)generation {
    if (!self.enabled || !self.copying || generation != self.generation) return;
    if ([self.source clipboardChangeCount] != before) {
        if (self.mouseFallbackUsed) self.preferMouse = YES;
        NSString *response = [self.source clipboardText];
        NSString *command = RelayCommandFromResponse(response);
        self.copying = NO;
        if ([self.lastDispatchedCopy isEqual:self.stableCopy] && [self.lastResponseText isEqualToString:response]) {
            RelayLog(@"auto_duplicate_response_ignored", @{});
            [self status:@"全自動：等待新的回答"]; return;
        }
        self.lastDispatchedCopy = self.stableCopy;
        self.lastResponseText = response;
        RelayLog(@"auto_response_copied", @{@"command_found":@(command != nil), @"command_characters":@(command.length)});
        if (!command) { [self status:@"回答沒有單一執行指令：全自動已結束，請查看 ChatGPT"]; [self stop]; return; }
        if (self.commandHandler) self.commandHandler(command);
        return;
    }
    if (attempt >= 20) {
        if (!self.mouseFallbackUsed) { [self tryMouseCopy:before generation:generation]; return; }
        self.copying = NO; [self status:@"實際點擊後剪貼簿仍未更新，全自動已停止"]; [self stop]; return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self awaitClipboard:before attempt:attempt + 1 generation:generation];
    });
}
@end

static id AutoAttr(id element, CFStringRef attribute) {
    if (!element) return nil;
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue((__bridge AXUIElementRef)element, attribute, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}
static BOOL Matches(NSString *value, NSArray<NSString *> *labels) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *name = [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    for (NSString *label in labels) {
        NSString *prefix = label.lowercaseString;
        if ([name isEqualToString:prefix] || [name hasPrefix:[prefix stringByAppendingString:@" ("]] || [name hasPrefix:[prefix stringByAppendingString:@"（"]]) return YES;
    }
    return NO;
}
@interface RelayAXAutoSource ()
@property NSRunningApplication *app;
@property id axApp;
@property id window;
@end
@implementation RelayAXAutoSource
- (instancetype)initWithApplication:(NSRunningApplication *)app {
    if ((self = [super init])) {
        _app = app;
        _axApp = CFBridgingRelease(AXUIElementCreateApplication(app.processIdentifier));
        AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)_axApp, 0.2);
    }
    return self;
}
- (RelayAutoSnapshot *)snapshot {
    RelayAutoSnapshot *result = [RelayAutoSnapshot new];
    if (self.app.terminated || !AXIsProcessTrusted() || NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != self.app.processIdentifier) return result;
    id focused = AutoAttr(self.axApp, kAXFocusedWindowAttribute);
    if (!focused) return result;
    if (!self.window) self.window = focused;
    if (![self.window isEqual:focused]) return result;
    result.windowTitle = AutoAttr(self.window, kAXTitleAttribute) ?: @"";
    NSMutableArray *stack = [NSMutableArray arrayWithObject:self.window];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2.0;
    NSUInteger visited = 0;
    BOOL stopped = NO, idle = NO;
    // Reverse document order reaches the composer and most recent response first,
    // avoiding a full scan of hundreds of older messages in long conversations.
    while (stack.count && visited++ < 20000 && NSProcessInfo.processInfo.systemUptime < deadline) {
        id node = stack.lastObject; [stack removeLastObject];
        NSString *role = AutoAttr(node, kAXRoleAttribute);
        if ([role isEqual:(__bridge NSString *)kAXButtonRole]) {
            BOOL enabled = ![AutoAttr(node, kAXEnabledAttribute) isEqual:@NO];
            NSString *name = AutoAttr(node, kAXDescriptionAttribute) ?: @"";
            NSString *title = AutoAttr(node, kAXTitleAttribute) ?: @"";
            NSArray *stopLabels = @[@"Stop", @"Stop generating", @"Stop response", @"Stop streaming", @"停止", @"停止生成", @"停止回應", @"停止回覆", @"停止回答"];
            NSArray *sendLabels = @[@"Send", @"Send message", @"Send prompt", @"Send now", @"傳送", @"傳送訊息", @"傳送提示", @"送出", @"送出訊息", @"发送", @"发送消息", @"Start voice mode", @"Use voice mode", @"開始語音模式", @"啟動語音模式", @"使用語音模式", @"開始語音對話"];
            NSArray *copyLabels = @[@"Copy", @"Copy code", @"Copy response", @"Copy message", @"複製", @"複製程式碼", @"複製代碼", @"複製回覆", @"複製內容", @"复制", @"复制代码", @"复制回复"];
            stopped |= enabled && (Matches(name, stopLabels) || Matches(title, stopLabels));
            idle |= Matches(name, sendLabels) || Matches(title, sendLabels);
            if (enabled && !result.responseCopyButton && (Matches(name, copyLabels) || Matches(title, copyLabels))) result.responseCopyButton = node;
        }
        NSArray *children = AutoAttr(node, kAXChildrenAttribute);
        if ([children isKindOfClass:NSArray.class]) [stack addObjectsFromArray:children];
        if (result.responseCopyButton && (stopped || idle)) break;
    }
    result.available = YES;
    result.generating = stopped;
    result.idle = !stopped && idle;
    RelayLog(@"auto_snapshot", @{@"nodes_visited":@(visited), @"generating":@(stopped), @"idle_control":@(idle), @"copy_button":@(result.responseCopyButton != nil)});
    return result;
}
- (BOOL)copyResponse:(id)button windowTitle:(NSString *)title {
    RelayAutoSnapshot *current = [self snapshot];
    if (!current.available || current.generating || !current.idle || ![current.responseCopyButton isEqual:button] || ![current.windowTitle isEqualToString:title]) return NO;
    AXError error = AXUIElementPerformAction((__bridge AXUIElementRef)button, kAXPressAction);
    RelayLog(@"auto_copy_pressed", @{@"ax_error":@(error)});
    return error == kAXErrorSuccess;
}
- (BOOL)clickResponse:(id)button windowTitle:(NSString *)title stillActive:(BOOL (^)(void))active {
    RelayAutoSnapshot *current = [self snapshot];
    if (!active() || !current.available || current.generating || !current.idle ||
        ![current.responseCopyButton isEqual:button] || ![current.windowTitle isEqualToString:title]) return NO;
    id position = AutoAttr(button, kAXPositionAttribute), size = AutoAttr(button, kAXSizeAttribute);
    CGPoint origin; CGSize extent;
    if (!position || !size || CFGetTypeID((__bridge CFTypeRef)position) != AXValueGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)size) != AXValueGetTypeID() ||
        !AXValueGetValue((__bridge AXValueRef)position, kAXValueCGPointType, &origin) ||
        !AXValueGetValue((__bridge AXValueRef)size, kAXValueCGSizeType, &extent) || extent.width <= 0 || extent.height <= 0) {
        RelayLog(@"auto_mouse_copy_rejected", @{@"reason":@"missing_button_geometry"}); return NO;
    }
    CGPoint point = CGPointMake(origin.x + extent.width / 2, origin.y + extent.height / 2);
    if (!isfinite(point.x) || !isfinite(point.y)) return NO;
    AXUIElementRef system = AXUIElementCreateSystemWide();
    AXUIElementRef hit = NULL;
    AXError hitError = AXUIElementCopyElementAtPosition(system, point.x, point.y, &hit);
    pid_t hitPID = 0;
    if (hit) AXUIElementGetPid(hit, &hitPID);
    if (hit) CFRelease(hit);
    if (hitError != kAXErrorSuccess || hitPID != self.app.processIdentifier ||
        CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft) || !active()) {
        CFRelease(system);
        RelayLog(@"auto_mouse_copy_rejected", @{@"reason":@"button_not_in_target_app_or_mouse_in_use", @"hit_pid":@(hitPID)}); return NO;
    }
    CGEventRef probe = CGEventCreate(NULL);
    if (!probe) { CFRelease(system); return NO; }
    CGPoint oldPoint = CGEventGetLocation(probe); CFRelease(probe);
    CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, point, kCGMouseButtonLeft);
    if (!move) { CFRelease(system); return NO; }
    CGEventPost(kCGHIDEventTap, move); CFRelease(move);
    usleep(120000); // Let hover-only copy controls become hit-testable.
    hit = NULL;
    hitError = AXUIElementCopyElementAtPosition(system, point.x, point.y, &hit);
    CFRelease(system);
    BOOL exactButton = NO;
    id ancestor = hit ? CFBridgingRelease(hit) : nil;
    for (int depth = 0; ancestor && depth < 10; depth++) {
        if ([ancestor isEqual:button]) { exactButton = YES; break; }
        ancestor = AutoAttr(ancestor, kAXParentAttribute);
    }
    BOOL clicked = NO;
    probe = CGEventCreate(NULL);
    CGPoint cursor = probe ? CGEventGetLocation(probe) : CGPointMake(INFINITY, INFINITY);
    if (probe) CFRelease(probe);
    BOOL cursorUnmoved = fabs(cursor.x - point.x) < 2 && fabs(cursor.y - point.y) < 2 &&
        !CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft);
    if (cursorUnmoved && hitError == kAXErrorSuccess && exactButton && active() && !self.app.terminated &&
        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == self.app.processIdentifier &&
        [AutoAttr(self.axApp, kAXFocusedWindowAttribute) isEqual:self.window] &&
        [AutoAttr(self.window, kAXTitleAttribute) isEqualToString:title]) {
        CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
        CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
        if (down && up) {
            CGEventSetFlags(down, 0); CGEventSetFlags(up, 0);
            CGEventSetIntegerValueField(down, kCGMouseEventClickState, 1);
            CGEventSetIntegerValueField(up, kCGMouseEventClickState, 1);
            CGEventPost(kCGHIDEventTap, down); CGEventPost(kCGHIDEventTap, up); clicked = YES;
        }
        if (down) CFRelease(down); if (up) CFRelease(up);
    }
    // Preserve the user's cursor if they did not move it during this brief operation.
    usleep(80000);
    probe = CGEventCreate(NULL);
    if (probe) {
        CGPoint now = CGEventGetLocation(probe); CFRelease(probe);
        if (fabs(now.x - point.x) < 2 && fabs(now.y - point.y) < 2 &&
            NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == self.app.processIdentifier) {
            move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, oldPoint, kCGMouseButtonLeft);
            if (move) { CGEventPost(kCGHIDEventTap, move); CFRelease(move); }
        }
    }
    RelayLog(@"auto_mouse_copy_hit_test", @{@"exact_button":@(exactButton), @"clicked":@(clicked)});
    return clicked;
}
- (NSInteger)clipboardChangeCount { return NSPasteboard.generalPasteboard.changeCount; }
- (NSString *)clipboardText { return [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]; }
@end
