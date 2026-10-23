<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/banner-dark.svg">
    <img alt="stakrr: downstack from a rolling branch" src="assets/banner-light.svg" width="100%">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/unworried/stakrr/actions/workflows/ci.yml"><img alt="ci" src="https://img.shields.io/github/actions/workflow/status/unworried/stakrr/ci.yml?branch=main&style=flat-square&label=ci&labelColor=0a0a0f&color=00f0ff"></a>
  <a href="https://github.com/unworried/stakrr/releases"><img alt="release" src="https://img.shields.io/github/v/release/unworried/stakrr?include_prereleases&style=flat-square&label=release&labelColor=0a0a0f&color=00f0ff"></a>
  <img alt="zig 0.17.0" src="https://img.shields.io/badge/zig-0.17.0-ff2a6d?style=flat-square&labelColor=0a0a0f">
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/github/license/unworried/stakrr?style=flat-square&label=license&labelColor=0a0a0f&color=5c5c70"></a>
</p>

<p align="center"><code>keep committing at the top. carve reviewable layers out from underneath.</code></p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/session-dark.svg">
  <img alt="terminal session: stakrr init, two cuts, then stakrr status drawing the stack" src="assets/session-light.svg" width="100%">
</picture>

## // why

stacked prs are great until you have to plan them up front. stakrr flips that:
work continuously on one rolling branch, then cut reviewable layers out from
underneath it as the boundaries become obvious, without hand-managing git
history each time.

- `gh stack` is slow, and i kept building stacks as an afterthought anyway
- a cut only creates a branch. no rebases, no rewritten commits
- every ref update is compare-and-swap, so a racing or aborted cut changes nothing

## // install

