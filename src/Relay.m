#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import "RelayDelivery.h"

static NSString * const kCurrentVersion = @"0.5.0";
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
@end

@implementation RelayAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.monitoring = YES;
    self.executing = NO;
    self.lastChangeCount = NSPasteboard.generalPasteboard.changeCount;

    NSString *saved = [NSString stringWithContentsOfFile:RelaySavedResultPath()
                                               encoding:NSUTF8StringEncoding error:nil];
    self.lastResult = saved;
    [self setupStatusItem];
    [self requestAccessibilityPermission];
    [self startClipboardTimer];
    [self updateStatus:@"監聽中"];

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

    self.retryMenuItem = [[NSMenuItem alloc] initWithTitle:@"重試回傳上次結果" action:@selector(retryReturn:) keyEquivalent:@""];
    self.retryMenuItem.target = self;
    [menu addItem:self.retryMenuItem];
    self.resultCopyMenuItem = [[NSMenuItem alloc] initWithTitle:@"複製上次結果" action:@selector(copyResult:) keyEquivalent:@""];
    self.resultCopyMenuItem.target = self;
    [menu addItem:self.resultCopyMenuItem];
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
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
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
    if (!self.monitoring || self.executing) {
        return;
    }

    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    NSInteger changeCount = pasteboard.changeCount;

    if (changeCount == self.lastChangeCount) {
        return;
    }

    self.lastChangeCount = changeCount;

    NSString *text = [pasteboard stringForType:NSPasteboardTypeString];

    NSString *command = RelayParseCommand(text);
    if (!command) return;

    // Prevent accidental double-clicks from executing the exact same command twice.
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (self.lastExecutedCommand &&
        [self.lastExecutedCommand isEqualToString:command] &&
        (now - self.lastExecutedAt) < 3.0) {
        return;
    }

    self.lastExecutedCommand = command;
    self.lastExecutedAt = now;

    self.executing = YES;
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
    if (self.executing || !self.lastResult || !self.monitoring) return;
    self.executing = YES;
    [self beginReturn];
}

- (void)endReturn:(NSString *)status {
    self.returnPending = NO;
    self.executing = NO;
    self.delivery = nil;
    [self updateStatus:self.monitoring ? status : @"已停止，結果已保留"];
}

- (void)beginReturn {
    NSUInteger generation = ++self.returnGeneration;
    self.returnPending = YES;
    if (!self.monitoring) { [self endReturn:@"已停止，結果已保留"]; return; }
    if (!AXIsProcessTrusted()) { [self endReturn:@"需要輔助使用權限，結果已保留"]; return; }
    [self updateStatus:@"正在尋找 ChatGPT"];
    [self findOrLaunchChatGPTWithAttempt:0 completion:^(NSRunningApplication *app) {
        if (generation != self.returnGeneration) return;
        if (!self.monitoring || !app) { [self endReturn:@"找不到 ChatGPT，結果已保留"]; return; }
        if (![app activateWithOptions:NSApplicationActivateAllWindows]) {
            [self endReturn:@"無法喚醒 ChatGPT，請開啟後重試"]; return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != self.returnGeneration) return;
            if (!self.monitoring) { [self endReturn:@"已停止"]; return; }
            id<RelayTarget> target = [[RelayAXTarget alloc] initWithPID:app.processIdentifier];
            self.delivery = [[RelayDelivery alloc] initWithTarget:target];
            [self updateStatus:@"確認輸入框並回傳"];
            [self.delivery deliver:self.lastResult completion:^(BOOL sent, NSString *reason) {
                [self endReturn:sent ? @"已交付傳送，監聽中" : [reason stringByAppendingString:@"，結果已保留"]];
            }];
        });
    }];
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

- (void)updateStatus:(NSString *)status {
    self.statusMenuItem.title =
        [NSString stringWithFormat:@"狀態：%@", status];

    self.statusItem.button.title =
        self.executing ? @"⇄ …" : @"⇄ Relay";

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
    self.returnGeneration++;
    [self.delivery cancel];
    if (self.returnPending) [self endReturn:@"已停止，結果已保留"];
    [self updateStatus:@"已停止"];
}

- (void)quit:(id)sender {
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
