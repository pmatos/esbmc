#!/bin/bash
#
# CPython differential smoke check for the Python regression suites.
#
# For each Python regression test whose test.desc asserts a verification
# verdict, run main.py under real CPython and check the exit code agrees with
# what ESBMC is expected to prove:
#
#   VERIFICATION SUCCESSFUL  -> program runs cleanly under CPython (exit 0)
#   VERIFICATION FAILED      -> program raises / exits nonzero under CPython
#
# The expected verdict is read from test.desc (the authoritative source used by
# ctest), NOT from the directory name -- the two disagree for dozens of tests.
#
# A test is excluded from the check when:
#   * a .no-cpython-check marker file is present (the reason lives with the
#     test and is reviewable, instead of a growing array in this script);
#   * main.py uses ESBMC/VERIFIER/nondet intrinsics, undefined under CPython;
#   * the directory name contains 'nondet' (symbolic input, no deterministic
#     CPython verdict);
#   * test.desc is KNOWNBUG/FUTURE (current ESBMC output diverges from the
#     regex by design);
#   * test.desc asserts no VERIFICATION verdict (nothing to cross-check).
#
# Excluded tests are counted per reason and the excluded fraction is reported,
# so shrinking coverage is visible rather than silent.
#
# Usage: check_python_tests.sh [query]
#   With no argument, every test in every suite is considered.
#   With a query, only tests whose directory name contains it (case-insensitive)
#   are considered.

# Run from the repository root regardless of the caller's working directory.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root" || exit 1

# Activate the regression virtual environment if present (build-with-venv.sh).
# CI builds install dependencies globally, so this is optional.
if [ -f "regression/esbmc-venv/bin/activate" ]; then
    # shellcheck disable=SC1091
    source regression/esbmc-venv/bin/activate
fi

# Pick a CPython interpreter. On macOS build.sh installs python@3.12.
if [ -n "${VIRTUAL_ENV:-}" ]; then
    PYTHON_CMD="python"
elif [[ "$OSTYPE" == "darwin"* ]] && command -v python3.12 &>/dev/null; then
    PYTHON_CMD="python3.12"
else
    PYTHON_CMD="python3"
fi

# Optional per-test wall-clock guard so one runaway program cannot hang CI.
# coreutils provides `timeout`; on macOS it is `gtimeout` (brew coreutils).
if command -v timeout &>/dev/null; then
    TIMEOUT_CMD=(timeout 60)
elif command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD=(gtimeout 60)
else
    TIMEOUT_CMD=()
fi

SUITES=(python python-intensive python-coverage)

test_query="$1"

failed_tests=()
matched_tests=0
checked=0
ex_optout=0
ex_intrinsic=0
ex_nondet=0
ex_knownbug=0
ex_noverdict=0

# expected_verdict <test.desc> -> echoes: success | fail | knownbug | none
# Reads the mode (line 1) and the stdout/stderr regexes (line 4+); the verdict
# is whichever VERIFICATION line the test expects ESBMC to print.
expected_verdict() {
    local desc="$1" mode body
    mode="$(head -n1 "$desc" | tr -d '[:space:]')"
    if [ "$mode" = "KNOWNBUG" ] || [ "$mode" = "FUTURE" ]; then
        echo knownbug
        return
    fi
    body="$(tail -n +4 "$desc")"
    if printf '%s\n' "$body" | grep -q 'VERIFICATION SUCCESSFUL'; then
        echo success
    elif printf '%s\n' "$body" | grep -q 'VERIFICATION FAILED'; then
        echo fail
    else
        echo none
    fi
}

for suite in "${SUITES[@]}"; do
    suite_dir="regression/$suite"
    [ -d "$suite_dir" ] || continue

    for dir in "$suite_dir"/*/; do
        dir="${dir%/}"
        name="$(basename "$dir")"

        # A CTest regression test needs both a program and a descriptor.
        [ -f "$dir/main.py" ] || continue
        [ -f "$dir/test.desc" ] || continue

        # Query mode: consider only tests whose name matches (case-insensitive).
        if [ -n "$test_query" ]; then
            echo "$name" | grep -qiF -- "$test_query" || continue
            matched_tests=$((matched_tests + 1))
        fi

        # Opt-out marker: exclusion reason lives with the test.
        if [ -f "$dir/.no-cpython-check" ]; then
            ex_optout=$((ex_optout + 1))
            continue
        fi

        # ESBMC intrinsics (__ESBMC_*, __VERIFIER_*, nondet_*) are not defined
        # in CPython; the program would raise NameError. Detecting them by
        # content means such tests never need a manual opt-out entry.
        if grep -qE '__ESBMC|__VERIFIER_|nondet_' "$dir/main.py"; then
            ex_intrinsic=$((ex_intrinsic + 1))
            continue
        fi

        # nondet-named tests model symbolic input (e.g. via random); CPython
        # picks concrete values, so there is no deterministic verdict to match.
        if echo "$name" | grep -qi 'nondet'; then
            ex_nondet=$((ex_nondet + 1))
            continue
        fi

        case "$(expected_verdict "$dir/test.desc")" in
            knownbug)
                ex_knownbug=$((ex_knownbug + 1))
                continue
                ;;
            none)
                ex_noverdict=$((ex_noverdict + 1))
                continue
                ;;
            fail)
                expected=fail
                ;;
            *)
                expected=success
                ;;
        esac

        checked=$((checked + 1))
        (cd "$dir" && "${TIMEOUT_CMD[@]}" "$PYTHON_CMD" main.py >/dev/null 2>&1)
        result=$?

        if [ "$expected" = "fail" ]; then
            if [ $result -eq 0 ]; then
                echo "❌ $suite/$name: test.desc expects VERIFICATION FAILED, but CPython exited 0"
                failed_tests+=("$suite/$name")
            else
                echo "✅ $suite/$name: failed as expected (exit $result)"
            fi
        else
            if [ $result -eq 0 ]; then
                echo "✅ $suite/$name: executed successfully (exit 0)"
            else
                echo "❌ $suite/$name: test.desc expects VERIFICATION SUCCESSFUL, but CPython exited $result"
                failed_tests+=("$suite/$name")
            fi
        fi
    done
done

total_excluded=$((ex_optout + ex_intrinsic + ex_nondet + ex_knownbug + ex_noverdict))
considered=$((checked + total_excluded))

echo ""
echo "CPython differential gate summary"
echo "  suites:   ${SUITES[*]}"
echo "  checked:  $checked"
echo "  excluded: $total_excluded (opt-out=$ex_optout intrinsics=$ex_intrinsic nondet=$ex_nondet knownbug/future=$ex_knownbug no-verdict=$ex_noverdict)"
if [ "$considered" -gt 0 ]; then
    echo "  excluded fraction: $((total_excluded * 100 / considered))% of $considered tests with main.py+test.desc"
fi

if [ -n "$test_query" ] && [ $matched_tests -eq 0 ]; then
    echo "❌ No tests matched query: $test_query"
    exit 1
fi

if [ -n "$test_query" ] && [ $matched_tests -gt 0 ] && [ $checked -eq 0 ]; then
    echo "⚠️ Query matched tests, but all matches were excluded from the CPython check."
    exit 0
fi

if [ ${#failed_tests[@]} -eq 0 ]; then
    echo "✅ All checked tests matched their test.desc verdict under CPython."
    exit 0
else
    echo "❌ ${#failed_tests[@]} test(s) disagreed with CPython:"
    for test in "${failed_tests[@]}"; do
        echo " - $test"
    done
    exit 1
fi
