#!/bin/sh
set -eu

# Release-notes generator.
#
# Categorizes the commit subjects between the previous tag and HEAD into
# sections. A Conventional Commit type that is not explicitly mapped below
# still appears under "Other Changes", so nothing is ever silently dropped.
#
# When adding a new commit type that deserves its own section, add a `section()`
# rule AND an `emit(...)` line in END.

CURRENT_TAG=$(git describe --tags --exact-match HEAD 2>/dev/null || true)
if [ -n "$CURRENT_TAG" ]; then
    LAST_TAG=$(git tag --sort=-creatordate | grep -v "^$CURRENT_TAG$" | head -n 1 || true)
else
    LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
fi

if [ -n "$LAST_TAG" ]; then
    RANGE="$LAST_TAG..HEAD"
else
    RANGE="HEAD"
fi

git log "$RANGE" --no-merges --pretty=format:"%s" | awk '
function section(s,  l) {
    l = tolower(s)
    if (l ~ /^feat(\([^)]*\))?!?:/)     return "features"
    if (l ~ /^perf(\([^)]*\))?!?:/)     return "perf"
    if (l ~ /^fix(\([^)]*\))?!?:/)      return "fixes"
    if (l ~ /^refactor(\([^)]*\))?!?:/) return "refactor"
    if (l ~ /^docs(\([^)]*\))?!?:/)     return "docs"
    return "other"
}
function emit(title, key) {
    if (items[key] != "") {
        print "### " title
        print ""
        printf "%s", items[key]
        print ""
    }
}
function strip(s,  prefix, rest) {
    if (match(s, /^[A-Za-z]+(\([^)]*\))?!?:[ ]*/)) {
        prefix = substr(s, 1, RLENGTH)
        rest = substr(s, RLENGTH + 1)
        if (match(prefix, /\([^)]*\)/))
            return substr(prefix, RSTART + 1, RLENGTH - 2) ": " rest
        return rest
    }
    return s
}
{
    key = section($0)
    items[key] = items[key] "- " strip($0) "\n"
}
END {
    emit("Features", "features")
    emit("Performance Improvements", "perf")
    emit("Bug Fixes", "fixes")
    emit("Refactors", "refactor")
    emit("Documentation", "docs")
    emit("Other Changes", "other")
}'
