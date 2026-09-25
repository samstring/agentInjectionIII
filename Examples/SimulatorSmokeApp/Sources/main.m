#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "SmokeApplication.h"

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(
            argc,
            argv,
            NSStringFromClass(SmokeApplication.class),
            NSStringFromClass(AppDelegate.class)
        );
    }
}
