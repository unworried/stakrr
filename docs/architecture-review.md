# Stack architecture

The stack manifest defines membership, order and recorded boundaries. Live Git
observations, resumable execution and completed operation history have separate
owners. See [Git command flows](git-flow.md) for the command contract and
[Git API](git-api.md) for ownership and publication interfaces.

## Storage ownership

| Module | Responsibility |
| --- | --- |
| `stack_state.zig` | Pure model, structural validation and deterministic JSON codec |
| `state_store.zig` | Manifest commit loading, creation and object retention |
| `stack.zig` | Partial observations, strict mutation snapshots and stack policy |
| `replay.zig` | Immutable replay planning, boundary mapping, validation and publication updates |
| `edit_session.zig` | Active execution model and checkpoint codec |
| `operation.zig` | Completed records with manifests, branch movements, rescue objects and history links |
| `edit.zig` | Workspace lifecycle, replay, publication, checkout, abort and archival |
| `fix.zig` | Object-only folding of staged changes and completed fix records |
| `mutation.zig` | Shared mutation lock, recovery and guarded publication |
| `ref_transaction.zig` | Interrupted publication intent and recovery |
| `ref_backend.zig` | Git ref protocol and direct-ref checks under Git's locks |
| `layout.zig` | Persisted ref names and checkpoint/publication format versions |

`refs/stakrr/state` is the sole authoritative stack root. Its commit contains
`stack.json`: base branch, work branch, anchor OID and ordered layers with branch
names and recorded boundary OIDs. Branch names are layer identity. The commit
parents its anchor and boundaries, deduplicated in that order, so referenced
objects remain readable after reflog expiry and pruning.

`refs/stakrr/edit` holds active progress; `refs/stakrr/oplog` holds completed
operations and retained checkpoints. `refs/stakrr/transaction` retains temporary
publication intent. All persisted formats use version 1. During active development,
schemas change directly without increasing their version tags.

## Observation and mutation

The codec validates syntax, namespaces, unique names, ref conflicts and
repository-format OIDs without Git access. Git-backed observation loads manifest
identity and available branch evidence independently. One linear history read
validates recorded boundaries and calculates counts. Declared layer order never
comes from sorting live history.

Owned observations expose unavailable counts, tips and stale indicators explicitly.
Status can render partial evidence and structured issues. Mutations require a
strict snapshot and command-specific eligibility checks. Unexpected namespace
branches are reported and never adopted.

Workflows acquire mutation contexts directly before reading expected values.
Publication compares and swaps the manifest with affected branches, repeats
direct-ref checks under Git's locks and retains old/new objects in the interruption
journal. Recovery accepts only recorded values and respects linked-worktree
ownership. Read-only commands never recover or repair state.

## Replay and workspaces

Fix and restack share planning, boundary mapping, result validation and publication
construction. Fix stays in object storage, refuses conflicts without changing
managed state or user files, and requires the resulting work tree to match the
staged tree. It writes a completed operation record directly.

Restack replays in a dedicated detached worktree. Progress records workspace
creation intent, ownership and a unique lock marker before creation. Checkpoints
retain the replay cursor, expected refs, origin checkout and final destination.
Conflicts print the workspace path; continuation works from that workspace or the
origin. Automated operations disable hooks and sparse/recursive submodule behavior.
Navigation retains normal hooks. Submodules are never initialized automatically.

Before publication, revalidate the original checkout and journal any brief detach,
ref publication and return to the original branch. Checkout collisions retain the
result and resumable progress. Workspace cleanup requires verified ownership and
clean files, records intent and never forces removal. Unexpected files or
initialized submodules remain available for preservation.

Abort restores original recorded boundaries and the original work tip while
retaining edited and replayed commits. Unsafe restoration refuses uncommitted
resolutions. Quit archives progress and rescue objects, preserves workspace files
and refuses an active Git operation. Reset archives state and required objects
before deleting the manifest; branches remain unless deletion is requested.

Completed records contain no execution phases. Log follows explicit history links
and shows both completed operations and checkpoints. Retention has no automatic
expiry. Undo is recognized only as a Git-free, exit-1 unimplemented stub. Redo,
selectable restoration, history pruning, base updates, remote publication and
repair commands remain deferred.

## Verification

Regression coverage includes deterministic codec bytes and independent lifetimes,
partial observations, manifest order under branch movement, malformed state,
namespace/ref drift, conflicts, workspace ownership, final checkout and cleanup.
Named fault boundaries assert both the injected marker and process termination.
Hooks, sparse checkout, gitlinks and linked worktrees have dedicated coverage.
Retention tests expire reflogs, remove alternative roots, prune, read objects and
run `fsck` in SHA-1 and SHA-256 repositories.

Run `zig fmt --check .`, `zig build`, `zig build test` and
`zig build test -Doptimize=ReleaseSafe`. CI covers Linux and macOS. Workspace
relocation is refused; initialized submodules can require manual preservation
before cleanup.
