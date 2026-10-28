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
tag=v0.1.0
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
| ● | `stakrr up` / `stakrr down` | switch between the base, layers, and rolling work |
| ● | `stakrr version` | print the version |
| ○ | `stakrr amend` | amend a lower layer and restack the descendants |
| ○ | `stakrr submit` | publish review branches, excluding rolling work |
| ○ | `stakrr undo` | restore the previous stakrr operation |

<sub>● shipped · ○ planned for m2</sub>

## // internals

| ref | holds |
| --- | --- |
| `git config stakrr.state` | `v1 <base_ref> <work_ref>`. one stack per repository, shared by all worktrees |
| `refs/stakrr/anchor` | the base commit at `init`, which also keeps it reachable for gc |
| `refs/stakrr/tip` | concurrency guard at the highest layer, compare-and-swapped in the same ref transaction as each new layer |
| `refs/heads/stakrr/*` | layer branches |

don't edit the internal refs by hand. an aborted cut leaves every ref
unchanged. stakrr runs the `git` on your `PATH` and inherits the environment
(`GIT_DIR` and friends).

## // recovery

`status` and `cut` refuse to run when the stack no longer matches the rolling
branch: after rebasing work past the base, deleting a layer branch, or upgrading
from an incompatible state version. to start over:

```sh
stakrr reset                  # drop stakrr state, keep stakrr/* branches
stakrr reset --delete-layers  # also delete the stakrr/* layer branches
stakrr init --base main
```

`reset` never touches the rolling branch, `HEAD`, the index or the working
tree, and refuses to delete layers while one of them is checked out.

## // roadmap

```
m1  safe rolling stacks      ■■■■  init · cut · status · reset, no history rewrites
m2  publishing + recovery    □□□□  submit via gh stack · operation journal · undo
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

## // editing earlier cuts

Use `stakrr go <cut>` to switch to a layer, then commit or amend with Git.
`stakrr status` marks changed layers as stale. Run `stakrr restack` to replay
what follows the changed layer and return to the branch where you started.
Only one layer may be stale at a time. Replaying descendants requires a clean
worktree with no ignored files.

For a conflict, resolve files, stage them, and run `stakrr continue`. Preserve
uncommitted resolutions before `stakrr abort`, which restores the original
recorded boundaries. `stakrr quit` drops a pending session while retaining HEAD,
branches and recovery history; the stack may then need `stakrr reset`.

`stakrr log` shows retained checkpoints and rescue commits. `stakrr undo`
reverses the last completed restack or undo, provided its published refs still
match. Sessions belong to their originating worktree.

Exit codes are 0 success, 1 failure, 2 usage, 3 replay conflict pending,
4 dirty or ignored work or an active Git operation, and 5 externally changed
edit or publication state.
