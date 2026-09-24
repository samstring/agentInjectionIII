import Foundation

/// Extra Agent-facing introspection compiled into the locally built
/// InjectionNext runtime. It deliberately stays out of the user's app target:
/// the app only loads the resulting injection bundle.
@objc(AgentInjectionRuntimeBridge)
@objcMembers
public final class AgentInjectionRuntimeBridge: NSObject {
    private static var lifetimeActive = false

    public static func callOrder() -> [String] {
        SwiftTrace.callOrder().map {
            $0.signature
        }
    }

    @discardableResult
    public static func startLifetimeTracking() -> Int {
        SwiftTrace.removeAllTraces()
        SwiftTrace.liveObjects.removeAll(
            keepingCapacity: true
        )
        SwiftTrace.swizzleFactory =
            SwiftTrace.LifetimeTracker.self

        let interposed =
            SwiftTrace.traceMainBundleMethods()
        SwiftTrace.traceMainBundle()
        lifetimeActive = true
        return interposed
    }

    public static func instanceCounts()
        -> [String: NSNumber] {
        var counts: [String: NSNumber] = [:]

        for (metadata, objects) in
            SwiftTrace.liveObjects {
            let type: Any.Type =
                unsafeBitCast(
                    metadata,
                    to: Any.Type.self
                )
            counts[_typeName(type)] =
                NSNumber(value: objects.count)
        }

        return counts
    }

    public static func stopLifetimeTracking() {
        SwiftTrace.removeAllTraces()
        SwiftTrace.swizzleFactory =
            SwiftTrace.Decorated.self
        lifetimeActive = false
    }

    public static func isLifetimeTracking()
        -> Bool {
        lifetimeActive
    }
}
