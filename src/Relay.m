#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import "RelayDelivery.h"
#import "RelayDiagnostics.h"
#import "RelayAuthorization.h"
#import "RelayAutoPilot.h"

static NSString * const kCurrentVersion = @"0.6.1";
static NSString * const kChatGPTBundleID = @"com.openai.codex";
static NSString * const kLatestReleaseAPI = @"https:" @"//api.github.com/repos/Coyoter/ChatGPT-Terminal-Relay/releases/latest";
static NSString * const kReleasesURL = @"https:" @"//github.com/Coyoter/ChatGPT-Terminal-Relay/releases";

@interface RelayAppDelegate : NSObject <NSApplicationDelegate>
@property NSStatusItem *statusItem;
@property NSMenuItem *statusMenuItem;
@property NSMenuItem *startMenuItem;
@property NSMenuItem *stopMenuItem;
@property NSTimer *clipboardTimer;
@property NSInteger lastChangeCount;
@property BOOL monitoring;
@property BOOL executing;
@property NSString *lastExecutedCommand;
@property NSTimeInterval lastExecutedAt;
@property NSString *lastResult;
@property NSString *lastLogPath;
@property RelayDelivery *delivery;
@property NSMenuItem *retryMenuItem;
@property NSMenuItem *resultCopyMenuItem;
@property NSUInteger returnGeneration;
@property BOOL returnPending;
@property NSString *commandID;
@property BOOL lastAccessibilityTrusted;
@property NSTimeInterval lastPermissionCheck;
@property RelayAutoPilot *autoPilot;
@property NSMenuItem *autoStartItem;
@property NSMenuItem *autoStopItem;
@property NSMenuItem *modeItem;
@property NSTimeInterval lastAutoPoll;
@end

@implementation RelayAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.monitoring = YES;
    self.executing = NO;
    self.lastAccessibilityTrusted = AXIsProcessTrusted();
    RelayLog(@"app_started", @{@"version":kCurrentVersion, @"bundle_path":NSBundle.mainBundle.bundlePath,
        @"accessibility_trusted":@(self.lastAccessibilityTrusted),
        @"os":NSProcessInfo.processInfo.operatingSystemVersionString});
    self.lastChangeCount = NSPasteboard.generalPasteboard.changeCount;

    NSString *saved = [NSString stringWithContentsOfFile:RelaySavedResultPath()
                                               encoding:NSUTF8StringEncoding error:nil];
    self.lastResult = saved;
    [self setupStatusItem];
    [self updateStatus:@"正在檢查新版授權"];
    BOOL authorizationPrepared = RelayEnsureAuthorizationForInstalledBuild();
    RelayLog(@"authorization_prepared", @{@"success":@(authorizationPrepared)});
    [self requestAccessibilityPermission];
    [self startClipboardTimer];
    [self updateStatus:self.lastAccessibilityTrusted ? @"監聽中" : @"需要輔助使用權限"];

    // Check GitHub Releases once after each launch without interrupting startup.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            [self checkForUpdates:NO];
        }
    );
}

