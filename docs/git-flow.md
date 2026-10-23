# Git command flows

Implement each stakrr command in the order below. These flows define the local
Git contract: checks, allowed mutations, publication and recovery. Change the
contract, implementation and regression tests together when changing behavior.
Remote publication is outside these flows; `submit` remains unimplemented.

## Shared rules

- Hold `<git-common-dir>/stakrr.lock` for the entire mutation, across all
  worktrees. Release the lock without unlinking its inode.
- `init`, `cut`, `reset`, `go`, `up`, `down`, `fix` and `undo` must refuse while
  `refs/stakrr/edit` exists. Use `continue`, `abort` or `quit` for a pending edit.
- Publish refs with `git update-ref --create-reflog -m <label> --stdin`:
  `start`, expected-OID `verify`/`create`/`update`/`delete` operations, `prepare`,
  `commit`. Every updated/deleted ref must match its expected old OID; every
  created ref must be absent. A failed transaction publishes none of its changes.
- Never insert an implicit stash, `reset --hard`, forced checkout or discarded
  resolution. Navigate with
  `git switch --quiet --no-guess --no-overwrite-ignore -- <branch>`;
  detach with `git switch --quiet --no-overwrite-ignore --detach <oid>`.
- Use NUL-delimited status and worktree listings. **Clean** means no staged,
  unstaged or untracked changes anywhere in the worktree. **Quiescent** means
  clean with no cherry-pick, merge, revert, rebase or sequencer operation.
  Only a validated replay pick may bypass that operation check.
- Automated commits bypass hooks and signing; user-created Git commits retain
  their configuration. Before replay picks, recheck ignored files after checkout
  hooks. All commands operate locally and perform no fetch, push or PR creation.

`stakrr.state` is exactly one nonempty local config value containing
`v1 <base-ref> <work-ref>`. Base and work are distinct local branches outside
`refs/heads/stakrr/`. Each layer branch `refs/heads/stakrr/<name>` has a recorded
boundary `refs/stakrr/layers/<name>`. A branch differing from its record is
**stale**. `refs/stakrr/anchor` fixes the base OID at initialization;
`refs/stakrr/tip` guards the highest recorded boundary.

**Inspect the stack** means: read config, anchor, base/work tips, layer branches
and records; require anchor ancestry; read
`git rev-list --parents --reverse <anchor>..<work>` once and reject merges;
match layers with their records; order boundaries by depth; require strictly
increasing boundaries above the anchor and a matching tip guard. With no layers,
the tip guard must be absent. Stale branches are allowed. A moved base is a
warning and must not silently change the anchor.

Object creation is separate from publication: a refused rewrite can leave
unreachable candidate objects. Atomic ref publication does not imply atomic
config writes or rollback of worktree changes.

Build checkpoints in object storage with `hash-object` and `commit-tree`.
The tree holds `session.json`, `rescue`, `previous` and an optional replay `plan`.
The previous checkpoint is the first parent; additional parents retain rescue
commits and original/replacement boundaries. Publish the checkpoint ref in the
same transaction as any accompanying branch changes.

## help and version

Print usage or the build version. Run no Git commands and require no repository.
No arguments, `help`, `--help` and `-h` select help; `version` and `--version`
select version.

## init

`stakrr init --base <branch>` adopts the current branch as rolling work.

1. Lock and refuse an active edit, existing config, layer branches, records,
   anchor or tip. Old operation-log history may remain.
2. Read symbolic HEAD. Require a valid, distinct local base branch and both
   branch names outside the layer namespace. Resolve both tips, require base
   ancestry, and reject merges in `base..work`.
3. Create the anchor at the observed base OID in a ref transaction.
4. Write `git config --local stakrr.state 'v1 <base-ref> <work-ref>'`.
   On failure, attempt to delete the just-created anchor with its expected OID.
   A crash between these separate writes leaves state that `reset` can remove.

Keep HEAD, branches, index and files in place. Dirty work is allowed.

## status

1. Require a working tree and read `refs/stakrr/edit` first.
2. With an active edit, validate its checkpoint and replay plan, read HEAD and
   any stopped commit's subject, and render the session view. Do not require
   partially edited refs to form a finished stack.
3. Otherwise inspect the stack, read HEAD, and render layer counts, unstacked
   work, stale branches and the moved-base warning.

Take no mutation lock and publish no changes. Report corrupt state without
repairing it. Status is an unlocked observation and may race with mutations.

## cut

`stakrr cut <name> [--at <rev>]` records the next boundary without rewriting work.

1. Lock and refuse an active edit. Validate the new ref with
   `git check-ref-format`, inspect the stack, and require HEAD on work.
   Refuse stale layers and existing names, including parent/child ref collisions.
2. Resolve `<rev>^{commit}`, defaulting to the observed work tip. Require the
   target strictly above the highest recorded layer (the anchor for the first
   cut) and ancestral to work.
