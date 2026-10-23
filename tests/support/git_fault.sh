#!/bin/sh
# Test-only Git wrapper. Kill stakrr immediately before/after a chosen ref
# checkpoint, or after a successful pick, to exercise persisted recovery.
checkpoint=false
pick=false
archive=false
update=false
for arg do
    [ "$arg" != update-ref ] || update=true
    [ "$arg" != 'stakrr: edit checkpoint' ] || checkpoint=true
    [ "$arg" != 'cherry-pick' ] || pick=true
    case "$arg" in
        'stakrr: finish edit'|'stakrr: abort edit'|'stakrr: quit edit'|'stakrr: undo edit') archive=true ;;
    esac
done
[ "$update" = true ] || archive=false
fault=${STAKRR_TEST_FAULT:-}
if [ "$checkpoint" = true ] && [ -n "$fault" ]; then
    count=0
    [ ! -f "$STAKRR_TEST_COUNTER" ] || read -r count < "$STAKRR_TEST_COUNTER"
    count=$((count + 1))
    printf '%s\n' "$count" > "$STAKRR_TEST_COUNTER"
    if [ "$fault" = "before:$count" ]; then
        kill -KILL "$PPID"
        exit 1
    fi
fi
if [ "$archive" = true ] && [ "$fault" = before:archive ]; then
    kill -KILL "$PPID"
    exit 1
fi
"$STAKRR_TEST_GIT" "$@"
result=$?
if [ "$result" = 0 ]; then
    if { [ "$checkpoint" = true ] && [ "$fault" = "after:$count" ]; } ||
       { [ "$pick" = true ] && [ "$fault" = pick ]; } ||
       { [ "$archive" = true ] && [ "$fault" = after:archive ]; }; then
        kill -KILL "$PPID"
    fi
fi
exit "$result"