- (void)setupStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"⇄ Relay";
    self.statusItem.button.toolTip = @"ChatGPT ↔ Terminal Relay";

    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *versionItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"ChatGPT Terminal Relay %@", kCurrentVersion] action:nil keyEquivalent:@""];
    versionItem.enabled = NO; [menu addItem:versionItem];
    self.modeItem = [[NSMenuItem alloc] initWithTitle:@"模式：只按複製" action:nil keyEquivalent:@""];
    self.modeItem.enabled = NO; [menu addItem:self.modeItem];

    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"狀態：啟動中"
                                                    action:nil
                                             keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    [menu addItem:self.statusMenuItem];

    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *checkUpdatesItem =
        [[NSMenuItem alloc] initWithTitle:@"檢查更新…"
                                   action:@selector(checkForUpdatesMenu:)
                            keyEquivalent:@""];
    checkUpdatesItem.target = self;
    [menu addItem:checkUpdatesItem];

    [menu addItem:NSMenuItem.separatorItem];

    self.startMenuItem = [[NSMenuItem alloc] initWithTitle:@"啟動監聽"
                                                   action:@selector(startMonitoring:)
                                            keyEquivalent:@""];
    self.startMenuItem.target = self;
    [menu addItem:self.startMenuItem];

    self.stopMenuItem = [[NSMenuItem alloc] initWithTitle:@"停止監聽"
                                                  action:@selector(stopMonitoring:)
                                           keyEquivalent:@""];
    self.stopMenuItem.target = self;
    [menu addItem:self.stopMenuItem];

    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *handoffItem = [[NSMenuItem alloc] initWithTitle:@"選擇專案並複製接手提示…" action:@selector(copyHandoff:) keyEquivalent:@""];
    handoffItem.target = self; [menu addItem:handoffItem];
    self.autoStartItem = [[NSMenuItem alloc] initWithTitle:@"啟動全自動接續" action:@selector(startAuto:) keyEquivalent:@""];
    self.autoStartItem.target = self; [menu addItem:self.autoStartItem];
    self.autoStopItem = [[NSMenuItem alloc] initWithTitle:@"停止全自動接續" action:@selector(stopAuto:) keyEquivalent:@""];
    self.autoStopItem.target = self; [menu addItem:self.autoStopItem];
    [menu addItem:NSMenuItem.separatorItem];

    self.retryMenuItem = [[NSMenuItem alloc] initWithTitle:@"重試回傳上次結果" action:@selector(retryReturn:) keyEquivalent:@""];
    self.retryMenuItem.target = self;
    [menu addItem:self.retryMenuItem];
    self.resultCopyMenuItem = [[NSMenuItem alloc] initWithTitle:@"複製上次結果" action:@selector(copyResult:) keyEquivalent:@""];
    self.resultCopyMenuItem.target = self;
    [menu addItem:self.resultCopyMenuItem];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *permissionItem = [[NSMenuItem alloc] initWithTitle:@"檢查輔助使用權限…" action:@selector(checkAccessibility:) keyEquivalent:@""];
    permissionItem.target = self;
    [menu addItem:permissionItem];
    NSMenuItem *diagnosticsItem = [[NSMenuItem alloc] initWithTitle:@"開啟診斷紀錄" action:@selector(openDiagnostics:) keyEquivalent:@""];
    diagnosticsItem.target = self;
    [menu addItem:diagnosticsItem];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"結束 Relay"
                                                     action:@selector(quit:)
                                              keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
}

- (void)requestAccessibilityPermission {
    NSDictionary *options = @{
        (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES
    };
    self.lastAccessibilityTrusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    RelayLog(@"permission_checked", @{@"trusted":@(self.lastAccessibilityTrusted), @"prompt_requested":@YES});
}

- (void)openDiagnostics:(id)sender {
    RelayLog(@"diagnostics_opened", @{});
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:RelayDiagnosticsPath()]]];
}

