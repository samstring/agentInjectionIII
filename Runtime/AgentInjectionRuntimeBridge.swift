import Foundation

/// Extra Agent-facing introspection compiled into the locally built
/// InjectionNext runtime. It deliberately stays out of the user's app target:
/// the app only loads the resulting injection bundle.
@objc(AgentInjectionRuntimeBridge)
@objcMembers
public final class AgentInjectionRuntimeBridge: NSObject {
    private static var lifetimeActive = false
    private static var previousMethodInclusionPattern: String?

    public static func callOrder() -> [String] {
        SwiftTrace.callOrder().map {
            $0.signature
        }
    }

    @discardableResult
    public static func startLifetimeTracking() -> Int {
        startLifetimeTracking(
            filter: nil
        )
    }

    @objc(startLifetimeTrackingWithFilter:)
    @discardableResult
    public static func startLifetimeTracking(
        filter: String?
    ) -> Int {
        SwiftTrace.removeAllTraces()
        SwiftTrace.liveObjects.removeAll(
            keepingCapacity: true
        )

        if !lifetimeActive {
            previousMethodInclusionPattern =
                SwiftTrace.methodInclusionPattern
        }

        if let filter,
           !filter.isEmpty {
            SwiftTrace.methodInclusionPattern =
                filter
        }

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
        SwiftTrace.methodInclusionPattern =
            previousMethodInclusionPattern
        previousMethodInclusionPattern = nil
        lifetimeActive = false
    }

    public static func isLifetimeTracking()
        -> Bool {
        lifetimeActive
    }
}

/// Linker root used by install-runtime.sh. The runtime looks up
/// AgentInjectionRuntimeBridge dynamically with NSClassFromString(), so without
/// a hard linker root the class can be removed by -dead_strip even though its
/// Swift source was compiled.
@_cdecl("AgentInjectionRuntimeBridgeAnchor")
public func AgentInjectionRuntimeBridgeAnchor() -> UnsafeRawPointer {
    unsafeBitCast(
        AgentInjectionRuntimeBridge.self,
        to: UnsafeRawPointer.self
    )
}
