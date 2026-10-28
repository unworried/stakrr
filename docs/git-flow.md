# Git command flows

## Shared mutation lock

`init`, `cut`, `reset`, `up` and `down` require a working tree and hold
`<git-common-dir>/stakrr.lock` from before reading stack state until the
operation finishes. Linked worktrees share this advisory lock. If another
stakrr mutation holds it, refuse immediately with `another stakrr mutation
is running` (exit 1), without changing refs, config, HEAD, the index or user
files. Read-only `status` does not acquire the lock.
After acquiring it, recover pending ref publication before reading stack state.

Release the lock on success and failure by closing its file. Keep the file
in place: unlinking it could let two processes lock different inodes. An
unlocked file is harmless and must not prevent the next mutation.

The lock coordinates stakrr commands; other Git processes do not honor it.
Continue publishing refs with compare-and-swap transactions and preserving
user files and uncommitted work.

## Object creation

Create blobs, trees and checkpoint commits through Git's `hash-object`,
`mktree` and `commit-tree` plumbing. Use Git's returned object IDs for both
SHA-1 and SHA-256 repositories. Object creation leaves refs, HEAD, the index
and working files in place; ref publication remains a separate transaction.
Checkpoint commits preserve parent order, omit duplicate parents and bypass
hooks and signing.

Merge candidate commits with `merge-tree --write-tree --merge-base=<base>`;
this explicit-base operation requires Git 2.40 or newer. A merge conflict
returns no tree. Rewrite commits with the replacement tree and one parent,
preserving author, committer, message and other metadata while dropping
invalidated signatures and merge tags. Both operations leave refs, HEAD,
the index and working files in place.

## Ref discovery

Managed branches and internal refs must be direct refs. Reject symbolic aliases
when reading full ref names or resolving them to commits, even when their target
has the expected object ID or is missing. Read HEAD's immediate target without
following branch aliases; commands requiring a current branch reject those aliases.
Ordinary symbolic HEAD and Git operation pseudorefs keep their usual behavior.

Prefix discovery checks loose ref names as well as `for-each-ref` output, because
Git omits dangling symbolic refs from its listings. Inspect only names under the
requested prefix, ignore lock files, and support packed refs. In linked worktrees,
use Git's resolved refs directory. Refuse discovery on ref storage other than
Git's files backend rather than overlooking dangling aliases.

`init`, `status`, `cut`, navigation and `reset` refuse managed symbolic refs
without changing refs, config, HEAD, the index or user files. Reset also refuses
symbolic layer refs when keeping layers. Restore direct refs before retrying.

## Ref publication

Publish with `update-ref --no-deref --stdin`, full object IDs and explicit
compare-and-swap expectations. Send `prepare`, wait for Git to acknowledge
that all requested refs are locked, then check each named ref with
`symbolic-ref --quiet --no-recurse`. Reject symbolic refs, including dangling
aliases and aliases resolving to the expected object ID, by sending `abort`.
Send `commit` only after every ref passes. Keep the locks through that decision;
a check before starting Git cannot prevent symbolic substitution races.
`reset` also refuses to publish a transaction containing a symbolic ref;
restore its direct value before retrying. Refusal preserves refs and config.

Drain stdout and stderr while writing the prepared request. Preserve Git
diagnostics on refusal, and release child processes and pipes on transport
errors. Individual ref writes are crash-atomic; this protocol alone does not
recover a transaction interrupted between ref writes.

## Branch availability across worktrees

Use the shared branch guards before rewriting or deleting branches. Parse
`worktree list --porcelain -z` to preserve paths containing spaces and newlines,
and compare full branch ref names. Use Git's resolved checked-out branch so
single and nested branch aliases cannot hide a layer checkout.

A rewrite may include the caller's own branch; deletion must also refuse that
checkout with `LayerCheckedOut`. Any requested branch checked out in another
worktree fails with `BranchOccupied`. Check every worktree, including forced
duplicate checkouts, separate Git directories and linked worktrees of bare
repositories. Detached and unrelated checkouts do not block the operation.

`reset --delete-layers` runs the deletion guard under the mutation lock before
publishing refs or removing config. Refusal preserves refs, config, HEAD, the
index and user work. Keeping layers permits their checkouts in other worktrees.

## Interrupted ref publication

Before a transaction with multiple ref writes, save its expected old and new
values under `refs/stakrr/transaction`. Retain commits, trees, blobs and annotated
tag contents so garbage collection cannot discard objects needed for recovery.
Verify old values and create the intent ref in one compare-and-swap transaction,
then publish the requested updates. Clear the intent only after verifying all
new values. Single-ref writes use Git's existing per-ref atomicity.

The next stack mutation recovers under the shared lock. Refs already at the new
value are verified; refs still at the old value are advanced or deleted. Refuse
unexpected values, symbolic substitutions, occupied branches, checked-out branch
deletions and active Git operations. Keep the intent for inspection and retry.
Never remove Git-owned lock files. A confirmed refusal before preparation cancels
the intent; uncertain or partial publication retains it unless every old value
still matches.

Read-only status never repairs publication. It reports a pending transaction
when any new value remains unpublished, but may inspect a completed transaction
awaiting intent cleanup. Retry a stack mutation to finish pending publication;
reset's config removal remains a separate step after ref recovery.