- (void)checkAccessibility:(id)sender {
    [self requestAccessibilityPermission];
    NSAlert *alert = [NSAlert new];
    alert.messageText = self.lastAccessibilityTrusted ? @"輔助使用權限正常" : @"目前這份 Relay 尚未取得權限";
    alert.informativeText = self.lastAccessibilityTrusted
        ? @"系統已允許目前正在執行的 Relay 控制其他 App。若回傳仍失敗，可開啟診斷紀錄查看原因。"
        : [NSString stringWithFormat:@"目前版本：%@\n位置：%@\n\n若設定中已經開啟，請移除舊的 ChatGPT Terminal Relay 項目，再加入這個位置的 App 並開啟權限。單純關閉再開啟舊項目可能無效。", kCurrentVersion, NSBundle.mainBundle.bundlePath];
    [alert addButtonWithTitle:self.lastAccessibilityTrusted ? @"好" : @"開啟輔助使用設定"];
    if (!self.lastAccessibilityTrusted) [alert addButtonWithTitle:@"稍後"];
    if ([alert runModal] == NSAlertFirstButtonReturn && !self.lastAccessibilityTrusted)
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

- (void)startClipboardTimer {
    [self.clipboardTimer invalidate];

    self.clipboardTimer =
        [NSTimer timerWithTimeInterval:0.35
                                target:self
                              selector:@selector(checkClipboard:)
                              userInfo:nil
                               repeats:YES];

    [[NSRunLoop mainRunLoop] addTimer:self.clipboardTimer
                              forMode:NSRunLoopCommonModes];
}

- (void)checkClipboard:(NSTimer *)timer {
    NSTimeInterval uptime = NSProcessInfo.processInfo.systemUptime;
    if (uptime - self.lastPermissionCheck >= 2.0) {
        self.lastPermissionCheck = uptime;
        BOOL trusted = AXIsProcessTrusted();
        if (trusted != self.lastAccessibilityTrusted) {
            self.lastAccessibilityTrusted = trusted;
            if (!trusted) [self.autoPilot stop];
            RelayLog(@"permission_changed", @{@"trusted":@(trusted)});
            if (!self.executing) [self updateStatus:self.monitoring ? (trusted ? @"監聽中" : @"需要輔助使用權限") : @"已停止"];
        }
    }
    [self updateAutoMenus];
    if (!self.monitoring || self.executing) return;
    if (self.autoPilot.enabled && uptime - self.lastAutoPoll >= 0.75) {
        self.lastAutoPoll = uptime;
        [self.autoPilot poll];
    }
    if (self.autoPilot.copying) return;

    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    NSInteger changeCount = pasteboard.changeCount;

    if (changeCount == self.lastChangeCount) {
        return;
    }

    self.lastChangeCount = changeCount;

    NSString *text = [pasteboard stringForType:NSPasteboardTypeString];

    NSString *command = RelayParseCommand(text);
    if (!command) {
        RelayLog(@"clipboard_ignored", @{@"has_text":@(text != nil), @"characters":@(text.length), @"reason":@"missing_or_invalid_marker"});
        return;
    }

    [self acceptCommand:command origin:@"manual_clipboard"];
}

- (void)acceptCommand:(NSString *)command origin:(NSString *)origin {
    if (!self.monitoring || self.executing || !command.length) return;
    // Prevent accidental double-clicks from executing the exact same command twice.
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (self.lastExecutedCommand &&
        [self.lastExecutedCommand isEqualToString:command] &&
        (now - self.lastExecutedAt) < 3.0) {
        RelayLog(@"command_duplicate_ignored", @{});
        return;
    }

    self.lastExecutedCommand = command;
    self.lastExecutedAt = now;

    self.executing = YES;
    [self.autoPilot suspend];
    self.commandID = NSUUID.UUID.UUIDString;
    RelayLog(@"command_accepted", @{@"origin":origin, @"command_id":self.commandID, @"characters":@(command.length), @"accessibility_trusted":@(AXIsProcessTrusted())});
    [self updateStatus:@"執行中"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = [self runShellCommand:command];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishCommand:command
                         result:result];
        });
    });
}

- (NSDictionary *)runShellCommand:(NSString *)command {
    NSString *tempPath =
        [RelayLogDirectory()
         stringByAppendingPathComponent:
         [NSString stringWithFormat:@"chatgpt-relay-%@.log",
          NSUUID.UUID.UUIDString]];

    [[NSFileManager defaultManager] createFileAtPath:tempPath
                                            contents:nil
                                          attributes:nil];

    NSFileHandle *handle =
        [NSFileHandle fileHandleForWritingAtPath:tempPath];

    if (!handle) {
        return @{
            @"exitCode": @127,
            @"output": @"Relay error: 無法建立暫存輸出檔。"
        };
    }

    NSTask *task = [[NSTask alloc] init];

    task.executableURL = [NSURL fileURLWithPath:@"/bin/zsh"];
    task.arguments = @[@"-lc", command];
    task.standardOutput = handle;
    task.standardError = handle;

    NSError *error = nil;

    @try {
        [task launchAndReturnError:&error];

        if (error) {
            [handle closeFile];

            [[NSFileManager defaultManager]
                removeItemAtPath:tempPath
                           error:nil];

            return @{
                @"exitCode": @127,
                @"output":
                    [NSString stringWithFormat:
                     @"Relay 無法啟動 zsh：\n%@", error]
            };
        }

        [task waitUntilExit];
    }
    @catch (NSException *exception) {
        [handle closeFile];

        [[NSFileManager defaultManager]
            removeItemAtPath:tempPath
                       error:nil];

        return @{
            @"exitCode": @127,
            @"output":
                [NSString stringWithFormat:
                 @"Relay 執行例外：\n%@",
                 exception.reason ?: @"Unknown error"]
        };
    }

    [handle synchronizeFile];
    [handle closeFile];

    NSFileHandle *reader = [NSFileHandle fileHandleForReadingAtPath:tempPath];
    NSData *data = [reader readDataOfLength:65536];
    BOOL truncated = [reader readDataOfLength:1].length != 0;
    [reader closeFile];

    NSString *output =
        [[NSString alloc] initWithData:data
                              encoding:NSUTF8StringEncoding];

    if (!output && truncated) {
        // The preview boundary may split a UTF-8 code point. Keep the valid prefix.
        for (NSUInteger trim = 1; trim <= 3 && trim < data.length; trim++) {
            output = [[NSString alloc] initWithBytes:data.bytes length:data.length - trim encoding:NSUTF8StringEncoding];
            if (output) break;
        }
    }

    if (!output && data) {
        output =
            [[NSString alloc] initWithBytes:data.bytes
                                    length:data.length
                                  encoding:NSISOLatin1StringEncoding];
    }

    if (!output) {
        output = @"";
    }

    if (truncated) output = [output stringByAppendingFormat:@"\n\n[輸出較長，完整紀錄保留於：%@]", tempPath];
    return @{@"exitCode": @(task.terminationStatus), @"output": output, @"logPath": tempPath};
}

