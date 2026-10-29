#!/bin/sh
# Test-only Git wrapper. Kill stakrr immediately before/after a chosen ref
# checkpoint, or after a successful pick, to exercise persisted recovery.
if [ "${STAKRR_TEST_OLD_MERGE_TREE:-}" = 1 ]; then
    for arg do
        if [ "$arg" = merge-tree ]; then
            printf '%s\n' "error: unknown option 'merge-base'" >&2
            exit 129
        fi
    done
fi
# Attempt a competing symbolic-ref write during the client's post-prepare
# validation. The named ref must remain locked until commit or abort.
if [ "${1:-}" = symbolic-ref ] && [ -n "${STAKRR_TEST_LOCK_REF:-}" ] &&
   [ "${4:-}" = "$STAKRR_TEST_LOCK_REF" ]; then
    lock_path=$("$STAKRR_TEST_GIT" rev-parse --git-path "$STAKRR_TEST_LOCK_REF.lock") || exit $?
    if [ -f "$lock_path" ]; then
        "$STAKRR_TEST_GIT" symbolic-ref "$STAKRR_TEST_LOCK_REF" refs/heads/victim >/dev/null 2>&1
        printf '%s' "$?" > "$STAKRR_TEST_LOCK_MARKER" || exit $?
    fi
fi
checkpoint=false
pick=false
archive=false
update=false
partial=false
race=false
for arg do
    [ "$arg" != update-ref ] || update=true
    case "$arg" in
        'stakrr: checkpoint '*) checkpoint=true; boundary=${arg#stakrr: checkpoint } ;;
    esac
    [ "$arg" != 'cherry-pick' ] || pick=true
    [ "$arg" != "${STAKRR_TEST_PARTIAL_LABEL:-}" ] || partial=true
    [ "$arg" != "${STAKRR_TEST_RACE_LABEL:-}" ] || race=true
    case "$arg" in
        'stakrr: restack'|'stakrr: abort restack'|'stakrr: quit edit') archive=true ;;
    esac
done
# Read the full request before injecting a transport failure, so cleanup tests
# do not depend on a blocked input writer or the scheduling of short pipe writes.
if [ "$update" = true ] && [ -n "${STAKRR_TEST_TRANSACTION_FAULT:-}" ]; then
    while IFS= read -r line; do
        [ "$line" != prepare ] || break
    done
    [ "${line:-}" = prepare ] || exit 1
    printf '%s\n' "$line" > "$STAKRR_TEST_TRANSACTION_FAULT_MARKER" || exit $?
    printf 'start: ok\n'
    case "$STAKRR_TEST_TRANSACTION_FAULT" in
        stderr-overflow)
            # Exceed 64 KiB without acknowledging prepare. Keep stdin open
            # until the client's error cleanup closes it.
            awk 'BEGIN { for (i = 0; i < 65; i++) printf "%1024s", "" }' >&2
            IFS= read -r decision ;;
        closed-stdin)
            # Close the read end before the acknowledgement, guaranteeing
            # that the client's commit write encounters a broken pipe.
            exec 0<&-
            printf 'prepare: ok\n' ;;
    esac
    exit 1
fi
# Replace a direct ref only when the selected Git transaction is about to run.
# This deliberately happens after all checks in the caller, including any
# symbolic-ref preflight immediately before spawning update-ref.
if [ "$update" = true ] && [ -n "${STAKRR_TEST_SYMREF_LABEL:-}" ]; then
    for arg do
        if [ "$arg" = "$STAKRR_TEST_SYMREF_LABEL" ]; then
            "$STAKRR_TEST_GIT" symbolic-ref "$STAKRR_TEST_SYMREF_REF" "$STAKRR_TEST_SYMREF_TARGET" || exit $?
            printf '%s' "$arg" > "$STAKRR_TEST_SYMREF_MARKER" || exit $?
            break
        fi
    done
