#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

// Exercise the real macOS adapter against a synthetic accessibility tree.
// No actual applications, UI, or clipboard are read or controlled.
static NSDictionary *fakeApp;
static AXUIElementRef FakeApplication(pid_t pid) { return (AXUIElementRef)CFRetain((__bridge CFTypeRef)fakeApp); }
static AXError FakeCopy(AXUIElementRef element, CFStringRef attribute, CFTypeRef *out) {
    id value = ((__bridge NSDictionary *)element)[(__bridge NSString *)attribute];
    if (!value) return kAXErrorNoValue;
    *out = CFRetain((__bridge CFTypeRef)value);
    return kAXErrorSuccess;
}
static AXError FakeSettable(AXUIElementRef element, CFStringRef attribute, Boolean *out) {
    *out = CFEqual(attribute, kAXValueAttribute) && [((__bridge NSDictionary *)element)[@"writable"] boolValue];
    return kAXErrorSuccess;
}
static AXError FakeTimeout(AXUIElementRef element, float timeout) { return kAXErrorSuccess; }
#define AXUIElementCreateApplication FakeApplication
#define AXUIElementCopyAttributeValue FakeCopy
#define AXUIElementIsAttributeSettable FakeSettable
#define AXUIElementSetMessagingTimeout FakeTimeout
#import "../src/RelayDelivery.m"

static NSDictionary *Editor(NSString *identifier, NSString *label, BOOL writable) {
    return @{(__bridge NSString *)kAXRoleAttribute:(__bridge NSString *)kAXTextAreaRole,
             (__bridge NSString *)kAXValueAttribute:@"", @"writable":@(writable),
             (__bridge NSString *)kAXDescriptionAttribute:label,
             (__bridge NSString *)kAXIdentifierAttribute:identifier,
             (__bridge NSString *)kAXEnabledAttribute:@YES};
}
static id Discover(NSArray *editors) {
    fakeApp = @{(__bridge NSString *)kAXFocusedWindowAttribute:
        @{(__bridge NSString *)kAXTitleAttribute:@"fixture",
          (__bridge NSString *)kAXChildrenAttribute:editors}};
    return [[[RelayAXTarget alloc] initWithPID:123] valueForKey:@"editor"];
}
static void Check(BOOL condition, const char *name) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", name); exit(1); }
    printf("PASS: %s\n", name);
}
int main(void) {
    @autoreleasepool {
        NSDictionary *unknown = Editor(@"new-composer", @"unrecognized localized label", YES);
        Check(Discover(@[unknown]) == unknown, "actual adapter accepts sole writable composer with unknown label");
        Check(!Discover(@[unknown, Editor(@"other", @"another label", YES)]), "ambiguous writable text areas are rejected");
        Check(!Discover(@[Editor(@"unknown", @"unknown", NO)]), "read-only text area is rejected");
        NSDictionary *known = Editor(@"prompt-textarea", @"unknown", YES);
        Check(Discover(@[unknown, known]) == known, "known composer identifier wins over unrelated editor");
        Check(!Discover(@[]), "missing editor is rejected");
        NSDictionary *disabled = @{(__bridge NSString *)kAXRoleAttribute:(__bridge NSString *)kAXTextAreaRole,
            (__bridge NSString *)kAXValueAttribute:@"", @"writable":@YES,
            (__bridge NSString *)kAXEnabledAttribute:@NO};
        Check(!Discover(@[disabled]), "disabled text area is rejected");
        puts("6 native adapter regression tests passed");
    }
    return 0;
}