- (void)finishCommand:(NSString *)command
                 result:(NSDictionary *)result {

    NSNumber *exitCode = result[@"exitCode"];
    NSString *output = result[@"output"];
    RelayLog(@"command_finished", @{@"command_id":self.commandID ?: @"", @"exit_code":exitCode ?: @127, @"output_characters":@(output.length)});

    if (output.length == 0) {
        output = @"(no output)";
    }

    NSString *relayResult =
        [NSString stringWithFormat:
         @"EXIT_CODE: %@\n\n"
         @"OUTPUT:\n%@",
         exitCode,
         output];

    self.lastResult = relayResult;
    self.lastLogPath = result[@"logPath"];
    [relayResult writeToFile:RelaySavedResultPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self beginReturn];
}

- (void)copyResult:(id)sender {
    if (!self.lastResult) return;
    NSPasteboard *p = NSPasteboard.generalPasteboard;
    [p clearContents];
    [p setString:self.lastResult forType:NSPasteboardTypeString];
    self.lastChangeCount = p.changeCount;
    [self updateStatus:self.monitoring ? @"結果已複製，監聽中" : @"結果已複製，已停止"];
}

- (void)retryReturn:(id)sender {
    RelayLog(@"return_retry_requested", @{@"busy":@(self.executing), @"monitoring":@(self.monitoring)});
    if (self.executing || !self.lastResult || !self.monitoring) return;
    self.executing = YES;
    [self beginReturn];
}

- (void)endReturn:(NSString *)status {
    RelayLog(@"return_finished", @{@"command_id":self.commandID ?: @"", @"status":status});
    self.returnPending = NO;
    self.executing = NO;
    self.delivery = nil;
    if (self.autoPilot.enabled) {
        if ([status hasPrefix:@"已送出回傳按鍵"]) [self.autoPilot resume];
        else [self.autoPilot stop];
    }
    [self updateStatus:self.monitoring ? status : @"已停止，結果已保留"];
}

- (void)beginReturn {
    NSUInteger generation = ++self.returnGeneration;
    self.returnPending = YES;
    if (!self.monitoring) { [self endReturn:@"已停止，結果已保留"]; return; }
    BOOL trusted = AXIsProcessTrusted();
    self.lastAccessibilityTrusted = trusted;
    RelayLog(@"return_permission_check", @{@"trusted":@(trusted), @"command_id":self.commandID ?: @""});
    if (!trusted) { [self endReturn:@"需要輔助使用權限，結果已保留"]; return; }
    [self updateStatus:@"正在尋找 ChatGPT"];
    [self findOrLaunchChatGPTWithAttempt:0 completion:^(NSRunningApplication *app) {
        if (generation != self.returnGeneration) return;
        if (!self.monitoring || !app) { [self endReturn:@"找不到 ChatGPT，結果已保留"]; return; }
        BOOL activated = [app activateWithOptions:NSApplicationActivateAllWindows];
        RelayLog(@"chatgpt_activation", @{@"target_pid":@(app.processIdentifier), @"request_accepted":@(activated), @"frontmost_pid":@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier)});
        if (!activated) {
            [self endReturn:@"無法喚醒 ChatGPT，請開啟後重試"]; return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != self.returnGeneration) return;
            if (!self.monitoring) { [self endReturn:@"已停止"]; return; }
            [self updateStatus:@"回傳中"];
            [self pasteResult:self.lastResult toApplication:app generation:generation];
        });
    }];
}

