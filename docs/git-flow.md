# Git command flows

## Shared mutation lock

`init`, `cut`, `reset`, `up` and `down` require a working tree and hold
`<git-common-dir>/stakrr.lock` from before reading stack state until the
operation finishes. Linked worktrees share this advisory lock. If another
stakrr mutation holds it, refuse immediately with `another stakrr mutation
is running` (exit 1), without changing refs, config, HEAD, the index or user
files. Read-only `status` does not acquire the lock.

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
