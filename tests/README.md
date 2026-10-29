# Tests

Run the same checks as CI with Zig 0.17.0 and Git on `PATH` (`fix` needs Git
2.40 or newer):

```sh
zig fmt --check .
zig build
zig build test
zig build test -Doptimize=ReleaseSafe
```

`build.zig` registers the inline tests and each integration suite. Add new
integration suites there so both optimization modes exercise them.

## Shared fixtures

- `support/repo.zig` owns disposable repositories and their environment. Use
  `initOptions` for SHA-256 cases. The environment excludes inherited `GIT_*`,
  fault controls, global/system config and forced colors, and uses the C locale.
  `expectRef` requires a full direct ref name. Assert HEAD and operation pseudo
  refs with explicit Git queries. Use `expectFile` to compare exact file bytes.
- `support/cli.zig` runs the built CLI and ref driver, captures stdout/stderr and
  preserves process termination. Always release results with `deinit`.
  `expectSuccess` reports stderr on failure; `expectKilled` requires SIGKILL,
  keeping normal refusals and panics from passing interruption tests.
- `support/edit_fixture.zig` creates a two-layer stack with real file changes,
  an upper deletion and rolling work. Its conflict variant adds a third layer.
  Shared validation checks layer identities and settled boundaries.
- `support/snapshot.zig` compares refs (including symbolic targets), local config,
  HEAD, staged entries, tracked diffs and status. Use it around refused or
  read-only commands. It requires a committed, attached HEAD; check dangling
  aliases and untracked/ignored file contents explicitly too.
- `support/git_fault.sh` injects checkpoint deaths, partial publication,
  transport errors and ref races. Install it through `installFaultShim` and run
  the CLI or ref driver in a child so executable lookup sees the shim's PATH.

Keep expected old values from before a simulated external Git change. Acquire
mutation contexts before observing state used for publication; release the
context before invoking a command that acquires its own lock. Recovery happens
when acquiring the next context. General revision resolution accepts user
revision expressions; managed branches use direct-ref queries and `branchCommit`.

## Manual regression checks

Use `bash scripts/mktemprepo.sh` to enter a disposable repository. Verify actual
CLI output and exit codes as well as refs and file bytes:

- Initialize, cut at HEAD and an earlier commit, navigate through layers and
  inspect status. Existing branch tips and compatible dirty work must survive.
- Stage a fix on a lower layer with unrelated unstaged/untracked work; verify
  descendant contents, then clean the scratch changes and inspect completed records. Compare
  exact branch, manifest and branch OIDs before and after publication.
- Commit on a lower layer, restack, and inspect the operation log. Exercise a
  real replay conflict separately with continue, abort and quit.
- Refuse invalid names, symbolic managed refs, occupied layers and a held
  mutation lock. Compare refs, config, HEAD, index and user bytes on refusal.
- Interrupt a checkpoint and partial ref publication, inspect status without
  repairing it, then continue and confirm the session/transaction refs clear.
- Reset with layer deletion and reinitialize. Run `git fsck --no-reflogs`.

Repeat with SHA-1 and SHA-256 repositories, Debug and ReleaseSafe binaries, and
normal, separate-directory, linked and bare-linked worktrees. Keep manual
transcripts outside the repository being exercised.
