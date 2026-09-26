#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Link anchor for the host-only InjectionNext sentinel class.
///
/// InjectionLite checks for an Objective-C class named "InjectionNext" during
/// +load before starting its standalone file watcher. agentInjectionIII owns
/// compilation/injection explicitly, so its host tools provide that sentinel
/// to keep the save watcher disabled.
FOUNDATION_EXPORT void AgentInjectionLinkHostShim(void);

NS_ASSUME_NONNULL_END
