#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Agent-only DEBUG bridge for streaming SwiftTrace output to injectiond.
///
/// Start this only after the embedded Agent injection runtime has loaded.
@interface AgentTraceBridge : NSObject
+ (void)start;
@end

NS_ASSUME_NONNULL_END