- (BOOL)postKey:(CGKeyCode)key flags:(CGEventFlags)flags toPID:(pid_t)pid {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!source) return NO;
    CGEventRef down = CGEventCreateKeyboardEvent(source, key, true);
    CGEventRef up = CGEventCreateKeyboardEvent(source, key, false);
    if (!down || !up) {
        if (down) CFRelease(down); if (up) CFRelease(up); CFRelease(source); return NO;
    }
    CGEventSetFlags(down, flags); CGEventSetFlags(up, flags);
    CGEventPostToPid(pid, down); CGEventPostToPid(pid, up);
    CFRelease(down); CFRelease(up); CFRelease(source);
    return YES;
}

- (void)pasteResult:(NSString *)result toApplication:(NSRunningApplication *)app generation:(NSUInteger)generation {
    if (generation != self.returnGeneration || !self.monitoring) return;
    if (app.terminated || NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != app.processIdentifier) {
        [self endReturn:@"ChatGPT 不是前景視窗，結果已保留"]; return;
    }
    if (!AXIsProcessTrusted()) { [self endReturn:@"需要輔助使用權限，結果已保留"]; return; }
    NSPasteboard *p = NSPasteboard.generalPasteboard;
    [p clearContents];
    if (![p setString:result forType:NSPasteboardTypeString]) { [self endReturn:@"無法複製結果"]; return; }
    NSInteger ownedChange = p.changeCount;
    self.lastChangeCount = ownedChange;
    RelayLog(@"paste_to_chatgpt", @{@"target_pid":@(app.processIdentifier), @"result_characters":@(result.length)});
    if (![self postKey:9 flags:kCGEventFlagMaskCommand toPID:app.processIdentifier]) {
        [self endReturn:@"無法貼上，結果已保留"]; return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.returnGeneration || !self.monitoring) return;
        BOOL targetOK = !app.terminated && NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == app.processIdentifier;
        BOOL clipboardOK = p.changeCount == ownedChange && [[p stringForType:NSPasteboardTypeString] isEqualToString:result];
        BOOL trusted = AXIsProcessTrusted();
        RelayLog(@"before_send", @{@"target_ok":@(targetOK), @"clipboard_unchanged":@(clipboardOK), @"trusted":@(trusted)});
        if (!targetOK || !clipboardOK || !trusted) {
            [self endReturn:@"視窗、剪貼簿或權限已變更，未送出"]; return;
        }
        BOOL posted = [self postKey:36 flags:0 toPID:app.processIdentifier];
        [self endReturn:posted ? @"已送出回傳按鍵，監聽中" : @"無法送出，結果已保留"];
    });
}

- (NSRunningApplication *)findRunningChatGPTUsingFallback:(BOOL *)usedFallback {
    if (usedFallback) {
        *usedFallback = NO;
    }

    // Primary lookup.
    NSArray<NSRunningApplication *> *apps =
        [NSRunningApplication
         runningApplicationsWithBundleIdentifier:kChatGPTBundleID];

    for (NSRunningApplication *app in apps) {
        if (![app isTerminated]) {
            return app;
        }
    }

    // Fallback:
    // runningApplicationsWithBundleIdentifier can occasionally return
    // an empty result even while ChatGPT is alive. Check the complete
    // NSWorkspace snapshot before concluding that ChatGPT is absent.
    for (NSRunningApplication *candidate
         in NSWorkspace.sharedWorkspace.runningApplications) {

        if ([candidate isTerminated]) {
            continue;
        }

        NSString *bundleID = candidate.bundleIdentifier ?: @"";
        NSString *bundlePath = candidate.bundleURL.path ?: @"";
        NSString *executablePath = candidate.executableURL.path ?: @"";

        BOOL bundleMatches =
            [bundleID isEqualToString:kChatGPTBundleID];

        BOOL bundlePathMatches =
            [bundlePath isEqualToString:@"/Applications/ChatGPT.app"];

        BOOL executableMatches =
            [executablePath
             isEqualToString:
             @"/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"];

        if (bundleMatches ||
            bundlePathMatches ||
            executableMatches) {

            if (usedFallback) {
                *usedFallback = YES;
            }

            NSLog(
                @"[Relay] Primary ChatGPT lookup missed PID %d; "
                 "workspace fallback recovered it.",
                candidate.processIdentifier
            );

            return candidate;
        }
    }

    return nil;
}

