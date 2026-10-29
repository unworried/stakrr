# contributing

## // build and test

needs zig 0.17.0 and git on `PATH`. the same checks run in ci:

```sh
zig fmt --check .
zig build
zig build test
zig build test -Doptimize=ReleaseSafe
```

`scripts/mktemprepo.sh` drops you into a throwaway repo with a fresh build on `PATH`
for poking at the cli by hand. See [the test guide](tests/README.md) for shared
fixtures, fault injection and the manual regression checklist.

The source layout stays flat: `layout.zig` names persisted refs and the checkpoint
and publication-intent format versions; `git_types.zig` defines validated refs,
branch names, OIDs and ref updates; `git.zig` provides Git queries, object plumbing and
subprocess helpers. `mutation.zig` owns the shared lock from recovery through
publication, checkout and replay. `ref_transaction.zig` retains publication
intent for recovery; `ref_backend.zig` implements Git's ref transaction protocol;
`coordination.zig` provides lock acquisition and worktree guards. `stack.zig`
owns stack policy and snapshots; `edit.zig` advances the edit workflow;
`edit_session.zig` holds its private model and checkpoint codec. On the CLI
side, `cli.zig` parses arguments, `render.zig` draws output, `term.zig` styles
it, and `main.zig` dispatches commands and maps errors to messages.

Public snapshots, edit status views and mutation contexts own resources and need
`deinit`. Validated ref and branch names borrow their input; OIDs store their
bytes inline. Owned branch results and ref listings have explicit `deinit`
methods. See [the Git API](docs/git-api.md) for signatures and ownership rules.
Edit internals use a command arena, with a separate scratch arena for each
checkpoint. Acquire a mutation context before observing state used for a write;
publish refs and perform checkout/replay through that context. Keep history
inspection batched and retain publication intent around multi-ref changes.
Recovery tests kill the process around checkpoints and simulate partial ref
publication; preserve their coverage when changing edit phases or transaction
recovery.

## // command behavior

[Git command flows](docs/git-flow.md) is the implementation contract for every
shipped command. Follow its check order, allowed Git mutations, transaction
boundaries and recovery rules. When changing behavior, update the matching flow
and regression coverage in the same change. Keep the README focused on usage;
keep the exact command flow in that one reference.

Stack manifests, active progress, completed records and publication intents use v1.
During active development, revise these schemas directly and keep readers, writers,
tests and format documentation aligned. Keep their version tags at v1.

## // commits

[conventional commits](https://www.conventionalcommits.org), lowercase,
imperative, one change per commit. each commit should build and pass tests.

```
<type>(<scope>): <summary>

feat(cli): render status as a stack
fix(stack): validate persisted state before use
refactor(git)!: require mutation contexts for ref publication
```

- **types**: `feat` `fix` `perf` `refactor` `test` `docs` `build` `ci` `chore`
- **scopes**: `cli` `stack` `git`, or none for repo-wide changes
- **breaking**: `!` after the scope, or a `BREAKING CHANGE:` footer

commit messages become the release notes through [`cliff.toml`](cliff.toml),
so write the summary for someone reading a changelog.

## // releasing

During active development, keep releases below 1.0 and mark them as GitHub
prereleases, as the release workflow already does. Use a new minor version for
breaking workflow or storage changes. Tags remain numeric (`v0.2.0`); this does
not change the v1 persisted-format tags.

Bring the release branch up to date with `main` before preparing the changelog,
so its history includes the latest release tag. Regenerate the changelog if the
release contents change before tagging.

1. bump `.version` in `build.zig.zon`
2. regenerate the changelog with [git-cliff](https://git-cliff.org)
   (`brew install git-cliff`) and commit both:
   ```sh
   git cliff --tag vX.Y.Z -o CHANGELOG.md
   ```
3. merge to `main`, then tag it with a codename and push the tag:
   ```sh
   git tag -a vX.Y.Z -m "stakrr vX.Y.Z - <codename>"
   git push origin vX.Y.Z
   ```

the release workflow checks the tag against `build.zig.zon` and `main`, builds
the four targets, and publishes them with `SHA256SUMS` and git-cliff notes
titled `stakrr vX.Y.Z ── <codename>`. preview the notes locally with
`STAKRR_RELEASE=1 git cliff --unreleased --tag vX.Y.Z --strip all`.