fi
# Advance a ref after stakrr saved its intent, before Git prepares publication.
if [ "$update" = true ] && [ "$race" = true ]; then
    "$STAKRR_TEST_GIT" update-ref "$STAKRR_TEST_RACE_REF" "$STAKRR_TEST_RACE_NEW" "$STAKRR_TEST_RACE_OLD" || exit $?
fi
# Model a files-backend transaction interrupted between individual ref writes.
# Applying a prefix makes the crash deterministic; the production transaction
# still has to preserve enough intent to finish both writes and deletions.
if [ "$update" = true ] && [ "$partial" = true ]; then
    # The production client waits for prepare before deciding whether to commit.
    # Read only that phase; waiting for EOF here would deadlock the handshake.
    payload=
    while IFS= read -r line; do
        payload="${payload}${line}
"
        [ "$line" != prepare ] || break
    done
    writes=$(printf '%s\n' "$payload" | awk '$1 == "create" || $1 == "update" || $1 == "delete" { n++ } END { print n+0 }')
    if [ "$writes" -gt 1 ] || [ "${STAKRR_TEST_PARTIAL_WRITES:-}" = 0 ]; then
        # Real Git acknowledges preparation before writing any refs at commit.
        printf 'start: ok\nprepare: ok\n'
        IFS= read -r decision || exit 1
        if [ "$decision" = abort ]; then
            printf 'abort: ok\n'
            exit 0
        fi
        [ "$decision" = commit ] || exit 1
        count=0
        while IFS= read -r line; do
            [ "$count" -ne "${STAKRR_TEST_PARTIAL_WRITES:-1}" ] || break
            case "$line" in
                create\ *|update\ *|delete\ *)
                    printf '%s\n' "$line" | "$STAKRR_TEST_GIT" update-ref --no-deref --stdin || exit $?
                    count=$((count + 1)) ;;
            esac
        done <<EOF
$payload
EOF
        [ "${STAKRR_TEST_PARTIAL_EXIT:-}" = 1 ] || kill -KILL "$PPID"
        exit "${STAKRR_TEST_PARTIAL_STATUS:-137}"
    fi
    { printf '%s' "$payload"; cat; } | "$STAKRR_TEST_GIT" "$@"
    exit $?
fi
if [ "$update" != true ]; then archive=false; checkpoint=false; boundary=; fi
# Named boundaries are counted independently, so unrelated checkpoints do not
# change recovery coverage. Tests assert the fired marker as well as SIGKILL.
fault=${STAKRR_TEST_FAULT:-}
if [ "$checkpoint" = true ]; then :
elif [ "$archive" = true ]; then boundary=archive
elif [ "$pick" = true ]; then boundary=pick
else
    previous=
    for arg do
        if [ "$previous" = worktree ]; then
            case "$arg" in add) boundary=workspace-create ;; remove) boundary=workspace-remove ;; unlock) boundary=workspace-unlock ;; esac
        fi
        if [ "$arg" = switch ]; then boundary=checkout; fi
        if [ "$arg" = --detach ] && [ "${boundary:-}" = checkout ]; then boundary=checkout-detach; fi
        previous=$arg
    done
fi
if [ -n "${boundary:-}" ] && [ -n "$fault" ]; then
    count=0
    count_path="$STAKRR_TEST_COUNTER.$boundary"
    [ ! -f "$count_path" ] || read -r count < "$count_path"
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_path"
    if [ "$fault" = "before:$boundary:$count" ]; then
        printf '%s' "$fault" > "$STAKRR_TEST_COUNTER.fired"
        kill -KILL "$PPID"
        exit 1
    fi
fi
"$STAKRR_TEST_GIT" "$@"
result=$?
if [ "$result" = 0 ] && [ -n "${boundary:-}" ] && [ -n "$fault" ] &&
   [ "$fault" = "after:$boundary:$count" ]; then
    printf '%s' "$fault" > "$STAKRR_TEST_COUNTER.fired"
    kill -KILL "$PPID"
fi
exit "$result"
