import Foundation
import CoreServices

final class PendingSourceStore: @unchecked Sendable {
    private let lock = NSLock()
    private let projectRoot: String?
    private var ordered: [String] = []
    private var known = Set<String>()

    init(projectRoot: String?) {
        self.projectRoot = projectRoot.map {
            Self.standardized($0)
        }
    }

    @discardableResult
    func add(_ files: [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        var added: [String] = []
        for input in files {
            let path = Self.standardized(input)
            guard known.insert(path).inserted else {
                continue
            }
            ordered.append(path)
            added.append(path)
        }
        return added
    }

    func markInjected(_ file: String) {
        let path = Self.standardized(file)

        lock.lock()
        known.remove(path)
        ordered.removeAll { $0 == path }
        lock.unlock()
    }

    func snapshot(
        watching: Bool
    ) -> PendingChangesResult {
        lock.lock()
        let files = ordered
        lock.unlock()

        return PendingChangesResult(
            projectRoot: projectRoot,
            watching: watching,
            files: files
        )
    }

    private static func standardized(
        _ path: String
    ) -> String {
        URL(
            fileURLWithPath:
                NSString(
                    string: path
                ).expandingTildeInPath
        )
        .standardizedFileURL
        .path
    }
}

final class ProjectFileWatcher: @unchecked Sendable {
    typealias Callback =
        @Sendable ([String]) -> Void

    let root: String

    private let callback: Callback
    private let queue = DispatchQueue(
        label: "AgentInjectionIII.file-watcher",
        qos: .utility
    )
    private var stream: FSEventStreamRef?

    init?(
        root: String,
        callback: @escaping Callback
    ) {
        let resolved = URL(
            fileURLWithPath:
                NSString(
                    string: root
                ).expandingTildeInPath
        )
        .standardizedFileURL
        .path

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: resolved,
            isDirectory: &isDirectory
        ),
        isDirectory.boolValue else {
            return nil
        }

        self.root = resolved
        self.callback = callback

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self)
                .toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = {
            _, info, count, paths,
            flags, _ in
            guard let info else {
                return
            }

            let watcher =
                Unmanaged<ProjectFileWatcher>
                    .fromOpaque(info)
                    .takeUnretainedValue()

            watcher.handle(
                paths: paths,
                flags: flags,
                count: count
            )
        }

        let flags =
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer
            )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [resolved] as CFArray,
            FSEventStreamEventId(
                kFSEventStreamEventIdSinceNow
            ),
            0.15,
            flags
        ) else {
            return nil
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(
            stream,
            queue
        )

        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    deinit {
        guard let stream else {
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func handle(
        paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<
            FSEventStreamEventFlags
        >,
        count: Int
    ) {
        let values =
            unsafeBitCast(
                paths,
                to: NSArray.self
            )

        var changed: [String] = []
        var seen = Set<String>()

        for index in 0..<min(
            count,
            values.count
        ) {
            let eventFlags = flags[index]
            let interesting =
                eventFlags &
                FSEventStreamEventFlags(
                    kFSEventStreamEventFlagItemCreated |
                    kFSEventStreamEventFlagItemRenamed |
                    kFSEventStreamEventFlagItemModified
                )

            guard interesting != 0,
                  let raw =
                    values[index] as? String,
                  let source =
                    injectableSource(raw),
                  seen.insert(source).inserted
            else {
                continue
            }

            changed.append(source)
        }

        if !changed.isEmpty {
            callback(changed)
        }
    }

    private func injectableSource(
        _ input: String
    ) -> String? {
        let url = URL(
            fileURLWithPath: input
        ).standardizedFileURL
        let path = url.path

        guard path == root ||
              path.hasPrefix(root + "/")
        else {
            return nil
        }

        let extensionName =
            url.pathExtension.lowercased()
        guard [
            "swift", "m", "mm",
            "cpp", "cc", "cxx"
        ].contains(extensionName) else {
            return nil
        }

        let name =
            url.lastPathComponent.lowercased()
        if name == "main.m" ||
           name == "main.mm" {
            return nil
        }

        let excluded = [
            "/DerivedData/",
            "/InjectionProject/",
            "/.DocumentRevisions-",
            "/.git/"
        ]

        guard !excluded.contains(
            where: path.contains
        ) else {
            return nil
        }

        return path
    }
}
