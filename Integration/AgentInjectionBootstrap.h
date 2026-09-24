#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AgentInjectionBootstrap : NSObject

/// Loads the developer-local embedded runtime when present.
/// If it is absent, optionally falls back to the team's existing
/// /Applications/InjectionIII.app bundle.
+ (void)start;

@end

NS_ASSUME_NONNULL_END
