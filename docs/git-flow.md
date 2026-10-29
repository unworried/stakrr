# Git command flows

This is the local command contract. One stack belongs to a common repository,
including its linked worktrees. Git remains the source of live branch tips and
worktree occupancy; the manifest is the source of membership, order and recorded
boundaries.

## Storage and ownership

| Location | Owner and meaning |
| --- | --- |
| `refs/stakrr/state` | Version 1 manifest commit; absence means uninitialized |
| `stack.json` in that commit | Base branch, work branch, anchor OID, ordered `{branch, recorded_boundary_oid}` layers |
| `refs/heads/stakrr/*` | User-visible layer branches; branch names are identity |
| `refs/stakrr/edit` | Version 1 active execution progress, workspace and checkout intent |
| `refs/stakrr/oplog` | Completed operation records and indefinitely retained history |
| `refs/stakrr/transaction` | Version 1 temporary write-ahead publication intent |
| `<git-common-dir>/stakrr.lock` | Shared advisory mutation lock; keep its inode |
| `<git-common-dir>/stakrr-workspaces/<session-id>` | Dedicated detached replay workspace |

The manifest commit directly parents its anchor and recorded boundaries,
deduplicated in that order. OIDs written in JSON do not provide reachability.
Completed records and checkpoints also parent the commits they retain. See
[Git garbage collection](https://git-scm.com/docs/git-gc).

## Shared safety rules

1. Workflows acquire `mutation.begin` before observing expected values. Stack
   commands refuse an active session; edit commands can resume it. Ref plumbing
   supports bare repositories. Acquisition recovers pending publication under
   the common lock before a workflow reads its state.
2. Validate ref syntax, reserved namespaces, direct-ref identity, object format,
   worktree ownership, and command eligibility before mutation. Publication
   rechecks direct refs while Git holds their locks.
3. Compare-and-swap the manifest with all affected branches. Verify other observed
   values used by the command. Multiple writes use the existing publication intent
   protocol: retain old/new objects, prepare intent, publish, verify, remove intent.
4. If Git stops after partial writes, accept only recorded old/new values and
   finish the remaining writes. Ref drift or occupied branches stops recovery.
   Preserve Git-owned lock files. Never silently force refs or worktree removal.
5. `status` and `log` are read-only. They never acquire mutation recovery, repair
   metadata, change refs, or clean workspaces. Status renders available evidence
   and structured issues; unknown counts, stale state, or tips are unavailable.
6. Keep allocator ownership explicit. Pure model/codec validation is separate from
   Git-backed loading, ancestry checks and mutation validation.

External Git writers do not take stakrr's lock. Worktree checks are observations,
not a global lock on Git. Expected-value transactions remain essential.

## Manifest validation and observation

The codec requires supported version and all required fields. It validates branch
syntax, reserved base/work namespaces, distinct base/work names, unique layer names,
ref directory conflicts and repository-format nonzero OIDs. Encoding has fixed field
order and preserves the declared layer order. Decoding owns its lifetime.

Observation loads the manifest identity, reads branches independently, lists the
reserved namespace to find unexpected refs, and reads linear anchor..work history
once. Recorded boundaries must occur in strictly increasing declared order. Counts
are differences in those depths; no live-history sort defines layer order.

Missing/symbolic branches, unexpected refs, missing ancestry, merges, unsupported
or malformed manifests and pending publication remain diagnosable. Mutations
require a strict view and add their own stale/checkout/cleanliness rules. Extra
namespace refs are reported and never adopted.

## init

Require an ordinary worktree and no stack or active session. Reserve the layer
namespace. Observe the current branch as work; accept a short or full local base
branch. Require direct base/work refs, distinct names outside the layer namespace,
base ancestry and linear history. Create an empty-layer manifest anchored at the
observed base tip. Publish the state ref while verifying base and work tips.
HEAD, index and files are untouched; dirty state is allowed. Internal metadata
commits use a stakrr identity without changing Git config.

## cut

Require the work branch and strict state. Refuse stale layers and invalid or
conflicting names. Resolve the optional user revision (HEAD by default); require
it strictly above the last recorded boundary and reachable from work. Append the
layer to the manifest, then publish the new branch and replacement state together,
verifying work and all existing layer tips. Base movement does not move the anchor.
Dirty staged/unstaged/untracked work is allowed and remains untouched.

## status and navigation

Status shows available base/work/layer evidence, stale layers, counts, base movement
and issues. An active session includes its phase, replay position, stopped commit,
destination and workspace path. A partially published transaction is reported,
never recovered by a read.

`go`, `up`, and `down` use declared manifest order: base, layers, work. They refuse
an active session or invalid state, preserve Git's checkout refusal rules and
normal navigation hooks, disable branch guessing, and never overwrite ignored files.
Unrelated ignored files are allowed.

## fix

Require strict state, the work branch, at least one layer, no stale layers or Git
operation, and staged changes. Fold the staged tree into the chosen layer (highest
by default) using `merge-tree --merge-base` in object storage. Create a commit or
amend that layer's last commit; amendment/replay preserves author, committer and
message, dropping invalidated signatures. Replay descendants with shared immutable
planning and boundary mapping. Empty commits and deletions remain represented.

Refuse any conflict or resulting work tree differing from the staged tree before
publishing. HEAD, files, index and unstaged changes remain untouched. The resulting
HEAD tree matches the index, so staged changes become committed. Publish moved
branches, manifest and a completed fix record in one guarded transaction, permitting
only the invoking worktree's exact work branch as the current-branch exception.
No active execution session is manufactured for fix.

## restack and continue

Require clean tracked/index/untracked state and no Git operation in the invoking
worktree. Ignored build output may remain. Exactly one layer must be stale. Its
edited tip must introduce a nonempty linear segment above the preceding recorded
boundary. Preserve the original recorded boundaries and work tip for abort.

Persist execution intent before creating a workspace: unique session identity,
origin path/private Git directory/branch/tip, expected refs and manifest, replay
plan, cursor, destination and workspace path. Create a locked detached worktree
with a unique ownership marker. A restart verifies registration, private directory,
common repository, path, marker and detached HEAD before using it. Locks protect
against pruning; see [Git worktree lifecycle](https://git-scm.com/docs/git-worktree).

All replay runs in that workspace. Disable hooks, signing, rerere, sparse checkout
and recursive submodule operations for automated picks/checkouts. Never initialize
or clean submodules automatically. The invoking worktree's sparse checkout does
not constrain replay. Normal navigation retains user hook behavior.

Checkpoints bracket picks. If a pick commits before the next checkpoint, verify
its single parent against the saved cursor and incorporate it exactly once. Map
boundaries through the shared replay core. Keep redundant/empty commits.

On conflict print the workspace path and exit 3. Resolve and stage files there,
using `git rm` for deletions. `continue` can run in the original worktree or workspace.
Validate the stopped pick, unmerged index, unstaged/untracked files, refs and
ownership before committing the resolution. A manual resolution commit whose
single parent is the saved cursor is accepted. Do not switch the workspace branch.

Before final publication, revalidate the invoking checkout's expected branch/tip,
cleanliness, Git operation state, availability and observed refs. Persist detach
intent, briefly detach that checkout if needed, and publish branches, replacement
manifest and progress using the publication intent protocol. Persist each transition.
Return the original checkout to its original branch with hooks disabled. Ignored
checkout collisions retain results and resumable progress; preserve the collision
and continue. Ref or checkout drift refuses unsafe publication.

Checkpoint cleanup intent. Remove only a verified, clean, owned workspace, with no
ignored/untracked files or Git operation, using non-forced Git removal. Preserve and
report unexpected files, initialized submodules or incomplete cleanup. A restart
can recover between unlock/removal/archival. Finish by writing a completed restack
record, retaining checkpoints, and deleting active progress atomically.

## abort

Restore original recorded boundaries and original work tip, including resetting
the edited branch to its original recorded boundary. Retain edited and replayed
commits through checkpoints and completed history. Require clean workspace and
invoking checkout; uncommitted resolutions must first be preserved or committed.
Validate any stopped pick before dropping its metadata. Checkpoint restoration
intent and expected refs, prepare the invoking checkout, and publish restoration
with a replacement manifest. Return to the original branch, safely clean the
workspace, archive an abort record and delete progress. Never reset user files hard.
Interrupted restoration resumes via `continue` or `abort`.

## quit

Refuse an active Git operation in the caller or known workspace. Drop progress
without restoring branches, HEAD, index or files. Preserve workspace files and its
lock; report its path before dropping progress. Retain current heads and checkpoint
objects in completed history. Corrupt-session archival does not require a valid
replay plan or manifest. Status after quit may report an inconsistent stack
requiring preservation-first reset.

## reset

Allow corrupt state, but refuse active progress.
Discover layer refs only to preserve or explicitly delete them. Archive previous
state and layer objects before removing their last roots. Delete `refs/stakrr/state`;
absence is the uninitialized state. Keep branches by default; `--delete-layers`
requires no layer checkout in any worktree. Publish archive, deletion and optional
branch deletions through compare-and-swap. Preserve HEAD, index and files. Kept
layer names must be renamed outside `stakrr/*` or removed before another init.
History is retained indefinitely.

## log and undo

Log lists completed records and active checkpoints newest first, with explicit
history links, actual branch movements, timestamps, labels and rescue objects.
Completed records hold kind, before/after manifests, moves, rescue OIDs and previous
history; they contain no execution phases. Corrupt archival retains raw objects.
There is no automatic history pruning.

`undo` remains recognized but returns `error: unimplemented`, exit 1, without any
Git access. Redo, selectable restoration, history pruning, base updates, remote
publication and repair commands are deferred.

## Verification

Run `zig fmt --check .`, `zig build`, `zig build test` and
`zig build test -Doptimize=ReleaseSafe`. CI runs Linux/macOS. Tests use disposable
repositories, both object formats, linked worktrees, symbolic-ref races, hooks,
ignored files, sparse checkout, gitlinks, expired reflogs and pruning. Fault tests
name each interruption boundary and assert both SIGKILL and the fired marker.
