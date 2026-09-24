#import "AgentInjectionBootstrap.h"
#import "AgentTraceBridge.h"

@implementation AgentInjectionBootstrap

+ (void)start {
#if DEBUG
    NSBundle *mainBundle = NSBundle.mainBundle;

    NSString *embeddedPath =
        [mainBundle pathForResource:@"iOSInjection"
                             ofType:@"bundle"];

    if (embeddedPath.length > 0) {
        NSBundle *embedded = [NSBundle bundleWithPath:embeddedPath];
        if ([embedded load]) {
            NSLog(@"agentInjectionIII: loaded embedded runtime");
            return;
        }

        NSLog(@"agentInjectionIII: failed to load embedded runtime at %@",
              embeddedPath);
    }

    // Compatibility path for teammates that continue using InjectionIII.app.
    NSString *classicPath =
        @"/Applications/InjectionIII.app/Contents/Resources/iOSInjection.bundle";

    if ([[NSFileManager defaultManager] fileExistsAtPath:classicPath]) {
        NSBundle *classic = [NSBundle bundleWithPath:classicPath];
        if ([classic load]) {
            NSLog(@"agentInjectionIII: loaded InjectionIII.app runtime");
        }
    }
#endif
}

@end
