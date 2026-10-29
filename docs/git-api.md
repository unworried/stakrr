# Git API

`Git` provides queries, object plumbing, and constructors for validated values.
`Mutation` owns the common repository lock and performs ref publication,
checkout and replay. The internal
`ref_transaction.zig` journal retains interrupted publication intent;
`ref_backend.zig` implements the update-ref handshake and direct-ref checks while
Git holds the requested names locked.

## Values and ownership

- `RefName.init(bytes)` validates a full name in `refs/` using Git's naming rules.
- `BranchRef.init(bytes)` additionally requires a local branch usable by
  `git switch`. Its `name` is a `RefName`.
- Names borrow their input. Retain the source buffer while using the name.
- `Oid.init(format, hex)` validates a nonzero full ID of the repository's object
  format. IDs store their bytes inline and can be copied freely. `hex()` borrows
  from the ID; `dupeHex(allocator)` returns owned bytes.
- `currentBranch()` returns an `OwnedBranchRef`; its `value` borrows its `raw`
  buffer. Release it with `deinit(allocator)`.
- `RefList` owns its raw listing and records. Names borrow that listing; OIDs are
  values. Release the list with `deinit(allocator)`.
- Methods ending in `Alloc` return owned hexadecimal/name bytes for the existing
  snapshot and checkpoint codecs. Snapshot arenas retain their existing lifetime
  and `deinit` contract. These adapters still perform typed validation.

Name validation establishes syntax and namespace, not lasting ref identity.
Reads reject symbolic refs; publication repeats direct-ref checks under Git's
ref locks to protect against symbolic substitution.

## Queries

`readDirectRef(RefName)` returns `?Oid`: null means absent; symbolic refs,
malformed refs, invalid Git output, and process failures return errors.
`listDirectRefs(prefix)` returns a complete direct-ref listing or an error. It
checks loose names under the requested prefix before accepting Git's listing,
and refuses unsupported ref storage.

`resolveCommit(revision)` interprets a user revision expression. Managed branches
use `branchCommit(BranchRef)`, which first reads their exact direct ref and then
resolves the observed OID as a commit. Cherry-pick operation state has a separate
`cherryPickHead()` query.

Object helpers retain their byte-oriented inputs and owned output buffers, but
validate IDs with `Oid` using the repository's object format. Zero IDs and IDs
from the other format are invalid. Malformed IDs in Git's output report
`InvalidGitOutput`; malformed checkpoint IDs and history links report
`InvalidEditSession` so corrupt sessions can still be archived by `quit`.

`commitTree()` uses the repository identity. `commitTreeWithOptions()` shares the
same validation, parent deduplication and signing settings, and accepts an
optional identity without changing config. Publication intents use it with the
stakrr identity so ref bookkeeping works before a user configures their own.

## Mutations

Acquire the context before observing state used to construct updates:

```zig
var mutation = try original_git.beginStackMutation();
defer mutation.deinit();
const git = mutation.repo();

var snapshot = try stack.inspect(git);
defer snapshot.deinit();

// Compute new objects and retain every expected old value.
const updates = [_]Git.RefUpdate{
    try git.updateRef(branch_name, old_hex, new_hex),
    try git.verifyRef(anchor_name, anchor_hex),
};
try mutation.publish(.{ .message = label, .updates = &updates });
```

`beginStackMutation()` requires a working tree, acquires the shared lock, recovers
pending publication, and refuses an active edit session. `beginEditMutation()`
allows that session. `beginRefMutation()` supports bare repositories and provides
the same lock and recovery guarantees without requiring a working tree.

Checkout and replay methods also live on the context: `switchBranch(BranchRef)`,
`detach(Oid)`, `cherryPick(Oid)`, `commitResolution()` and `quitCherryPick()`.
Switching preserves Git's refusal to overwrite ignored files and disables branch
guessing. Automated picks and resolution commits centralize hook/signing settings
and preserve empty commits. Workflows retain validation of cleanliness, HEAD,
ignored files, stopped picks and staged resolutions before calling these methods.

The update union uses validated names and OIDs: `verify.expected` is optional,
`create.new` is required, `update` requires both `old` and `new`, and `delete.old`
is required. Absence is null; zero IDs are emitted only inside the protocol
backend. `Git` also provides validating constructors for byte-oriented workflow
data. Constructing an update does not write it.

Publication derives worktree checks from the actual changes, validates duplicate
names and object formats, enforces expected values and direct refs, and retains
recovery intent for multiple writes. Verification-only and unchanged updates do
not count as branch moves. Command-specific clean-worktree and replay checks
remain in their workflows.

The default `current_branch` policy is `.forbid`. `fix` passes
`.{ .allow = snapshot.config.work_ref }` to allow updating its current work branch.
This permits only the caller's checkout of that exact branch; other worktrees
remain protected, and deletions never receive the exception.

Journal intents persist the exception and originating worktree. Acquisition
uses the same validator when recovering remaining writes. `publish()` refuses
an unexpected pending intent instead of silently recovering after a snapshot
was read. Low-level protocol publication is reserved for the journal backend.

All persisted formats currently use v1: stack configuration, edit checkpoints
and publication intents. Writers and readers use the version constants in
`layout.zig`. Development formats are revised directly without legacy migration.

The common lock coordinates stakrr processes. Ordinary Git writers do not take
it; expected-OID transactions and validation under Git's ref locks remain
necessary. Worktree occupancy checks are observations, not a repository-wide
lock on external Git operations.
