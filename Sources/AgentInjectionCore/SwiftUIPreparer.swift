import Foundation
import SwiftRegexD

public final class SwiftUIPreparer {
    public struct Result: Sendable {
        public let filesEdited: Int
        public let changes: Int
        public let files: [String]

        public init(
            filesEdited: Int,
            changes: Int,
            files: [String]
        ) {
            self.filesEdited = filesEdited
            self.changes = changes
            self.files = files
        }
    }

    public init() {}

    @discardableResult
    public func prepareSource(
        _ source: String
    ) throws -> Result {
        let fileURL = URL(fileURLWithPath: source)
        let original = try String(contentsOf: fileURL)

        var patched = original
        var changes = 0

        let bodyPattern = #"""
            ^((\s+)(public )?(var body:|func body\([^)]*\) -\>) some View \{\n\#
            (\2(?!    (if|switch|ForEach) )\s+(?!\.enableInjection)\S.*\n|(\s*|#.+)\n)+)(?<!#endif\n)\2\}\n
            """#.anchorsMatchLines

        let beforeBodyPatch = patched
        patched[bodyPattern] = """
            $2#if DEBUG
            $2@ObserveInjection var forceRedraw
            $2#endif

            $1$2    .enableInjection()
            $2}

            """
        if patched != beforeBodyPatch {
            changes += 1
        }

        if (patched.contains("class AppDelegate") ||
            patched.contains("@main\n")) &&
            !patched.contains("InjectionObserver") {
            if !patched.contains("import SwiftUI") {
                patched += "\nimport SwiftUI\n"
            }

            patched += Self.swiftUISupport
            changes += 1
        }

        guard patched != original else {
            return Result(
                filesEdited: 0,
                changes: 0,
                files: []
            )
        }

        try patched.write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )

        return Result(
            filesEdited: 1,
            changes: changes,
            files: [source]
        )
    }

    public func prepareProject(
        sources: [String]
    ) -> Result {
        var filesEdited = 0
        var totalChanges = 0
        var files: [String] = []

        for source in sources
            where source.hasSuffix(".swift") {
            do {
                let result = try prepareSource(source)
                filesEdited += result.filesEdited
                totalChanges += result.changes
                files += result.files
            } catch {
                continue
            }
        }

        return Result(
            filesEdited: filesEdited,
            changes: totalChanges,
            files: files
        )
    }

    private static let swiftUISupport = """

        #if canImport(HotSwiftUI)
        @_exported import HotSwiftUI
        #elseif canImport(Inject)
        @_exported import Inject
        #else

        #if DEBUG
        import Combine

        public class InjectionObserver: ObservableObject {
            public static let shared = InjectionObserver()
            @Published var injectionNumber = 0
            var cancellable: AnyCancellable? = nil
            let publisher = PassthroughSubject<Void, Never>()

            init() {
                cancellable = NotificationCenter.default.publisher(
                    for: Notification.Name(
                        "INJECTION_BUNDLE_NOTIFICATION"
                    )
                )
                .sink { [weak self] _ in
                    self?.injectionNumber += 1
                    self?.publisher.send()
                }
            }
        }

        extension SwiftUI.View {
            public func eraseToAnyView()
                -> some SwiftUI.View {
                AnyView(self)
            }

            public func enableInjection()
                -> some SwiftUI.View {
                eraseToAnyView()
            }

            public func onInjection(
                bumpState: @escaping () -> ()
            ) -> some SwiftUI.View {
                onReceive(
                    InjectionObserver.shared.publisher,
                    perform: bumpState
                )
                .eraseToAnyView()
            }
        }

        @available(
            iOS 13.0,
            macOS 10.15,
            tvOS 13.0,
            watchOS 6.0,
            *
        )
        @propertyWrapper
        public struct ObserveInjection:
            DynamicProperty {
            @ObservedObject private var observer =
                InjectionObserver.shared

            public init() {}

            public private(set)
            var wrappedValue: Int {
                get { 0 }
                set {}
            }
        }
        #else
        extension SwiftUI.View {
            @inline(__always)
            public func eraseToAnyView()
                -> some SwiftUI.View {
                self
            }

            @inline(__always)
            public func enableInjection()
                -> some SwiftUI.View {
                self
            }

            @inline(__always)
            public func onInjection(
                bumpState: @escaping () -> ()
            ) -> some SwiftUI.View {
                self
            }
        }

        @available(
            iOS 13.0,
            macOS 10.15,
            tvOS 13.0,
            watchOS 6.0,
            *
        )
        @propertyWrapper
        public struct ObserveInjection {
            public init() {}

            public private(set)
            var wrappedValue: Int {
                get { 0 }
                set {}
            }
        }
        #endif
        #endif

        """
}