- (void)findOrLaunchChatGPTWithAttempt:(NSInteger)attempt
                            completion:(void (^)(NSRunningApplication *))completion {
    if (!self.returnPending) return;
    NSUInteger lookupGeneration = self.returnGeneration;
    BOOL usedFallback = NO;

    NSRunningApplication *chatGPTApp =
        [self findRunningChatGPTUsingFallback:&usedFallback];

    RelayLog(@"chatgpt_lookup", @{@"attempt":@(attempt), @"found":@(chatGPTApp != nil), @"fallback":@(usedFallback), @"target_pid":@(chatGPTApp.processIdentifier)});
    if (chatGPTApp) {
        if (usedFallback) {
            NSLog(
                @"[Relay] ChatGPT recovered through workspace fallback."
            );
        }

        completion(chatGPTApp);
        return;
    }

    NSLog(
        @"[Relay] ChatGPT not found. attempt=%ld",
        (long)attempt
    );

    if (attempt == 0) {
        [self updateStatus:@"正在啟動 ChatGPT"];

        NSURL *appURL =
            [NSWorkspace.sharedWorkspace
             URLForApplicationWithBundleIdentifier:kChatGPTBundleID];

        if (!appURL) {
            NSString *fallbackPath = @"/Applications/ChatGPT.app";

            if ([[NSFileManager defaultManager]
                 fileExistsAtPath:fallbackPath]) {
                appURL = [NSURL fileURLWithPath:fallbackPath];
            }
        }

        if (appURL) {
            NSWorkspaceOpenConfiguration *configuration =
                [NSWorkspaceOpenConfiguration configuration];

            configuration.activates = YES;
            configuration.createsNewApplicationInstance = NO;

            [NSWorkspace.sharedWorkspace
             openApplicationAtURL:appURL
             configuration:configuration
             completionHandler:^(NSRunningApplication *application,
                                 NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (lookupGeneration != self.returnGeneration || !self.returnPending) return;
                    if (application && ![application isTerminated]) {
                        NSLog(
                            @"[Relay] ChatGPT open returned PID %d.",
                            application.processIdentifier
                        );

                        completion(application);
                        return;
                    }

                    if (error) {
                        NSLog(
                            @"[Relay] ChatGPT open failed: %@",
                            error.localizedDescription
                        );
                    }

                    [self scheduleChatGPTRetryFromAttempt:attempt
                                              completion:completion];
                });
             }];

            return;
        }
    }

    [self scheduleChatGPTRetryFromAttempt:attempt
                              completion:completion];
}

- (void)scheduleChatGPTRetryFromAttempt:(NSInteger)attempt
                             completion:(void (^)(NSRunningApplication *))completion {
    if (!self.returnPending) return;
    NSUInteger lookupGeneration = self.returnGeneration;
    static const NSInteger kMaximumLookupAttempts = 6;

    if (attempt >= kMaximumLookupAttempts) {
        BOOL usedFallback = NO;

        NSRunningApplication *finalApp =
            [self findRunningChatGPTUsingFallback:&usedFallback];

        if (finalApp) {
            completion(finalApp);
        } else {
            NSLog(
                @"[Relay] ChatGPT lookup exhausted all retries."
            );
            completion(nil);
        }

        return;
    }

    [self updateStatus:@"正在等待 ChatGPT"];

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(0.45 * NSEC_PER_SEC)
        ),
        dispatch_get_main_queue(),
        ^{
            if (lookupGeneration != self.returnGeneration || !self.returnPending) return;
            [self findOrLaunchChatGPTWithAttempt:(attempt + 1)
                                      completion:completion];
        }
    );
}

