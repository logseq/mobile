#import "LogseqAuthenticationUI.h"
#import <AuthenticationServices/AuthenticationServices.h>
#include <dlfcn.h>

// Use SDK declarations for type checking, without linking the framework at
// launch. Resolve framework classes after loading the public system framework.
@interface LogseqWebAuthenticationSession () <ASWebAuthenticationPresentationContextProviding>
@property(nonatomic, strong) ASWebAuthenticationSession *nativeSession;
@property(nonatomic, weak) UIWindow *anchor;
@property(nonatomic, copy) void (^completion)(NSURL *, NSError *);
@property(nonatomic) NSUInteger generation;
@end

static NSError *LogseqAuthenticationError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"LogseqWebAuthentication" code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation LogseqWebAuthenticationSession

- (void)authenticateURL:(NSURL *)URL
        callbackScheme:(NSString *)callbackScheme
                anchor:(UIWindow *)anchor
            completion:(void (^)(NSURL *, NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Browser authentication must run on the main thread");
    if (self.completion) {
        completion(nil, LogseqAuthenticationError(2, @"Sign-in is already in progress."));
        return;
    }
    NSString *scheme = URL.scheme.lowercaseString;
    if ((![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) || callbackScheme.length == 0) {
        completion(nil, LogseqAuthenticationError(3, @"The sign-in address or callback scheme is invalid."));
        return;
    }
    Class sessionClass = NSClassFromString(@"ASWebAuthenticationSession");
    if (!sessionClass) {
        // Keep the handle for the lifetime of its Objective-C classes. dyld also
        // resolves this SDK path correctly inside the simulator's shared cache.
        static void *framework;
        if (!framework) {
            framework = dlopen("/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices", RTLD_LAZY | RTLD_LOCAL);
        }
        if (!framework) {
            completion(nil, LogseqAuthenticationError(101, @"Could not open the secure sign-in page."));
            return;
        }
        sessionClass = NSClassFromString(@"ASWebAuthenticationSession");
    }
    if (!sessionClass) {
        completion(nil, LogseqAuthenticationError(102, @"Could not open the secure sign-in page."));
        return;
    }
    self.generation += 1;
    NSUInteger generation = self.generation;
    self.anchor = anchor;
    self.completion = completion;
    __weak LogseqWebAuthenticationSession *weakSelf = self;
    ASWebAuthenticationSessionCompletionHandler handler = ^(NSURL *callbackURL, NSError *error) {
        void (^deliver)(void) = ^{
            [weakSelf finishWithURL:callbackURL error:error generation:generation];
        };
        if (NSThread.isMainThread) {
            deliver();
        } else {
            dispatch_async(dispatch_get_main_queue(), deliver);
        }
    };
    ASWebAuthenticationSession *session;
    if (@available(iOS 17.4, *)) {
        Class callbackClass = NSClassFromString(@"ASWebAuthenticationSessionCallback");
        ASWebAuthenticationSessionCallback *callback = [callbackClass callbackWithCustomScheme:callbackScheme];
        session = [[sessionClass alloc] initWithURL:URL callback:callback completionHandler:handler];
    } else {
        session = [[sessionClass alloc] initWithURL:URL callbackURLScheme:callbackScheme completionHandler:handler];
    }
    self.nativeSession = session;
    session.presentationContextProvider = self;
    session.prefersEphemeralWebBrowserSession = YES;
    if (![session start]) {
        [self finishWithURL:nil error:LogseqAuthenticationError(103, @"Could not open the secure sign-in page.")
                 generation:generation];
    }
}

- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    return self.anchor ?: [[UIWindow alloc] init];
}

- (void)finishWithURL:(NSURL *)URL error:(NSError *)error generation:(NSUInteger)generation {
    if (generation != self.generation || !self.completion) {
        return;
    }
    void (^completion)(NSURL *, NSError *) = self.completion;
    self.completion = nil;
    self.nativeSession = nil;
    self.anchor = nil;
    completion(URL, URL ? nil : (error ?: LogseqAuthenticationError(1, @"Could not open the secure sign-in page.")));
}

- (void)cancel {
    [self.nativeSession cancel];
    [self finishWithURL:nil error:LogseqAuthenticationError(4, @"Sign-in was cancelled.") generation:self.generation];
}

- (void)dealloc {
    [_nativeSession cancel];
}

@end
