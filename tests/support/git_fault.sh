#!/bin/sh
# Test-only Git wrapper. Kill stakrr immediately before/after a chosen ref
# checkpoint, or after a successful pick, to exercise persisted recovery.
checkpoint=false
pick=false
for arg do
    [ "$arg" != 'stakrr: edit checkpoint' ] || checkpoint=true
    [ "$arg" != 'cherry-pick' ] || pick=true
done
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
"$STAKRR_TEST_GIT" "$@"
result=$?
if [ "$result" = 0 ]; then
    if { [ "$checkpoint" = true ] && [ "$fault" = "after:$count" ]; } ||
       { [ "$pick" = true ] && [ "$fault" = pick ]; }; then
        kill -KILL "$PPID"
    fi
fi
exit "$result"