3. In one transaction verify anchor, work tip and the previous layer branch
   when present; create the new layer branch and its record at the target;
   create the tip guard for the first cut or update it from the previous
   boundary to the target.

Keep HEAD, existing branches, index and files in place. Dirty work is allowed.
A failed transaction leaves every ref unchanged.

## go up and down

1. Lock, refuse an active edit, and inspect the stack.
2. `go <cut>` resolves a short layer name. `up`/`down` require symbolic HEAD on
   the stack and select the adjacent branch in `base → ordered layers → work`.
   At the requested end, succeed without switching.
3. Run the protected branch switch from the shared rules. Let Git reject an
   occupied branch or conflicting local changes; carry compatible changes.

Move HEAD and let checkout update index/files. Change no branch tips or stakrr
metadata. Unrelated ignored files are allowed.

## fix

`stakrr fix [<cut>] -m <message>|--amend` folds staged changes into a layer.

1. Lock, refuse an active edit, inspect the stack, and require HEAD on work with
   no Git operation. Require layers and no stale layer. Select the named layer,
   defaulting to the highest; require it and all higher layers to be free in
   other worktrees. Then require a staged diff with `git diff --cached --quiet`.
2. Capture the index with `git write-tree`; create a temporary commit with that
   tree and old work as parent. Merge it into the target layer using
   `git merge-tree --write-tree --no-messages --merge-base=<old-work> <old-layer> <staged-commit>`.
3. For `-m`, create a new commit on the layer. For `--amend`, replace its tip
   using the folded tree and original parent; preserve author, committer and
   message, dropping invalidated signatures.
4. Replay `old-layer..old-work` oldest first in object storage. For each commit,
   merge with its old parent as base and the rewritten cursor as ours, then
   rewrite it with the resulting tree and cursor as parent. Map each crossed
   layer boundary to its replacement. Refuse any conflict or a final work tree
   differing from the captured index tree.
5. Build a completed checkpoint retaining original/replacement boundaries and
   old work. In one transaction update the target/higher layer branches and
   records, work, tip guard and operation log; verify the anchor. Compare every
   changed ref with its observed old OID.

Keep HEAD, the staged tree and working files in place. The staged diff becomes
empty against new work; unstaged edits remain. Refusal publishes no refs and
creates no active edit. A completed fix can be undone.

## restack

`stakrr restack` incorporates an edited layer and replays its descendants.

1. Lock. Refuse an existing session after validating its checkpoint, owner, refs
   and availability. For a new edit, require quiescence and inspect the stack.
   No stale layer means nothing to restack; more than one is an error.
2. Save the invocation branch as the return destination. Require managed
   branches and destination to be free in other worktrees. The stale tip must
   contain at least one linear commit above the preceding recorded boundary,
   or anchor for the first layer. Amends are allowed.
3. Save a replay plan from the stale layer's **old recorded** boundary through
   old work, oldest first. If replay is needed, refuse all ignored files
   throughout the worktree before detaching.
4. Save `detaching` in `refs/stakrr/edit`, verifying observed branch tips,
   records, tip guard and anchor. Retain the edited tip and original boundaries.
   Bind the session to this worktree's absolute Git directory.
5. Advance through these phases, retaining empty commits and upper deletions.

| Phase | Required Git action and next checkpoint |
| --- | --- |
| `detaching` | Require quiescence and, for a nonempty replay, the ignored-file guard; detach at the edited tip; save `replay`. Recheck ignored files after checkout hooks before picking. |
| `replay` | Require detached HEAD. Cherry-pick each planned commit with hooks/signing/rerere disabled and empty commits retained. Checkpoint replacement boundaries, next index and HEAD after each pick. |
| `conflict` | Save the stopped plan position and return exit 3. Keep the resolution in the index/worktree and managed boundaries unpublished. |
| `publishing` | Require quiescence, expected detached HEAD, unchanged refs/config and available branches. In one transaction move all layer branches, records, work and tip to pending OIDs, and save `switching`. Include coincident highest-layer/work tips. |
| `switching` | Recheck quiescence, refs and availability; switch to the invocation branch. Atomically update `refs/stakrr/oplog` and delete `refs/stakrr/edit`, verifying anchor, tip, branches and records. |

The user's edit already moved the stale branch before restack began. Other
managed branches retain their published tips until the publication transaction.
Replay changes detached HEAD, index and files. Conflicts and interruptions retain
a session for `continue`, `abort` or `quit`.

## continue

1. Lock and require an active session. Validate checkpoint, owner, config,
   anchor, tip, records, branches and worktree availability. For phases carrying
   a replay plan, compare the whole plan with original linear history and
   require every descendant boundary in order.
2. Resume the saved phase. For an active pick, require `CHERRY_PICK_HEAD` to
   identify the planned commit and HEAD to match the saved parent. Require no
   unresolved, unstaged or untracked changes. Commit staged resolutions with
   `--allow-empty --allow-empty-message --no-edit`, bypassing hooks/signing.
   If a pick was already committed, require exactly the expected single parent
   and incorporate it once.
