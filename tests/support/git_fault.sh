#!/bin/sh
# Test-only publication races and transport failures.
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
update=false
for arg do
    [ "$arg" != update-ref ] || update=true
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
exec "$STAKRR_TEST_GIT" "$@"
