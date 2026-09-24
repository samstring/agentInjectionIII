#import "AppDelegate.h"
#import "AgentInjectionBootstrap.h"
#import "SimulatorSmokeApp-Swift.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
#if DEBUG
    [AgentInjectionBootstrap start];
#endif

    self.window = [[UIWindow alloc]
        initWithFrame:UIScreen.mainScreen.bounds];

    SmokeViewController *controller =
        [SmokeViewController new];

    self.window.rootViewController =
        [[UINavigationController alloc]
            initWithRootViewController:controller];

    [self.window makeKeyAndVisible];
    return YES;
}

@end
