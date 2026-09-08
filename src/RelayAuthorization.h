#import <Foundation/Foundation.h>
BOOL RelayPrepareAuthorization(NSString *fingerprint, NSString *statePath, BOOL (^reset)(void));
BOOL RelayEnsureAuthorizationForInstalledBuild(void);