- (void)checkForUpdatesMenu:(id)sender {
    [self checkForUpdates:YES];
}

- (void)checkForUpdates:(BOOL)manual {
    NSURL *url = [NSURL URLWithString:kLatestReleaseAPI];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 10.0;
    [request setValue:
        [NSString stringWithFormat:@"ChatGPT-Terminal-Relay/%@", kCurrentVersion]
        forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github+json"
        forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession]
         dataTaskWithRequest:request
         completionHandler:^(NSData *data,
                             NSURLResponse *response,
                             NSError *error) {
        if (error || !data) {
            if (manual) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showUpdateError:
                        error.localizedDescription ?: @"無法連線至 GitHub。"];
                });
            }
            return;
        }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode < 200 || http.statusCode >= 300) {
            if (manual) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showUpdateError:
                        [NSString stringWithFormat:
                         @"GitHub 回傳 HTTP %ld。",
                         (long)http.statusCode]];
                });
            }
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *json =
            [NSJSONSerialization JSONObjectWithData:data
                                            options:0
                                              error:&jsonError];

        if (![json isKindOfClass:NSDictionary.class]) {
            if (manual) dispatch_async(dispatch_get_main_queue(), ^{ [self showUpdateError:@"更新資料格式不正確。"]; });
            return;
        }
        NSString *tag = json[@"tag_name"];
        NSString *releaseURL = [json[@"html_url"] isKindOfClass:NSString.class] ? json[@"html_url"] : kReleasesURL;

        if (jsonError || ![tag isKindOfClass:NSString.class]) {
            if (manual) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showUpdateError:@"無法解析 GitHub Release 資訊。"];
                });
            }
            return;
        }

        NSString *latest =
            [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag;

        NSComparisonResult comparison =
            [latest compare:kCurrentVersion options:NSNumericSearch];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (comparison == NSOrderedDescending) {
                [self showUpdateAvailable:latest
                               releaseURL:releaseURL];
            } else if (manual) {
                [self showUpToDate];
            }
        });
    }];

    [task resume];
}

- (void)showUpdateAvailable:(NSString *)latest
                 releaseURL:(NSString *)releaseURL {
    [NSApp activateIgnoringOtherApps:YES];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"有新版 ChatGPT Terminal Relay";
    alert.informativeText =
        [NSString stringWithFormat:
         @"目前版本：%@\n最新版本：%@\n\n可前往 GitHub Releases 自行下載更新。",
         kCurrentVersion,
         latest];
    [alert addButtonWithTitle:@"前往 GitHub"];
    [alert addButtonWithTitle:@"稍後"];

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *target =
            releaseURL.length > 0 ? releaseURL : kReleasesURL;
        [NSWorkspace.sharedWorkspace
            openURL:[NSURL URLWithString:target]];
    }
}

- (void)showUpToDate {
    [NSApp activateIgnoringOtherApps:YES];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"已是最新版本";
    alert.informativeText =
        [NSString stringWithFormat:
         @"ChatGPT Terminal Relay %@ 已是最新版本。",
         kCurrentVersion];
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
}

- (void)showUpdateError:(NSString *)message {
    [NSApp activateIgnoringOtherApps:YES];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"無法檢查更新";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
}

- (void)copyHandoff:(id)sender {
    if (self.executing) { [self updateStatus:@"請等目前指令完成再切換專案"]; return; }
    [self.autoPilot stop];
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO; panel.canChooseDirectories = YES; panel.allowsMultipleSelection = NO;
    panel.message = @"選擇要交給 ChatGPT 接手的專案資料夾。";
    if ([panel runModal] != NSModalResponseOK) return;
    NSString *templatePath = [NSBundle.mainBundle pathForResource:@"HANDOFF_PROMPT" ofType:@"txt"];
    NSString *prompt = templatePath ? [NSString stringWithContentsOfFile:templatePath encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!prompt.length) { [self updateStatus:@"找不到接手提示範本"]; return; }
    prompt = [prompt stringByReplacingOccurrencesOfString:@"{{PROJECT_PATH}}" withString:panel.URL.path];
    NSPasteboard *p = NSPasteboard.generalPasteboard;
    [p clearContents]; [p setString:prompt forType:NSPasteboardTypeString];
    self.lastChangeCount = p.changeCount;
    [self updateStatus:@"接手提示已複製，請貼到 ChatGPT Chat 對話並填寫目標"];
    RelayLog(@"handoff_prompt_copied", @{});
}

