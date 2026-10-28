---
title: Architecture critiques and agent implementation brief
created: 2026-10-28
status: unverified_backlog
scope: repository_architecture_and_product_workflow
compatibility: breaking_changes_allowed
execution_order: [C01, C02, C03, C04, C05, C06, C07]
---

# Architecture critiques and agent implementation brief

This document records the seven recommendations from a source review of stakrr.
It is intended to be handed to agents to verify the critiques, refine the designs,
implement accepted changes, and verify the results. The review did not include
running tests, benchmarking, or reproducing failures. An observed design constraint
is not necessarily a defect, and a proposed replacement is not a proven solution.

Compatibility with existing commands, persisted formats, and internal structure
is negotiable. Preservation of user work and recoverability remain requirements.
Writing this brief does not itself implement any of the recommendations.

## Agent workflow

Use the stable IDs below when assigning work and reporting results. Each critique
has the same structure: status, priority, dependencies, evidence, verification,
implementation, and acceptance criteria. Priorities express recommended product
order; dependencies identify where designs must agree before implementation.

For each assigned critique:

1. Read `AGENTS.md`, `docs/git-flow.md`, the referenced source, and related tests.
   Inspect the current working tree and preserve unrelated edits.
2. Verify the factual claims. Reproduce behavior in disposable repositories where
   useful. Record whether the critique is confirmed, partially confirmed,
   rejected, or superseded, with concrete evidence.
3. Complete the design. Resolve the open questions, identify affected commands and
   persisted state, and define a small implementation sequence. Do not implement
   a suggested design mechanically if a simpler design meets the requirements.
4. Implement the accepted scope in focused, buildable changes. Update the command
   contract, user documentation, completion, and regression coverage as needed.
5. Verify behavior and failure paths. Record exact commands and results, including
   anything not tested. Review the resulting diff against the acceptance criteria.
6. Update the task status and append a report using the template at the end.

Use these status values: `unverified`, `verified`, `designed`, `implementing`,
`implemented`, `validated`, `rejected`, `superseded`, `blocked`.
Do not mark a task `validated` while required acceptance checks remain undone.
Document rejected critiques rather than deleting them.

If several agents work on this backlog, coordinate ownership before editing shared
files. C01, C02, C03, and C05 overlap substantially; agree on their interfaces and
state model before attempting concurrent implementation. Do not expand an
assignment into unrelated features without an instruction to implement those too.

## Requirements to preserve

- Preserve the rolling-branch workflow: keep committing at the top and carve
  reviewable layers out underneath it.
- Preserve cuts that create boundaries without rewriting existing commits.
- Hold the shared mutation lock and honor linked-worktree branch ownership.
- Publish expected ref changes using compare-and-swap and retain recovery intent
  across interrupted publication. A Git multi-ref transaction is not a substitute
  for the existing interruption recovery protocol.
- Retain original and rewritten commits needed for recovery through Git pruning.
- Preserve user files, staged and unstaged changes, untracked files, ignored files,
  and conflict resolutions. Never introduce an implicit destructive cleanup.
- Keep read-only commands read-only with respect to managed state and recovery.
- Preserve symbolic-ref refusal and protocol validation where applicable. Do not
  remove safety checks merely to simplify discovery or support another backend.
- Keep meaningful SHA-1, SHA-256, linked-worktree, refusal, and fault-injection
  coverage. Update obsolete implementation-specific tests deliberately.

## C01: Isolate replay from the user's worktree

- Status: `unverified`
- Priority: `1`
- Dependencies: coordinate the replay interface with C03 and progress model with C05.

### Evidence and critique

`src/edit.zig` (`begin`, `detachForReplay`, `replayDescendants`, `detach`,
`requireNoIgnored`) replays descendants using detached HEAD and cherry-pick in the
invoking worktree. It rejects all ignored files before picks because merge rename
handling can write paths absent from the incoming diff. `README.md` documents the
requirement to preserve and remove even unrelated ignored build output.

`src/fix.zig` (`fix`) already builds replacement commits in object storage through
`Git.mergeTree` and `Git.rewriteCommit`, without replaying through the worktree.
The two workflows impose substantially different demands on the user.

