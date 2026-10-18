#!/usr/bin/env bash
set -euo pipefail
# tool used to create new test repo w/ stakrr exec in path

# resolve the stakrr project root
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$root/zig-out/bin/stakrr"

# Build unless explicitly disabled.
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    echo "Building Stakrr..."
    (cd "$root" && zig build)
fi

if [[ ! -x "$bin" ]]; then
    echo "Stakrr executable not found: $bin" >&2
    exit 1
fi

# Create an isolated repository.
repo="$(mktemp -d "${TMPDIR:-/tmp}/stakrr-manual.XXXXXX")"
rollbranch="shipit"

cleanup() {
    if [[ "${KEEP_REPO:-0}" == "1" ]]; then
        echo "Preserved test repository: $repo"
    else
        rm -rf -- "$repo"
        echo "Removed test repository."
    fi
}

trap cleanup EXIT

git -C "$repo" init -q -b main
git -C "$repo" config user.name "Stakrr Test"
git -C "$repo" config user.email "test@stakrr.local"

commit() {
    git -C "$repo" commit -q --allow-empty -m "$1"
}

commit "auto:base"

git -C "$repo" switch -q -c "$rollbranch"

commit "auto:feat1:models"
commit "auto:feat2:api"
commit "auto:feat3:ui"
commit "auto:feat4:cleanup"

# Make the local build accessible inside the shell.
PATH="$(dirname "$bin"):$PATH" && export PATH
export STAKRR="$bin"
export STAKRR_TEST_REPO="$repo"

cd "$repo"

echo
echo "Stakrr manual testing environment"
echo "---------------------------------"
echo "Repository: $repo"
echo "Branch:     $rollbranch"
echo "Binary:     $bin"
echo
git log --oneline --graph --decorate --all
echo
echo "Try:"
echo "  stakrr init --base main"
echo "  git config --local --get stakrr.state"
echo "  stakrr init --base main   # Should fail"
echo
echo "Exit the shell with 'exit' or Ctrl-D."
echo

"${SHELL:-/bin/bash}" -i
