#import <Cocoa/Cocoa.h>

NSString *RelayCommandFromResponse(NSString *text);

@interface RelayAutoSnapshot : NSObject
@property BOOL available;
@property BOOL generating;
@property BOOL idle;
@property id responseCopyButton;
@property NSString *windowTitle;
@end

@protocol RelayAutoSource <NSObject>
- (RelayAutoSnapshot *)snapshot;
- (BOOL)copyResponse:(id)button windowTitle:(NSString *)title;
- (NSInteger)clipboardChangeCount;
- (NSString *)clipboardText;
@optional
- (BOOL)clickResponse:(id)button windowTitle:(NSString *)title stillActive:(BOOL (^)(void))active;
@end

@interface RelayAutoPilot : NSObject
@property(readonly) BOOL copying;
@property(readonly) BOOL enabled;
- (instancetype)initWithSource:(id<RelayAutoSource>)source;
- (void)startWithCommand:(void (^)(NSString *))command status:(void (^)(NSString *))status;
- (void)poll;
- (void)suspend;
- (void)resume;
- (void)stop;
@end

@interface RelayAXAutoSource : NSObject <RelayAutoSource>
- (instancetype)initWithApplication:(NSRunningApplication *)app;
@end
