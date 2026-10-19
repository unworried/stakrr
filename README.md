# stakrr
CLI tool designed to streamline downstacking from a rolling branch.

---

### why zig?
you can only relax when the agents are sleeping. also, its fast and I like using it

---

## design
- working at the development HEAD
- make a cut at the current HEAD or specified commit-like
- branch is created for the cut and is stacked below the dev branch
- new branch is stacked on top of pre-existing cuts
- e.g.
feature-p1 => feature-p2 => HEAD
```sh
$ stakrr cut feature-p3
```
feature-p1 => feature-p2 => feature-p3 => HEAD
- feature-p3 contains all the commits feature-p2..HEAD by default can be adjusted
- allow for commits to be edited as usual allowing for standard branch actions
- integration with `gh stack` allowing for third-party stack to be linked to githubs system

## CLI API
| command | purpose | status |
| --- | --- | --- |
| stakrr init --base \<branch\> | adopt current branch as stack head | m1 |
| stakrr cut \<name\> [--at \<rev\>] | extract existing commit boundary into a lower layer | m1 |
| stakrr status | display stack, ancestry and outstanding commits | m1 |
| stakrr reset [--delete-layers] | forget the stack so it can be re-initialised | m1 |
| stakrr amend | amend a lower layer and restack the descendants | planned |
| stakrr submit | publish review branches, excluding rolling work | planned |
| stakrr undo | restore previous stakrr operation | planned |


## cut
after `stakrr init --base main`, keep committing to your rolling branch

```sh
stakrr cut feature-p1 --at HEAD~1  # create a layer at an earlier commit
stakrr cut feature-p2              # cut at the rolling branch tip
stakrr status
```

`cut` creates a `stakrr/<name>` branch at a commit boundary; it never changes
`HEAD`, working files, the index, or existing layer branches. Each cut must
advance beyond the previous boundary and be reachable from the rolling branch.

If the base branch moves after `init` (e.g. `git pull` on main), `cut` keeps
working: layers are carved relative to the original base commit, and
`status` warns that the base moved. Restacking onto the new base is planned.

## state
- `git config stakrr.state`: `v1 <base_ref> <work_ref>`. One stack per
  repository, shared by all worktrees.
- `refs/stakrr/anchor`: the base commit at `init`. It also keeps that
  commit reachable for gc.
- `refs/stakrr/tip`: an internal concurrency guard pointing at the highest
  layer. The first cut creates it, and later cuts compare-and-swap it in the
  same Git ref transaction as the new layer and a check of the anchor and work
  branch. An aborted cut leaves existing refs unchanged.
- `refs/heads/stakrr/*`: layer branches.

Do not edit the internal refs by hand. This M1 implementation does not rewrite
commits or extract hunks.

## recovery
`status` and `cut` refuse to run when the stack no longer matches the rolling
branch. That happens after rebasing work past the base, deleting a layer
branch, or upgrading from an incompatible state version. To start over:

```sh
stakrr reset                  # drop stakrr state; keep stakrr/* branches
stakrr reset --delete-layers  # also delete the stakrr/* layer branches
stakrr init --base main
```

`reset` never touches the rolling branch, HEAD, the index or the working tree.
It refuses to delete layers while one of them is checked out.

stakrr runs the `git` found on `PATH` and inherits the environment
(`GIT_DIR` and so on).

## why not just use `gh stack`?
- it is slow
- find myself building stacks as an afterthought instead of as I develop
- allows for the ability to work continuously at the top of a branch and gradually carve out reviewable units from underneath it, without needing to manually manage Git history each time.

## development roadmap
### m1: safe rolling stacks
implement init, cut, status, and integration tests. no history rewriting or github dependency. MVP.
### m2: publishing and recovery
implement submit through gh stack link, operation journaling, and undo for stakrr-owned ref changes. test interrupted operations.
### m3: patch level extraction
select individual hunks from a commit, extract them into a lower layer, replay descendants, and keep the rolling work branch usable

## base requirements
- dont rewrite history where not required
- use compare-and-swap ref updates
- create recovery points
- treat conflicts as resolvable failures not hidden problems
- keep remote operations separate
- validate git worktrees