### Verify and complete the design

- Reproduce the ignored-build-output refusal and document why simply narrowing
  the ignored-file check would be unsafe under the current replay mechanism.
- Evaluate object-only replay for clean merges and a dedicated detached worktree
  for conflicts. Compare this with using a dedicated worktree for every replay.
- Define how a user finds the conflict workspace, resolves files with Git, and
  continues or quits after restarting the CLI.
- Define final publication separately from replay. Moving a branch checked out
  in the invoking worktree can require reconciling tracked files and the index;
  isolation alone does not make arbitrary dirty-state publication safe.
- Account for checkout hooks, submodules, sparse checkouts, workspace relocation,
  interrupted workspace creation, and orphaned workspace cleanup. State supported
  cases explicitly and refuse unsupported cases before unsafe mutation.

### Implementation direction

Use isolated replay storage and durable progress. Keep managed branch changes
behind the final guarded publication. Preserve a conflict workspace and its user
resolutions until completion or an explicit safe cleanup action.

### Acceptance criteria

- Unrelated ignored files no longer require removal merely to execute replay.
- Replay does not detach the invoking worktree's HEAD or place conflict files in
  that worktree under the selected design.
- Clean replay, conflicts, continuation, abort, quit, and process-death recovery
  work with documented workspace ownership and lifecycle rules.
- Final publication preserves tracked work and refuses unsafe checked-out-branch
  updates without losing the replay result or user changes.
- Tests cover rename destinations, ignored files, hooks, linked worktrees,
  interrupted replay, and workspace cleanup that preserves user resolutions.

## C02: Consolidate authoritative stack metadata

- Status: `unverified`
- Priority: `2`
- Dependencies: agree on the metadata interface used by C03, C04, C05, and C07.

### Evidence and critique

`src/layout.zig` defines config state, anchor/tip refs, layer branches, recorded
boundaries, edit checkpoints, an operation log, and a pending transaction ref.
`src/stack.zig` (`initStack`, `loadConfig`, `inspect`, `reset`) combines these into
a stack model. Init and reset publish refs and write or remove Git config in
separate steps. Layer membership and order are reconstructed through namespace
discovery and history depths.

This creates multiple consistency relationships and separate recovery concerns.
It is not a claim that current failure handling necessarily loses user data.

### Verify and complete the design

- Inventory which values are authoritative, derived, concurrency guards, or
  retention roots. Identify actual failure windows and existing protections.
- Evaluate one versioned manifest stored in a Git commit behind a dedicated state
  ref. Record base, rolling branch, ordered layers, and published boundaries.
- Decide whether stable layer IDs are useful independently of branch names.
  Define identity and rename behavior before adding IDs.
- Define which redundant refs can be removed and which guards remain necessary.
- Decide whether to migrate old state or refuse it with precise preservation and
  upgrade instructions. Breaking changes do not justify silent data loss.
- Define handling of missing branches, namespace collisions, symbolic refs, and
  storage backends. An explicit manifest reduces discovery needs but does not
  automatically solve dangling symbolic-ref detection or reftable support.

### Implementation direction

Publish the authoritative state ref with the affected branch refs using the
existing guarded intent/recovery protocol. Keep Git config for user preferences.
Retain every commit referenced by metadata through actual object reachability;
OID strings inside JSON alone do not keep commits alive.

### Acceptance criteria

- The source of truth and all derived state are explicit and documented.
- Init, cut, reset, edits, and recovery use the agreed state model consistently.
- Interrupted publication converges or stops with actionable drift diagnostics.
- Upgrade/refusal behavior preserves existing branches and recovery objects.
- Relevant tests cover pruning, external changes, symbolic refs, linked worktrees,
  both object formats, and initialization/reset failure boundaries.

## C03: Share replay planning, execution, and publication

- Status: `unverified`
- Priority: `3`
- Dependencies: C01 execution design; C02 metadata interface; C05 operation interface.

### Evidence and critique

