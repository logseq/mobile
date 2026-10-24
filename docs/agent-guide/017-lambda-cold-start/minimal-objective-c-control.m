#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <stdio.h>
#include <unistd.h>

// Standalone attribution control. It is not the application's launch path.
static double birth, enteredMain, launched, connected, contentCreated, keyWindow, committed;
static double milliseconds(void) { return (CACurrentMediaTime() - birth) * 1000; }

@interface ControlLabel : UILabel
@property(nonatomic) BOOL wasDrawn;
@end
@implementation ControlLabel
- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:rect];
    self.wasDrawn = YES;
}
@end

@interface ContentController : UIViewController
@property(nonatomic, strong) NSArray<ControlLabel *> *labels;
@end
@implementation ContentController
- (void)loadView {
    UIView *root = [UIView new];
    root.backgroundColor = UIColor.systemBackgroundColor;
    NSMutableArray *labels = [NSMutableArray new];
    for (NSInteger i = 0; i < 5; i++) {
        ControlLabel *label = [ControlLabel new];
        label.text = [NSString stringWithFormat:@"Journal content row %ld", (long)i + 1];
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        label.textColor = UIColor.labelColor;
        label.numberOfLines = 1;
        label.accessibilityIdentifier = [NSString stringWithFormat:@"control.title.%ld", (long)i];
        [root addSubview:label];
        [labels addObject:label];
    }
    self.labels = labels;
    self.view = root;
    contentCreated = milliseconds();
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    for (NSInteger i = 0; i < self.labels.count; i++) {
        self.labels[i].frame = CGRectMake(24, self.view.safeAreaInsets.top + 32 + i * 40,
                                         self.view.bounds.size.width - 48, 36);
    }
}
@end

static NSInteger visibleDrawnTitles(UIView *view, UIWindow *window) {
    if (view.hidden || view.alpha <= 0.01) return 0;
    NSInteger count = 0;
    if ([view isKindOfClass:ControlLabel.class]) {
        ControlLabel *label = (ControlLabel *)view;
        CGRect rect = [label convertRect:label.bounds toView:window];
        if (label.wasDrawn && label.text.length > 0 && CGRectIntersectsRect(rect, window.bounds)) count++;
    }
    for (UIView *child in view.subviews) count += visibleDrawnTitles(child, window);
    return count;
}

@interface FrameProbe : NSObject
@property(nonatomic, strong) id updates;
@property(nonatomic, strong) CADisplayLink *display;
@property(nonatomic) double presentation;
@property(nonatomic) NSInteger titles;
- (void)windowBecameKey:(NSNotification *)notification;
@end
@implementation FrameProbe
- (void)windowBecameKey:(NSNotification *)notification {
    UIWindow *window = notification.object;
    if (!window.windowScene || !window.rootViewController || self.updates) return;
    keyWindow = milliseconds();
    if (@available(iOS 18.0, *)) {
        UIUpdateLink *updates = [UIUpdateLink updateLinkForWindowScene:window.windowScene];
        [updates addActionToPhase:UIUpdateActionPhase.afterCATransactionCommit
                         handler:^(UIUpdateLink *link, UIUpdateInfo *info) {
            NSInteger titles = visibleDrawnTitles(window, window);
            if (titles != 5) return;
            committed = milliseconds();
            self.titles = titles;
            self.presentation = MAX(CACurrentMediaTime(), info.estimatedPresentationTime);
            link.enabled = NO;
        }];
        self.updates = updates;
        updates.enabled = YES;
        self.display = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        [self.display addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    } else {
        fprintf(stderr, "Precise content observation requires iOS 18\n");
        exit(1);
    }
}
- (void)tick:(CADisplayLink *)display {
    if (self.presentation == 0 || display.timestamp < self.presentation) return;
    [display invalidate];
    double observed = milliseconds();
    const char *mode = getenv("LOGSEQ_FRAME_CONTROL_MODE") ?: "objc-uikit";
    printf("MINIMAL_FRAME_RESULT {\"mode\":\"%s\",\"stages_ms\":{"
           "\"main_entry\":%.6f,\"delegate_launch\":%.6f,\"scene_connect\":%.6f,"
           "\"native_content_created\":%.6f,\"window_became_key\":%.6f,"
           "\"first_commit\":%.6f,\"first_display_after_commit\":%.6f},"
           "\"nonempty_drawn_titles\":%ld}\n",
           mode, enteredMain, launched, connected, contentCreated, keyWindow,
           committed, observed, (long)self.titles);
    exit(0);
}
@end

@interface ControlSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation ControlSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
       options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    connected = milliseconds();
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [ContentController new];
    [self.window makeKeyAndVisible];
}
@end

@interface ControlApplicationDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ControlApplicationDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    launched = milliseconds();
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Control" sessionRole:session.role];
    configuration.delegateClass = ControlSceneDelegate.class;
    return configuration;
}
@end

int main(int argc, char **argv) {
    setbuf(stdout, NULL);
    struct kinfo_proc process;
    size_t size = sizeof(process);
    int query[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    if (sysctl(query, 4, &process, &size, NULL, 0) != 0) return 1;
    struct timespec wall;
    clock_gettime(CLOCK_REALTIME, &wall);
    double started = process.kp_proc.p_starttime.tv_sec + process.kp_proc.p_starttime.tv_usec / 1e6;
    birth = CACurrentMediaTime() - (wall.tv_sec + wall.tv_nsec / 1e9 - started);
    enteredMain = milliseconds();
    @autoreleasepool {
        FrameProbe *probe = [FrameProbe new];
        [NSNotificationCenter.defaultCenter addObserver:probe selector:@selector(windowBecameKey:)
                                                   name:UIWindowDidBecomeKeyNotification object:nil];
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ControlApplicationDelegate.class));
    }
}