grab a build from [releases](https://github.com/unworried/stakrr/releases),
verify it and put it on your `PATH`:

```sh
tag=v0.0.2             # latest from the releases page
target=aarch64-macos   # x86_64-macos · aarch64-linux-musl · x86_64-linux-musl
curl -fsSLO https://github.com/unworried/stakrr/releases/download/$tag/stakrr-$tag-$target.tar.gz
curl -fsSLO https://github.com/unworried/stakrr/releases/download/$tag/SHA256SUMS
shasum -a 256 -c --ignore-missing SHA256SUMS
tar -xzf stakrr-$tag-$target.tar.gz && mv stakrr ~/.local/bin/
```

or build from source with zig 0.17.0:

```sh
zig build -Doptimize=ReleaseSafe   # → zig-out/bin/stakrr
```

## // usage

```sh
git switch -c shipit             # the rolling branch, on top of main
stakrr init --base main

# ...commit as you go...

stakrr cut models --at HEAD~3    # oldest work becomes stakrr/models
stakrr cut api                   # everything since, up to the tip, becomes stakrr/api
stakrr status
```

## // editing earlier cuts

Edit commands print a short confirmation. Use `stakrr status` for the full stack,
active edit phase, and any instructions needed to continue.

Use ordinary Git commits or amendments on a cut. Descendants replay when you
jump to another cut or finish the session:

```sh
stakrr edit models
# edit files...
git add model.zig
git commit -m "fix validation"    # git commit --amend also works
stakrr edit api                  # replay, then switch to stakrr/api
# edit and commit more if needed...
stakrr edit                      # replay and return to the original branch
```

An unchanged cut only needs a checkout. A changed cut replays each descendant
commit in order, including unstacked rolling work. Empty commits stay present;
upper-layer deletions stay deletions, with normal Git conflicts if an edit
changes a file deleted above it. Cuts must retain at least one linear commit
above their previous boundary. Changing earlier boundaries or merging branches
inside an edit is unsupported.

Transitions require a clean index and working tree, including untracked files.
No implicit commits or stashes are made. Checkouts refuse to overwrite ignored
files. Before replaying descendants, preserve and remove **all ignored files**,
including unrelated build output: Git's rename handling can write paths absent
from the incoming commit's diff. Unchanged cuts can still be navigated with
unrelated ignored files present. During a session, `init`, `cut` and `reset`
are blocked in every worktree.
`up` and `down` replay changes and move to the adjacent cut; `up` from the
top cut finishes the session. `down` stops at the bottom cut.

On a conflict, the pending destination and session remain saved:

```sh
stakrr status
# resolve conflicts, using git rm for a deletion if appropriate...
git add <resolved-files>
stakrr edit --continue
```

`--continue` works after restarting stakrr. A manually committed resolution also
works. Replay temporarily uses detached HEAD; do not switch branches during it.
The rewritten boundaries, rolling branch and internal tip are published together
only after replay completes. Automated replay commits bypass hooks and signing;
ordinary commits you create while editing keep your normal Git configuration.

`stakrr edit --abort` restores the stack from before the **entire** session,
including changes incorporated during earlier jumps. It requires clean work:
commit or otherwise preserve conflict resolutions and other uncommitted changes
first. It never runs `reset --hard` or discards files. `stakrr edit --undo`
returns to the previous editing checkpoint, reversing the last jump and its
branch changes while keeping the session open. Repeating it walks back through
earlier jumps. Both commands retain the work they reverse in the operation log.

After finishing an edit, `stakrr undo` restores the branch positions from before
the session. It refuses if a managed branch or guard has moved since the edit,
if work is uncommitted, or if an affected branch is checked out in another
worktree. An undo is recorded as an operation too: run `stakrr undo` again to
undo that undo. Interrupted restorations resume with `stakrr edit --continue`.

`stakrr log` lists checkpoints newest first, including an active session. Each
line gives an ISO 8601 timestamp, a readable step label, the before → after OIDs
of moved branches, and a rescue commit:

```sh
stakrr log
git branch rescue <commit-from-the-rescue-column>
```

Completed sessions remain reachable from `refs/stakrr/oplog`. Checkpoints keep
original boundaries and observed edit/replay commits reachable even after
`git gc --prune=now`. No new `refs/stakrr/recovery/*` refs are written; existing
v1 recovery refs remain available through `git for-each-ref refs/stakrr/recovery/`.
Retention is intentional and has no automatic expiry. Direct Git
commands in other processes do not take stakrr's lock; avoid concurrent manual
branch updates or worktree changes during an edit. Detected external changes
stop the operation and name the ref or HEAD that moved, with the commands to
keep it on a rescue branch and restore the expected value:

```sh
error: Git refs or HEAD changed outside the edit workflow; ...
hint: refs/heads/stakrr/api is at 9f8e7d6..., expected 1a2b3c4...
hint: keep it:    git branch rescue/stakrr/api 9f8e7d6...
hint: restore it: git update-ref refs/heads/stakrr/api 1a2b3c4... 9f8e7d6...
```

To keep the changed state instead, `stakrr edit --quit` drops the session like
`git rebase --quit`: HEAD, the index, files and branches stay as they are, and
HEAD plus the checkpoint are retained in `refs/stakrr/oplog` (inspect them with
`stakrr log`). It also works when the checkpoint is corrupt. Afterwards
`stakrr status` may need `stakrr reset`.

## // model

```
  ▸ shipit          ●  ●        unstacked, keep committing
  │
  │ stakrr/api      ●  ●  ●     layer 2
  │
  │ stakrr/models   ●           layer 1
  │
  └ main            ●           base, anchored at init
```

- `cut` creates a `stakrr/<name>` branch at a commit boundary on the rolling
  branch. the layer holds every commit between the previous boundary and its own
- it never changes `HEAD`, the index, working files or existing layer branches
- each cut must advance past the previous boundary and be reachable from the
  rolling branch
- if the base moves after `init` (`git pull` on main), cuts keep working relative
  to the original base commit and `status` warns. restacking onto the new base
  is planned

## // commands

|   | command | does |
| - | --- | --- |
| ● | `stakrr init --base <branch>` | adopt the current branch as rolling work on top of `<branch>` |
| ● | `stakrr cut <name> [--at <rev>]` | cut the next layer at `<rev>`, the tip by default |
| ● | `stakrr status` | draw the stack: layers, commit counts, unstacked work |
| ● | `stakrr reset [--delete-layers]` | forget the stack so it can be re-initialised |
| ● | `stakrr version` | print the version |
| ● | `stakrr edit [<cut>]` | edit a cut, replay descendants, or finish and return to origin |
| ● | `stakrr edit --continue` | resume a pending replay or checkout |
| ● | `stakrr edit --abort` | restore the entire pre-session stack and return to origin |
| ● | `stakrr edit --undo` | reverse the last jump and return to its editing checkpoint |
| ● | `stakrr log` | list edit checkpoints, branch moves and rescue commits |
| ● | `stakrr edit --quit` | drop the session, leaving HEAD and every branch as they are |
| ○ | `stakrr submit` | publish review branches, excluding rolling work |
| ● | `stakrr undo` | reverse the last finished edit, including an undo |

<sub>● shipped · ○ planned for m2</sub>

## // internals

| ref | holds |
| --- | --- |
| `git config stakrr.state` | `v1 <base_ref> <work_ref>`. one stack per repository, shared by all worktrees |
| `refs/stakrr/anchor` | the base commit at `init`, which also keeps it reachable for gc |
| `refs/stakrr/tip` | concurrency guard at the highest layer, compare-and-swapped in the same ref transaction as each new layer |
| `refs/heads/stakrr/*` | layer branches |
| `refs/stakrr/edit` | v2 checkpoint commit for the active session, shared by all worktrees and bound to one owner |
| `refs/stakrr/oplog` | latest completed checkpoint, retaining previous sessions and undo operations |
| `refs/stakrr/recovery/<session>/<oid>` | legacy v1 recovery objects; still readable, no longer created |
| `<git-common-dir>/stakrr.lock` | advisory lock held for each stakrr mutation; released automatically on process exit |

Each v2 checkpoint tree contains `session.json`, an immutable replay `plan`
when needed, and the previous checkpoint and rescue metadata. Its first parent
is the previous checkpoint; additional parents retain original and rewritten
commits, as in `git stash`. The session ref advances in the same compare-and-swap
transaction as branch publication. Finishing, aborting or quitting updates the
oplog and deletes the active ref in one transaction. In-progress v1 blob
checkpoints remain readable and migrate on their next checkpoint.

don't edit the internal refs by hand. an aborted cut leaves every ref
unchanged. stakrr runs the `git` on your `PATH` and inherits the environment
(`GIT_DIR` and friends).

## // recovery

During an edit, inspect `stakrr status` and use `stakrr edit --continue` after a
crash. Use `stakrr edit --undo` to reverse a jump, `--abort` to restore the whole
session, or `--quit` to keep the current Git state and leave the session. Preserve
uncommitted work first. `stakrr log` shows retained commits both during and after
a session; create a rescue branch from the listed commit before experimenting.
Older recovery refs remain visible with `git for-each-ref refs/stakrr/recovery/`.

Outside a managed edit, `status` and `cut` refuse to run when the stack no longer matches the rolling
branch: after rebasing work past the base, deleting a layer branch, or upgrading
from an incompatible state version. to start over:

```sh
stakrr reset                  # drop stakrr state, keep stakrr/* branches
stakrr reset --delete-layers  # also delete the stakrr/* layer branches
stakrr init --base main
```

`reset` never touches the rolling branch, `HEAD`, the index or the working
tree, and refuses to delete layers while one of them is checked out in any
worktree.

## // roadmap

```
m1  safe rolling stacks      ■■■□  init · cut · status · reset, no history rewrites
m2  publishing + recovery    ■■■□  operation journal · log · undo · submit via gh stack (planned)
m3  patch-level extraction   □□□□  move hunks into a lower layer · replay descendants
```

## // principles

- don't rewrite history where it isn't required
- compare-and-swap every ref update
- create recovery points
- treat conflicts as resolvable failures, not hidden problems
- keep remote operations separate
- validate git worktrees

## // why zig?

you can only relax when the agents are sleeping. also, it's fast and i like
using it.

---

<sub>[changelog](CHANGELOG.md) · [contributing](CONTRIBUTING.md) · [mit](LICENSE)</sub>
