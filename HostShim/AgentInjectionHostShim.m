#import "AgentInjectionHostShim.h"

/// Host-only sentinel. The iOS InjectionNext runtime is not linked into
/// injectionctl/injectiond, but InjectionLite uses this class-name check to
/// decide whether it should start its standalone save watcher.
@interface InjectionNext : NSObject
@end

@implementation InjectionNext
@end

void AgentInjectionLinkHostShim(void) {
    // Referencing this symbol from Swift forces this object file into host
    // executables. Objective-C registers InjectionNext before +load methods run.
}
