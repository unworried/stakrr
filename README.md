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
- new branch is stacked ontop of pre existing cuts
- e.g.
feature-p1 => feature-p2 => HEAD
```sh
$ sk cut feature-p3
```
feature-p1 => feature-p2 => feature-p3 => HEAD
- feature-p3 contains all the commits feature-p2..HEAD by default can be adjusted
- allow for commits to be edited as usual allowing for standard branch actions
- intergration with `gh stack` allowing for third-party stack to be linked to githubs system

## CLI API
| command | purpose |
| --- | --- |
| sk init | adopt current branch as stack head |
| sk cut | extract existing commit boundary into a lower layer |
| sk status | display stack, ancestry and outstanding commits |
| sk amend | amend a lower layer and restack the descendants |
| sk submit | publish review branches, excluding rolling work |
| sk undo | restore previous stakrr operation |


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

`refs/stakrr/tip` is an internal concurrency guard. Do not manually edit or
delete it. The first cut creates it; subsequent cuts compare-and-swap it in the
same Git ref transaction as the new layer. Aborted cuts leave existing refs
unchanged. This M1 implementation does not rewrite commits or extract hunks.

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
- keep remote operations seperate
- validate git worktrees
