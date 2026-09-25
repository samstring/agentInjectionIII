#import "SmokeApplication.h"

@implementation SmokeApplication

- (void)sendEvent:(UIEvent *)event {
    NSSet<UITouch *> *touches = event.allTouches;
    BOOL hasReplayTouch = NO;

    for (UITouch *touch in touches) {
        if (touch.phase == UITouchPhaseBegan ||
            touch.phase == UITouchPhaseEnded ||
            touch.phase == UITouchPhaseCancelled) {
            hasReplayTouch = YES;
            break;
        }
    }

    if (hasReplayTouch) {
        NSURL *documents = [[NSFileManager defaultManager]
            URLsForDirectory:NSDocumentDirectory
            inDomains:NSUserDomainMask].firstObject;
        NSURL *marker = [documents
            URLByAppendingPathComponent:@"agentInjection-touch-event.txt"];
        [@"REPLAYED"
            writeToURL:marker
            atomically:YES
            encoding:NSUTF8StringEncoding
            error:nil];
    }

    [super sendEvent:event];
}

@end