- (void)updateAutoMenus {
    self.autoStartItem.enabled = !self.executing && !self.autoPilot.enabled && self.lastAccessibilityTrusted;
    self.autoStopItem.enabled = self.autoPilot.enabled;
    self.modeItem.title = self.autoPilot.enabled ? @"模式：全自動接續" : @"模式：只按複製";
}

- (void)startAuto:(id)sender {
    if (self.executing || !AXIsProcessTrusted()) { [self updateStatus:@"請先完成授權與目前指令"]; return; }
    NSRunningApplication *app = [self findRunningChatGPTUsingFallback:NULL];
    if (!app) { [self updateStatus:@"請先開啟 ChatGPT 對話"]; return; }
    [self.autoPilot stop];
    self.monitoring = YES;
    self.lastChangeCount = NSPasteboard.generalPasteboard.changeCount;
    self.autoPilot = [[RelayAutoPilot alloc] initWithSource:[[RelayAXAutoSource alloc] initWithApplication:app]];
    __weak RelayAppDelegate *weakSelf = self;
    [self.autoPilot startWithCommand:^(NSString *command) {
        RelayAppDelegate *strongSelf = weakSelf;
        strongSelf.lastChangeCount = NSPasteboard.generalPasteboard.changeCount;
        [strongSelf acceptCommand:command origin:@"automatic_response"];
    } status:^(NSString *status) {
        RelayAppDelegate *strongSelf = weakSelf;
        if (!strongSelf.executing) [strongSelf updateStatus:status];
    }];
    [self updateAutoMenus];
}

- (void)stopAuto:(id)sender {
    [self.autoPilot stop];
    [self updateStatus:self.executing ? @"已停止全自動，目前指令繼續處理" : @"已停止全自動，仍可按複製執行"];
}

- (void)updateStatus:(NSString *)status {
    [self updateAutoMenus];
    RelayLog(@"status", @{@"text":status, @"monitoring":@(self.monitoring), @"executing":@(self.executing)});
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"Relay %@ — %@", kCurrentVersion, status];
    self.statusMenuItem.title =
        [NSString stringWithFormat:@"狀態：%@", status];

    BOOL autoNeedsAttention = [status containsString:@"全自動已停止"] || [status containsString:@"全自動已結束"];
    self.statusItem.button.title = self.executing ? @"⇄ …" :
        (!self.lastAccessibilityTrusted ? @"⇄ 權限" :
         (autoNeedsAttention ? @"⇄ 查看" : (self.autoPilot.enabled ? @"⇄ 自動" : @"⇄ Relay")));

    self.startMenuItem.enabled = !self.monitoring;
    self.stopMenuItem.enabled = self.monitoring;
    self.retryMenuItem.enabled = self.monitoring && !self.executing && self.lastResult.length > 0;
    self.resultCopyMenuItem.enabled = !self.executing && self.lastResult.length > 0;
}

- (void)startMonitoring:(id)sender {
    self.monitoring = YES;

    self.lastChangeCount =
        NSPasteboard.generalPasteboard.changeCount;

    [self updateStatus:@"監聽中"];
}

- (void)stopMonitoring:(id)sender {
    self.monitoring = NO;
    [self.autoPilot stop];
    self.returnGeneration++;
    [self.delivery cancel];
    if (self.returnPending) [self endReturn:@"已停止，結果已保留"];
    [self updateStatus:@"已停止"];
}

- (void)quit:(id)sender {
    RelayLog(@"app_quit", @{@"executing":@(self.executing)});
    [self.autoPilot stop];
    [NSApp terminate:nil];
}

@end

int main(int argc, const char * argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSApplication *app =
            NSApplication.sharedApplication;

        RelayAppDelegate *delegate =
            [[RelayAppDelegate alloc] init];

        app.delegate = delegate;

        [app setActivationPolicy:
            NSApplicationActivationPolicyAccessory];

        [app run];
    }

    return 0;
}
