import XCTest
import Foundation
@testable import AgentInjectionCore

final class ProjectReordererTests: XCTestCase {
    func testSourceOrderUsesUpstreamTypeNameRule() {
        let order = ProjectReorderer.sourceOrder(
            signatures: [
                "MyApp.HomeViewController.viewDidLoad()",
                "MyApp.FeedService.load()",
                "MyApp.HomeViewController.render()",
                "invalid"
            ]
        )

        XCTAssertEqual(
            order["AppDelegate.swift"],
            0
        )
        XCTAssertEqual(
            order["HomeViewController.swift"],
            1
        )
        XCTAssertEqual(
            order["FeedService.swift"],
            2
        )
    }

    func testPreviewAndApplyReorderSourcesBuildPhase() throws {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "agentInjectionIII-reorder-\(UUID().uuidString)"
            )
        defer {
            try? FileManager.default
                .removeItem(at: root)
        }

        let project = root
            .appendingPathComponent(
                "Demo.xcodeproj"
            )
        try FileManager.default
            .createDirectory(
                at: project,
                withIntermediateDirectories: true
            )

        let pbxproj = project
            .appendingPathComponent(
                "project.pbxproj"
            )

        let original = """
        /* Begin PBXSourcesBuildPhase section */
                123 = {
                    isa = PBXSourcesBuildPhase;
                    buildActionMask = 2147483647;
                    files = (
                        001 /* FeedService.swift in Sources */,
                        002 /* Other.swift in Sources */,
                        003 /* AppDelegate.swift in Sources */,
                        004 /* HomeViewController.swift in Sources */,
                    );
                    runOnlyForDeploymentPostprocessing = 0;
                };
        /* End PBXSourcesBuildPhase section */
        """

        try original.write(
            to: pbxproj,
            atomically: true,
            encoding: .utf8
        )

        let reorderer = ProjectReorderer()
        let signatures = [
            "Demo.HomeViewController.viewDidLoad()",
            "Demo.FeedService.load()"
        ]

        let preview: ProjectReorderPlan
        switch reorderer.reorder(
            project: project.path,
            projectRoot: nil,
            signatures: signatures,
            apply: false
        ) {
        case .failure(let error):
            return XCTFail(error.message)
        case .success(let plan):
            preview = plan
        }

        XCTAssertTrue(preview.changed)
        XCTAssertEqual(
            preview.matchedFiles,
            [
                "AppDelegate.swift",
                "HomeViewController.swift",
                "FeedService.swift"
            ]
        )
        XCTAssertEqual(
            try String(
                contentsOf: pbxproj,
                encoding: .utf8
            ),
            original
        )

        switch reorderer.reorder(
            project: project.path,
            projectRoot: nil,
            signatures: signatures,
            apply: true
        ) {
        case .failure(let error):
            XCTFail(error.message)
        case .success(let plan):
            XCTAssertTrue(plan.changed)
        }

        let changed = try String(
            contentsOf: pbxproj,
            encoding: .utf8
        )

        let app = try XCTUnwrap(
            changed.range(
                of: "AppDelegate.swift"
            )?.lowerBound
        )
        let home = try XCTUnwrap(
            changed.range(
                of: "HomeViewController.swift"
            )?.lowerBound
        )
        let feed = try XCTUnwrap(
            changed.range(
                of: "FeedService.swift"
            )?.lowerBound
        )
        let other = try XCTUnwrap(
            changed.range(
                of: "Other.swift"
            )?.lowerBound
        )

        XCTAssertLessThan(app, home)
        XCTAssertLessThan(home, feed)
        XCTAssertLessThan(feed, other)

        let backup = URL(
            fileURLWithPath:
                pbxproj.path + ".preorder"
        )
        XCTAssertEqual(
            try String(
                contentsOf: backup,
                encoding: .utf8
            ),
            original
        )
    }
}
