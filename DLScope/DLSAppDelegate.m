#import "DLSAppDelegate.h"
#import "DLSViewController.h"

@implementation DLSAppDelegate

- (void)dealloc {
    [_window release];
    [super dealloc];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [[UIApplication sharedApplication] setStatusBarHidden:YES];

    UIWindow *window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window = window;
    [window release];

    DLSViewController *vc = [[DLSViewController alloc] init];
    self.window.rootViewController = vc;
    [vc release];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
