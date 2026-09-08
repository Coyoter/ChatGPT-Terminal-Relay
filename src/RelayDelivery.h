#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

NSString *RelayParseCommand(NSString *text);
NSString *RelaySavedResultPath(void);
NSString *RelayLogDirectory(void);

@protocol RelayTarget <NSObject>
- (BOOL)isValid;
- (NSString *)readText;
- (BOOL)writeText:(NSString *)text;
- (BOOL)canSend;
- (BOOL)sendText:(NSString *)text;
@end

@interface RelayDelivery : NSObject
- (instancetype)initWithTarget:(id<RelayTarget>)target;
- (void)deliver:(NSString *)text completion:(void (^)(BOOL, NSString *))completion;
- (void)cancel;
@end

@interface RelayAXTarget : NSObject <RelayTarget>
- (instancetype)initWithPID:(pid_t)pid;
@end
