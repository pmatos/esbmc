#!/usr/bin/env bash
#
# Enforce ESBMC's "one passing + one failing regression test per PR" convention
# (AGENTS.md) for changes to the Python frontend and its C operational models.
#
# When a pull request modifies files under either of:
#   - src/python-frontend/
#   - src/c2goto/library/python/
# it must also add at least one new PASSING and one new FAILING regression test
# under regression/python/. That is the behavioural coverage the two-test
# convention asks for; with no CI check it degrades silently whenever author or
# reviewer discipline lapses.
#
# Conventions used to classify the diff:
#   - A new test is a newly-added `regression/python/<name>/test.desc`.
#   - A FAILING test directory name ends in `_fail` or `-fail`; any other new
#     test directory counts as passing.
#
# Escape hatch: the workflow skips this check when the PR carries the
# `skip-test-check` label (docs-only or pure-refactor PRs that need no test).
#
# Usage:
#   scripts/ci/check-python-test-pair.sh [BASE_REF]
# BASE_REF defaults to $BASE_REF in the environment, then to origin/master.
#
# Testability: export CHANGED_FILES and/or ADDED_FILES (newline-separated
# paths) to drive the classification logic directly without touching git.

set -euo pipefail

BASE_REF="${1:-${BASE_REF:-origin/master}}"

# A path whose modification makes the two-test requirement apply.
is_frontend_path() {
  case "$1" in
  src/python-frontend/* | src/c2goto/library/python/*) return 0 ;;
  *) return 1 ;;
  esac
}

# CHANGED_FILES / ADDED_FILES override git so the logic is unit-testable.
# The `+x` test treats an explicitly-empty override as "no files" (not "unset").
if [ -n "${CHANGED_FILES+x}" ]; then
  changed="$CHANGED_FILES"
else
  changed="$(git diff --name-only "$BASE_REF...HEAD")"
fi

if [ -n "${ADDED_FILES+x}" ]; then
  added="$ADDED_FILES"
else
  added="$(git diff --name-only --diff-filter=A "$BASE_REF...HEAD")"
fi

touches_frontend=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if is_frontend_path "$f"; then
    touches_frontend=1
    break
  fi
done <<EOF
$changed
EOF

if [ "$touches_frontend" -eq 0 ]; then
  echo "No changes under src/python-frontend/ or src/c2goto/library/python/;" \
    "two-test check not applicable."
  exit 0
fi

pass_count=0
fail_count=0
new_pass=""
new_fail=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
  regression/python/*/test.desc) ;;
  *) continue ;;
  esac
  dir="$(basename "$(dirname "$f")")"
  case "$dir" in
  *_fail | *-fail)
    fail_count=$((fail_count + 1))
    new_fail="$new_fail $dir"
    ;;
  *)
    pass_count=$((pass_count + 1))
    new_pass="$new_pass $dir"
    ;;
  esac
done <<EOF
$added
EOF

echo "New passing regression/python tests:${new_pass:- (none)}"
echo "New failing regression/python tests:${new_fail:- (none)}"

if [ "$pass_count" -ge 1 ] && [ "$fail_count" -ge 1 ]; then
  echo "OK: PR adds >=1 passing and >=1 failing Python regression test."
  exit 0
fi

echo "::error::PR modifies the Python frontend / operational models but does" \
  "not add the required passing+failing regression test pair."
cat >&2 <<'EOF'

ESBMC requires every PR touching src/python-frontend/ or
src/c2goto/library/python/ to add at least one new PASSING and one new FAILING
regression test under regression/python/ (AGENTS.md: "one passing + one failing
regression test per PR").

  - A new test is a newly-added regression/python/<name>/test.desc.
  - A FAILING test directory name ends in `_fail` or `-fail`.

Add the missing test(s), or apply the `skip-test-check` label to this PR if it
genuinely needs none (e.g. docs-only or pure refactor).
EOF
exit 1
