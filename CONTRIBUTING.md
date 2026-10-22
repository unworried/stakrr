# contributing

## // build and test

needs zig 0.17.0 and git on `PATH`. the same checks run in ci:

```sh
zig fmt --check .
zig build
zig build test
zig build test -Doptimize=ReleaseSafe
```

`./mktemprepo.sh` drops you into a throwaway repo with a fresh build on `PATH`
for poking at the cli by hand.

The source layout stays flat: `layout.zig` names every ref and config key
stakrr persists; `git.zig` runs Git, parses its output and applies generic ref
transactions; `coordination.zig` owns locks and worktree guards; `stack.zig`
owns stack policy and snapshots; `edit.zig` advances the edit workflow;
`edit_session.zig` holds its private model and checkpoint codec. On the CLI
side, `cli.zig` parses arguments, `render.zig` draws output, `term.zig` styles
it, and `main.zig` dispatches commands and maps errors to messages.

Public snapshots and edit status views own their storage and need `deinit`.
Edit internals use a command arena, with a separate scratch arena for each
checkpoint. Keep history inspection batched and publish refs with the journal
in one compare-and-swap transaction. Recovery tests kill the process around
those checkpoints; preserve their coverage when changing edit phases.

## // commits

[conventional commits](https://www.conventionalcommits.org), lowercase,
imperative, one change per commit. each commit should build and pass tests.

```
<type>(<scope>): <summary>

feat(cli): render status as a stack
fix(stack): validate persisted state before use
feat(stack)!: bump the state format to v2
```

- **types**: `feat` `fix` `perf` `refactor` `test` `docs` `build` `ci` `chore`
- **scopes**: `cli` `stack` `git`, or none for repo-wide changes
- **breaking**: `!` after the scope, or a `BREAKING CHANGE:` footer

commit messages become the release notes through [`cliff.toml`](cliff.toml),
so write the summary for someone reading a changelog.

## // releasing

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