`src/fix.zig` and `src/edit.zig` independently perform replay, map rewritten commits
to layer boundaries, construct checkpoint data, and assemble publication updates.
They share low-level Git wrappers but expose different execution and conflict
behavior. This is a likely maintenance cost as base updates and layer retirement
are added; the amount of useful unification needs verification.

### Verify and complete the design

- Compare the algorithms and list genuine differences: staged-change folding,
  amended commits, edit boundaries, empty commits, conflicts, and tree equality.
- Propose concrete shared types for an immutable rewrite plan, execution progress,
  and publication result. Keep command-specific policies outside shared plumbing.
- Preserve `fix`'s requirement that the resulting rolling tree reproduces the
  staged index and its protection of unstaged changes.
- Determine whether a common executor can retain `fix`'s refusal-on-conflict
  behavior while allowing interactive continuation for restack.

### Implementation direction

Separate planning, resumable execution, and guarded publication. Use the smallest
shared implementation that removes duplicated invariants; avoid building a generic
workflow framework. Keep user-facing commands distinct where their intent differs.

### Acceptance criteria

- Fix and restack share boundary mapping and publication invariants where valid.
- Existing command semantics remain covered, or intentional changes are documented.
- Tests preserve empty commits, upper-layer deletions, amendment metadata policy,
  staged-tree equivalence, and refusal without user-state mutation.
- A future base update can use the engine without duplicating the replay loop.

## C04: Separate observation from mutation validation

- Status: `unverified`
- Priority: `4`
- Dependencies: C02 metadata interface; can prototype observation types independently.

### Evidence and critique

`src/stack.zig` (`inspect`) requires consistency before returning a `Snapshot`.
`src/main.zig` uses that snapshot for normal status. Missing branches, invalid
boundaries, or incompatible state can therefore prevent displaying the stack.
Several user-facing errors suggest reset rather than describing a targeted repair.

### Verify and complete the design

- Enumerate status failures and distinguish incomplete observation, unsupported
  state versions, corrupt state, and valid state that cannot safely be mutated.
- Design an observed view with structured issues and a separate validated view
  required for mutations. Preserve allocator ownership and explicit lifetimes.
- Define useful output when only some state is readable; never invent missing
  branch positions or present corrupt data as trustworthy.
- Specify a `doctor` command that diagnoses and proposes concrete recovery steps.
  Decide separately whether automated repair belongs in its initial scope.

### Implementation direction

Render available evidence and specific problems in status. Keep strict validation
at mutation boundaries. Diagnosis must not silently recover a transaction, move
refs, repair metadata, or discard state.

### Acceptance criteria

- Status explains at least missing branches, diverged boundaries, pending
  publication, and unsupported/corrupt state as far as safely observable.
- Mutating commands continue to refuse invalid state before unsafe changes.
- Doctor names affected refs and offers preservation-first recovery instructions.
- Tests assert diagnostic accuracy and absence of managed-state mutation.

## C05: Model operations separately from execution progress

- Status: `unverified`
- Priority: `5`
- Dependencies: coordinate with C01, C02, and C03 before changing persisted formats.

### Evidence and critique

`src/edit_session.zig` models edit phases, outcomes, rollback, and undo in `Session`.
`src/fix.zig` (`publish`) represents a finished fix through an edit session with
phase `.switching`. `src/edit.zig` (`undo`) reuses abort-oriented phases during
restoration. Repeated undo toggles the last operation, as the CLI documents.

The model appears narrower than the operations it now records. Existing reuse may
still be sound; verify whether a new model actually reduces special cases.

### Verify and complete the design

- Map current phase/outcome/operation combinations and their invariants.
- Separate an operation's immutable before/after state from resumable execution
  progress and conflict-workspace ownership.
- Define stable operation IDs and selectable checkpoint restoration. Distinguish
  inspectable historical checkpoints from states safe to restore automatically.
- Define explicit redo behavior, including what happens after external Git changes
  or a new operation following undo. All restoration needs expected-state guards.
- Design opt-in history pruning with clear retention roots. Preserve indefinite
  retention by default; never prune an active operation's recovery objects.

### Implementation direction

