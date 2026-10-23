#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Browser authentication is loaded only when an interactive sign-in begins.
NS_SWIFT_UI_ACTOR
@interface LogseqWebAuthenticationSession : NSObject

- (void)authenticateURL:(NSURL *)URL
        callbackScheme:(NSString *)callbackScheme
                anchor:(UIWindow *)anchor
            completion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion
    NS_SWIFT_NAME(authenticate(_:callbackScheme:anchor:completion:));
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