3. Resume replay/publication/return as above. In `switching`, only return and
   archive. In `aborting`/`aborted`, finish restoration instead of replaying.

A new conflict again returns exit 3 and retains the session. Never repeat
completed picks solely because the process restarted.

## abort

1. Lock and validate session, owner, refs, plan and availability. Require clean
   work. Any active cherry-pick must match the saved replay position; reject
   unrelated Git operations.
2. Save `aborting` with expected current OIDs and restoration targets before
   moving refs. For restack, targets are original **recorded** boundaries and
   work, including the stale layer's position before the user's edit. Retain
   current HEAD. For an active pick, run `git cherry-pick --quit`.
3. Detach at current HEAD. In one transaction restore layer branches, records,
   work and tip, and save `aborted`. Return to the invocation branch; atomically
   archive the checkpoint and delete the active session.

Retain edited commits and committed resolutions through the journal. Require
the user to preserve uncommitted resolutions first. Resume interruptions through
`continue` or `abort`. For a pending undo, honor its saved restoration targets.

## quit

1. Lock and require a session. Try loading it; on `InvalidEditSession`, use the
   corrupt-checkpoint archive path. Enforce the owner when readable. Allow ref
   drift and dirty work, but refuse any Git operation, including a replay pick.
2. Retain HEAD and the checkpoint in a new operation-log commit. Preserve corrupt
   commits as parents, or corrupt blobs/trees as archive-tree entries.
3. In one transaction update/create the operation log and delete the session,
   comparing both refs with their observed old values.

Keep HEAD, branches, config, index and files in place. The stack may need
`reset`; quit does not finish or undo the edit.

## undo

1. Lock, refuse an active edit, and require quiescence. Walk the operation log
   to the newest valid finished/undone checkpoint, skipping invalid metadata
   and aborted/quit operations when traversable.
2. Require config, anchor, tip, records and every managed branch to match that
   operation's published result. Require branches and invocation branch to be
   available. A different worktree may start this new operation.
3. Set restoration targets to the operation's originals; save current published
   OIDs as the undo's originals. Assign the new owner/destination and save
   `aborting` before changing refs.
4. Use abort's restoration flow. Return to the invocation branch, archive with
   outcome `undone`, and atomically delete the active session.

Restore branch positions; do not recreate staged changes from before a fix.
Another undo reverses this undo. Resume an interrupted undo through `continue`.

## log

1. Require a working tree. Start at `refs/stakrr/edit` when present, otherwise
   `refs/stakrr/oplog`; follow explicit `previous` checkpoint links.
2. Read timestamps, labels and rescue OIDs. Decode metadata without replay-plan
   validation. Compare checkpoints within one session for branch moves; for a
   new operation compare its originals with its published/expected OIDs.
3. Print newest first, including readable corrupt-session archives. With no
   entries, print `no edit history`.

Take no mutation lock, repair nothing and expire no recovery data. Checkpoint
parents retain original/replacement commits through Git garbage collection.

## reset

`stakrr reset [--delete-layers]` forgets stack metadata, including corrupt state.

1. Lock and refuse an active edit. List layer branches, records, anchor and tip
   without parsing config or requiring a valid stack.
2. With `--delete-layers`, refuse a layer checked out in this or another
   worktree. Otherwise preserve layer branches.
3. In one transaction delete anchor, tip and all records; delete layer branches
   only when requested. Use each ref's observed old OID.
4. Run `git config --local --unset-all stakrr.state`, accepting an absent key.
   Rerun reset if config removal fails after ref deletion. Report uninitialized
   only when no config, stack refs or layer branches existed.

Keep HEAD, base/work branches, index, files and operation-log history. Retained
layer branches block initialization until removed or deleted by another reset.

## Implementation and verification

| Flows | Implementation | Regression coverage |
| --- | --- | --- |
| Init, inspect, cut, navigation, reset | [stack.zig](../src/stack.zig) | [stack](../tests/stack_test.zig), [cut](../tests/cut_test.zig), [reset](../tests/reset_test.zig) |
| Fix | [fix.zig](../src/fix.zig) | [fix](../tests/fix_test.zig) |
| Restack and recovery, undo, log | [edit.zig](../src/edit.zig), [checkpoint codec](../src/edit_session.zig) | [edit](../tests/edit_test.zig), [recovery](../tests/edit_recovery_test.zig), [undo](../tests/undo_test.zig) |
| Arguments, output and exits | [cli.zig](../src/cli.zig), [main.zig](../src/main.zig) | [CLI](../tests/cli_test.zig) |

Preserve tests around checkpoint creation, successful picks before journaling,
publication and final archival. On failure retain the last successful checkpoint
and publish no partial ref transaction. Exit codes are 0 success, 1 failure,
2 usage, 3 replay conflict pending, 4 dirty/ignored work or an active Git operation,
and 5 externally changed edit state.
