# Multi-Project / Multi-Device Implementation Plan

## Phase 1 - Runtime identity
- Store InjectionNext projectRoot and executable responses.
- Expose them on InjectionRuntimeStatus and RuntimeTarget.
- Add runtime/project matching helpers.

## Phase 2 - Project sessions
- Add ProjectSessionSummary / ProjectsResult.
- Add MultiProjectInjectionBackend.
- One InjectionNextRuntimeBackend per project root.
- Shared InjectionNextRuntimeServer and AgentTraceServer.
- Source routing uses longest containing root.
- Automatic runtime selection uses runtime projectRoot.

## Phase 3 - Control plane
- Add projects/project_add/project_remove.
- Add optional projectID to requests.
- Route pending/inject/doctor/diagnostics/targets by project when supplied.
- Preserve legacy single-project calls.

## Phase 4 - Daemon
- Accept repeated --project.
- Instantiate MultiProjectInjectionBackend.
- A single --project remains backward compatible.

## Phase 5 - Menu Bar
- Replace single projectRoot preference with persisted roots.
- Add/remove independent project directories without restarting the app.
- Group pending files and targets under projects.
- Ctrl+- injects all registered project sessions.
- Show unmatched runtime sessions separately for diagnosis.

## Phase 6 - Tests
- Runtime target retains projectRoot/executable.
- Deterministic project IDs.
- Longest-root source routing.
- Runtime-to-project matching.
- Independent pending source stores.
- Control protocol round-trip with/without projectID.
- Existing single-project tests remain green.