Keep Git-backed, pruning-resistant checkpoints and a readable operation log.
Introduce separate data types only where they clarify real invariants. Treat
selectable restore, redo, and pruning as focused subchanges with explicit contracts.

### Acceptance criteria

- Completed fix records no longer need unrelated in-progress edit phases under
  the selected model, or the agent documents why retaining them is preferable.
- Operation IDs, before/after state, progress, and retained rescue commits have
  unambiguous meanings and durable encoding.
- Undo, redo, and selected restoration refuse drift and occupied branches safely.
- Restart and pruning tests prove required objects remain reachable.
- Pruning is explicit, preserves active recovery state, and reports what it removes.

## C06: Test invariants and named failure boundaries

- Status: `unverified`
- Priority: `6`
- Dependencies: none for initial harness improvements; track C01-C05 as designs change.

### Evidence and critique

`tests/support/repo.zig`, `edit_fixture.zig`, `cli.zig`, and `git_fault.sh` already
provide useful shared fixtures, hermetic environments, and fault injection.
`tests/edit_recovery_test.zig` also uses numbered checkpoint ranges such as `1..8`,
coupling some recovery coverage to implementation-specific checkpoint counts.
`TODO.md` independently identifies test boilerplate as an improvement area.

The review recommends preserving the strong existing safety coverage while making
it easier to extend and harder to accidentally skip new failure boundaries.

### Verify and complete the design

- Inventory repeated setup and distinguish meaningful scenario differences from
  boilerplate. Do not hide test intent behind an elaborate fixture DSL.
- Identify numbered or label-dependent injection sites and how coverage breaks
  when checkpoint order changes.
- Design named fault boundaries with occurrence identifiers for repeated steps.
  Assert that requested injection points are actually reached.
- Design deterministic generated operation sequences against a small independent
  model, with reproducible seeds and useful failure traces.

### Implementation direction

Keep real Git integration and CLI crash tests. Use shared fixtures for setup and
state capture. Add property-oriented tests for refusal, recovery convergence,
boundary consistency, branch ownership, preservation of user files, and object
reachability after pruning. Do not merely restate implementation logic in tests.

### Acceptance criteria

- New replay/publication phases cannot silently escape the intended fault matrix.
- Named faults cover before/after persistence and uncertain publication windows.
- Generated sequences are deterministic and report the sequence needed to reproduce.
- Assertions distinguish allowed recovery work from forbidden mutation on refusal;
  unreachable object creation alone is not treated as user-state corruption.
- SHA-1/SHA-256, linked-worktree, symbolic-ref, and failure-path coverage is retained.
- Debug and ReleaseSafe tests pass without making ordinary failures harder to diagnose.

## C07: Complete the everyday stack lifecycle and CLI diagnostics

- Status: `unverified`
- Priority: `7`
- Dependencies: use the accepted C01-C05 interfaces; C06 supplies regression support.

### Evidence and critique

`README.md` documents that submit, moving onto an updated base, and retiring landed
layers remain planned. `src/cli.zig` has a compact parser and `src/render.zig` has
global help; the CLI currently offers no structured JSON output. The core local
editing workflow is substantial, but keeping a stack current and publishing it
still requires work outside the tool.

This is a product-priority recommendation, not a claim that planned features are
implementation defects. Split the following into separate agent assignments.

### C07-A: Update onto a moved base

- Specify an explicit base-update operation, including target selection and any
  fetch behavior. Local operations should remain local unless remote access is
  explicitly part of the command contract.
- Use shared replay, conflict continuation, publication, abort, and undo machinery.
- Verify anchor/state updates, unstacked rolling work, empty commits, conflicts,
  external drift, linked worktrees, and restart recovery.

### C07-B: Retire landed layers

- Define how users select layers to retire and how remaining work is replayed.
- Distinguish retirement from deleting user branches. Preserve branches by default
  unless the command explicitly requests deletion and passes ownership checks.
- Do not assume that squash merges or rewritten upstream history can be recognized
  reliably from ancestry alone. Make ambiguous cases explicit.
- Verify remaining boundaries, rolling work, recovery, and undo.

### C07-C: Publish review branches

