# Objective-C + Swift multi-project hot-reload plan

Branch: `feature/objc-swift-hot-reload`

## Goal

Make Swift hot reload reliable in large Xcode workspaces containing Objective-C,
Swift, CocoaPods, multiple projects, multiple targets, and many Swift sources,
without adding configuration for normal single-project apps.

## Compatibility rule

- A source with one valid compile context keeps the current zero-config behavior.
- Extra target/module/architecture selection is only used when multiple contexts exist.
- Ambiguous contexts must fail with a useful diagnostic instead of reporting a false success.
- Existing Objective-C and simple Swift injection paths remain valid.

## Work items

1. **Compile-context identity**
   - Track source, platform, architecture, target triple, module and build-log origin.
   - Keep compatibility with the existing persistent cache.
   - Avoid treating commands for different architectures/modules as the same entry.

2. **Candidate selection**
   - Collect all matching Xcode compile commands instead of returning the first match.
   - Prefer the connected runtime architecture.
   - Collapse repeated logs for the same compile context.
   - If multiple distinct contexts remain, report an ambiguity rather than guessing.

3. **Diagnostics**
   - Extend `doctor SOURCE` with candidate count, modules, architectures and ambiguity.
   - Make stale/wrong-architecture contexts visible to an Agent.

4. **Compiler interception**
   - Cover Xcode 26.3+ driver behavior where `swiftc` can bypass a
     `swift-frontend` wrapper.
   - Preserve normal driver invocation semantics and build-log fallback.

5. **Tests**
   - Single-project/single-candidate behavior remains unchanged.
   - Multiple logs for the same module collapse to one context.
   - arm64 runtime does not select an x86_64 compile command.
   - Multiple modules for one source are detected as ambiguous.
   - Compiler interception patch/unpatch remains reversible.

6. **Simulator E2E**
   - Keep the existing mixed Objective-C + Swift + CocoaPods smoke test.
   - Add a multi-project fixture with Swift code outside the app project.
   - Verify behavior changes in the running app, not just `injected=true`.

## Definition of done

`swift build`, `swift test`, MCP checks and Simulator smoke are green on the
feature branch, and a multi-project Swift edit is observed in the already
running Simulator app without rebuilding or relaunching it.
