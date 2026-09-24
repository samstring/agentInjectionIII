import Foundation

public struct ProjectReorderPlan: Codable, Sendable {
    public let projectPath: String
    public let projectFile: String
    public let backupPath: String
    public let changed: Bool
    public let orderedFiles: [String]
    public let matchedFiles: [String]

    public init(
        projectPath: String,
        projectFile: String,
        backupPath: String,
        changed: Bool,
        orderedFiles: [String],
        matchedFiles: [String]
    ) {
        self.projectPath = projectPath
        self.projectFile = projectFile
        self.backupPath = backupPath
        self.changed = changed
        self.orderedFiles = orderedFiles
        self.matchedFiles = matchedFiles
    }
}

public final class ProjectReorderer {
    private let fileManager = FileManager.default

    public init() {}

    public func reorder(
        project: String?,
        projectRoot: String?,
        signatures: [String],
        apply: Bool
    ) -> Result<ProjectReorderPlan, ControlError> {
        guard let projectURL = resolveProject(
            project: project,
            projectRoot: projectRoot
        ) else {
            return .failure(
                ControlError(
                    code: "PROJECT_NOT_FOUND",
                    message: "Could not resolve an .xcodeproj. Pass one explicitly or set --project to a project directory."
                )
            )
        }

        let pbxproj = projectURL
            .appendingPathComponent(
                "project.pbxproj"
            )

        guard fileManager.fileExists(
            atPath: pbxproj.path
        ) else {
            return .failure(
                ControlError(
                    code: "PBXPROJ_NOT_FOUND",
                    message: "Xcode project file does not exist: \(pbxproj.path)"
                )
            )
        }

        var encoding: String.Encoding = .utf8
        let original: String
        do {
            original = try String(
                contentsOf: pbxproj,
                usedEncoding: &encoding
            )
        } catch {
            return .failure(
                ControlError(
                    code: "PBXPROJ_READ_FAILED",
                    message: "Unable to read \(pbxproj.path): \(error)"
                )
            )
        }

        let order = Self.sourceOrder(
            signatures: signatures
        )

        guard !order.isEmpty else {
            return .failure(
                ControlError(
                    code: "CALL_ORDER_EMPTY",
                    message: "No usable Swift type names were found in the call-order snapshot."
                )
            )
        }

        let rewritten = Self.rewrite(
            project: original,
            order: order
        )

        let backupPath =
            pbxproj.path + ".preorder"

        let plan = ProjectReorderPlan(
            projectPath: projectURL.path,
            projectFile: pbxproj.path,
            backupPath: backupPath,
            changed: rewritten.text != original,
            orderedFiles: order
                .sorted { $0.value < $1.value }
                .map(\.key),
            matchedFiles: rewritten.matchedFiles
        )

        guard apply,
              plan.changed else {
            return .success(plan)
        }

        do {
            if !fileManager.fileExists(
                atPath: backupPath
            ) {
                try original.write(
                    toFile: backupPath,
                    atomically: true,
                    encoding: encoding
                )
            }

            try rewritten.text.write(
                to: pbxproj,
                atomically: true,
                encoding: encoding
            )
            return .success(plan)
        } catch {
            return .failure(
                ControlError(
                    code: "PROJECT_REORDER_WRITE_FAILED",
                    message: "Unable to reorder \(pbxproj.path): \(error)"
                )
            )
        }
    }

    static func sourceOrder(
        signatures: [String]
    ) -> [String: Int] {
        var orders = [
            "AppDelegate.swift": 0
        ]
        var next = 1
        var seen = Set<String>()

        for signature in signatures {
            let parts = signature
                .components(
                    separatedBy: "."
                )
            guard parts.count >= 3 else {
                continue
            }

            let typeName = parts[1]
            guard !typeName.isEmpty,
                  !typeName.contains("("),
                  seen.insert(typeName).inserted
            else {
                continue
            }

            let file = typeName + ".swift"
            if orders[file] == nil {
                orders[file] = next
                next += 1
            }
        }

        return orders
    }

    static func rewrite(
        project: String,
        order: [String: Int]
    ) -> (
        text: String,
        matchedFiles: [String]
    ) {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?ms)(isa = PBXSourcesBuildPhase;.*?files = \(\n)(.*?)(\n\s*\);)"#
        ) else {
            return (project, [])
        }

        let nsProject = project as NSString
        let fullRange = NSRange(
            location: 0,
            length: nsProject.length
        )
        let matches = regex.matches(
            in: project,
            range: fullRange
        )

        guard !matches.isEmpty else {
            return (project, [])
        }

        var result = project
        var matched = Set<String>()

        for match in matches.reversed() {
            guard match.numberOfRanges >= 4,
                  let bodyRange = Range(
                    match.range(at: 2),
                    in: project
                  )
            else {
                continue
            }

            let body = String(
                project[bodyRange]
            )
            let lines = body
                .split(
                    separator: "\n",
                    omittingEmptySubsequences: false
                )
                .map(String.init)

            let ranked = lines.enumerated().map {
                index,
                line -> (
                    line: String,
                    index: Int,
                    rank: Int
                ) in
                guard let file =
                    sourceFileName(
                        from: line
                    ),
                    let rank = order[file]
                else {
                    return (
                        line,
                        index,
                        Int.max
                    )
                }

                matched.insert(file)
                return (
                    line,
                    index,
                    rank
                )
            }

            let sorted = ranked.sorted {
                if $0.rank == $1.rank {
                    return $0.index < $1.index
                }
                return $0.rank < $1.rank
            }
            .map(\.line)
            .joined(separator: "\n")

            result.replaceSubrange(
                bodyRange,
                with: sorted
            )
        }

        let matchedFiles = order
            .sorted { $0.value < $1.value }
            .map(\.key)
            .filter { matched.contains($0) }

        return (
            result,
            matchedFiles
        )
    }

    private static func sourceFileName(
        from line: String
    ) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"/\* (.+?) in Sources \*/"#
        ) else {
            return nil
        }

        let ns = line as NSString
        let range = NSRange(
            location: 0,
            length: ns.length
        )
        guard let match = regex.firstMatch(
            in: line,
            range: range
        ),
        match.numberOfRanges > 1 else {
            return nil
        }

        return ns.substring(
            with: match.range(at: 1)
        )
    }

    private func resolveProject(
        project: String?,
        projectRoot: String?
    ) -> URL? {
        if let project {
            return normalizedProject(
                URL(
                    fileURLWithPath:
                        NSString(
                            string: project
                        ).expandingTildeInPath
                )
            )
        }

        guard let projectRoot else {
            return nil
        }

        let root = URL(
            fileURLWithPath:
                NSString(
                    string: projectRoot
                ).expandingTildeInPath
        )

        if let normalized =
            normalizedProject(root) {
            return normalized
        }

        guard let contents =
            try? fileManager
                .contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys:
                        nil,
                    options: [
                        .skipsHiddenFiles
                    ]
                )
        else {
            return nil
        }

        return contents
            .filter {
                $0.pathExtension ==
                    "xcodeproj"
            }
            .sorted {
                $0.lastPathComponent <
                    $1.lastPathComponent
            }
            .first
    }

    private func normalizedProject(
        _ url: URL
    ) -> URL? {
        if url.pathExtension ==
            "xcodeproj" {
            return url
        }

        if url.pathExtension ==
            "xcworkspace" {
            let sibling = url
                .deletingPathExtension()
                .appendingPathExtension(
                    "xcodeproj"
                )
            if fileManager.fileExists(
                atPath: sibling.path
            ) {
                return sibling
            }
        }

        return nil
    }
}