- Specify remote/provider scope, branch mapping, PR targeting, authentication, and
  how partial remote success is reported and resumed.
- Exclude unstacked rolling work from publication.
- Guard rewritten remote branches using recorded expectations; never introduce an
  unconditional force push or claim atomicity across local refs, pushes, and PR APIs.
- Verify with disposable remotes or controlled fixtures. Do not publish real user
  branches or send external messages merely to validate this backlog.

### C07-D: Command-specific help and actionable errors

- Add `stakrr <command> --help` with command-relevant examples and preconditions.
- Preserve relevant Git diagnostics and name affected refs/worktrees when known.
- Keep existing exit-code distinctions or document deliberate replacements.
- Update completion and documentation with the implemented command surface.

### C07-E: Structured output

- Define versioned JSON output for status, diagnostics, and operation history.
- Specify stdout/stderr behavior and machine-readable error representation.
- Return the same underlying observations used by human output, including partial
  state and structured issues from C04. Avoid parsing rendered text internally.
- Verify stable field semantics, escaping, no ANSI output, and meaningful exit codes.

### Acceptance criteria

- Each subtask has a documented command contract and focused regression coverage.
- Base updates and retirement preserve local recovery and user-work guarantees.
- Publication explicitly handles remote drift and partial success.
- Help, completion, human diagnostics, and JSON output reflect actual behavior.
- Do not mark C07 validated when only one of its subtasks has shipped; report
  C07-A through C07-E independently.

## Retain unless verification provides a concrete reason to change

- Zig: the source review identified no evidence that a language rewrite would
  address the main problems. Evaluate any proposal against a specific deficiency.
- Git CLI plumbing: retain Git's behavior and shared wrappers rather than replacing
  them for aesthetic reasons. Profile before making performance claims.
- Explicit allocator ownership, owned snapshots, and `deinit` conventions.
- Rendering that consumes values without running Git commands.
- Shared locking, guarded ref publication, retained recovery checkpoints, and the
  existing fault-injection discipline.

These are design preferences, not immutable files. Implementations can change
while preserving the reasons these mechanisms exist.

## Verification checklist for implementation agents

Run checks appropriate to the actual change. For application behavior or shared
architecture changes, the repository's standard checks are:

```sh
zig fmt --check build.zig src tests
zig build
zig build test
zig build test -Doptimize=ReleaseSafe
```

Use the repository-required Zig version and record the Git version used. CI covers
Linux and macOS; a local run on one platform does not establish both platforms.
Run targeted regressions first when useful. Do not repeatedly broaden testing once
required checks pass unless new changes or unresolved concerns justify it.

Review safety in disposable fixtures: refusal, crashes, conflicts, pruning,
worktree occupancy, and external ref changes. Update `docs/git-flow.md` together
with behavior; its current contract must not be silently bypassed by a redesign.

## Agent report template

Append one report per critique or C07 subtask. Include repository-relative source
locations and exact verification results. Keep proposals distinct from completed
work.

```yaml
task_id: C01
status: verified
verdict: confirmed # confirmed | partially_confirmed | rejected | superseded
evidence:
  - "src/edit.zig:requireNoIgnored rejects all ignored files"
reproduction:
  - "Describe the disposable fixture, command, and observed result"
design_decisions:
  - "Decision and reason; include alternatives where material"
implemented_changes: []
documentation_changes: []
verification:
  - command: "exact command"
    result: "passed | failed | not_run, with reason/details"
acceptance_criteria_remaining: []
risks_or_limitations: []
follow_up_tasks: []
```

## Git references for design verification

- [git-merge-tree](https://git-scm.com/docs/git-merge-tree): merges in object storage
  without reading or writing the worktree or index; inspect structured conflict
  information rather than treating the resulting tree as a resolved merge.
- [git-worktree](https://git-scm.com/docs/git-worktree): separate HEAD/index/worktree
  state, shared refs, ownership rules, and workspace lifecycle.
- [git-update-ref](https://git-scm.com/docs/git-update-ref): expected-value updates
  and prepare/commit protocol. Preserve the repository's additional intent and
  recovery protections.
