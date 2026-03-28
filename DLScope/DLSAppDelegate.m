#import "DLSAppDelegate.h"
#import "DLSViewController.h"

@implementation DLSAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [[UIApplication sharedApplication] setStatusBarHidden:YES];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [[DLSViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
