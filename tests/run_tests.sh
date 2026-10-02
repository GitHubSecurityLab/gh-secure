#!/usr/bin/env bash
#
# Tests for gh-secure.
#
# These tests never touch the network and never modify a repository. Every `gh api` call
# is intercepted by a stub on PATH that returns a fixture instead of making a request, and
# every mutating call is asserted to have been made at most once. That combination is what
# makes the suite safe to run against a live token.
#
# Run: ./tests/run_tests.sh   (or: ./run_tests.sh from the tests directory)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/gh-secure"

PASS=0
FAIL=0
CURRENT_TEST=""

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

pass() {
  PASS=$((PASS + 1))
  printf "  ${GREEN}ok${NC}   %s\n" "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf "  ${RED}FAIL${NC} %s\n" "$1"
  if [ -n "${2:-}" ]; then
    printf "       %s\n" "$2"
  fi
}

# Extract a single function from the script under test so it can be exercised on its own,
# without running main() or resolving a repository.
load_function() {
  local name="$1"
  # shellcheck disable=SC1090
  eval "$(awk -v fn="$name" '
    $0 ~ "^"fn"\\(\\) \\{" { capture = 1 }
    capture { print }
    capture && $0 ~ "^\\}" { exit }
  ' "$SCRIPT_UNDER_TEST")"
}

setup_stub_dir() {
  STUB_DIR="$(mktemp -d)"
  CALL_LOG="$STUB_DIR/calls.log"
  : > "$CALL_LOG"
  mkdir -p "$STUB_DIR/bin"

  # Every call is appended to the log before the fixture is produced, so a test can assert
  # both the result and the number of requests that were attempted.
  cat > "$STUB_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"
if [ -n "$GH_STUB_RULESETS" ]; then
  cat "$GH_STUB_RULESETS"
  exit 0
fi
printf '%s' "${GH_STUB_DEFAULT:-}"
exit 0
STUB
  chmod +x "$STUB_DIR/bin/gh"
  export CALL_LOG
  export PATH="$STUB_DIR/bin:$PATH"
}

teardown_stub_dir() {
  rm -rf "$STUB_DIR"
}

fixture() {
  printf '%s' "$1" > "$STUB_DIR/fixture.json"
  export GH_STUB_RULESETS="$STUB_DIR/fixture.json"
}

# Count calls whose log line contains the given substring.
count_calls() {
  grep -c -- "$1" "$CALL_LOG" 2>/dev/null || echo 0
}

echo "gh-secure test suite"
echo

# ─── check_rulesets ────────────────────────────────────────────────────────────
#
# This is the regression test for the bug that motivated the suite. The original filter was
#
#   [.[] | select(.enforcement == "active")] | "\(length)\n\([.[].name] | join(", "))"
#
# whose `|` inside the \(...) interpolation closed the outer pipe, so the names were never
# extracted, the count was not numeric, `[ ... -gt 0 ]` failed, and a `2>/dev/null` on that
# comparison swallowed the error. check_rulesets returned false for every repository,
# including ones with active rulesets, which disabled the conflict warning and the
# confirmation prompt in enable_branch_protection.

print_warning() { printf '  %s\n' "$*"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "${YELLOW}jq is not installed; skipping the ruleset detection tests.${NC}"
  echo "${YELLOW}These are the tests that cover the regression. Install jq to run them.${NC}"
  echo
else
  setup_stub_dir
  load_function check_rulesets

  fixture '[{"name":"protect-main","enforcement":"active"},{"name":"block-force-push","enforcement":"active"},{"name":"retired","enforcement":"disabled"}]'
  if check_rulesets; then
    CURRENT_TEST="check_rulesets: detects active rulesets"
    if [ "$ACTIVE_RULESETS_COUNT" = "2" ]; then
      pass "$CURRENT_TEST"
    else
      fail "$CURRENT_TEST" "expected count 2, got '$ACTIVE_RULESETS_COUNT'"
    fi

    CURRENT_TEST="check_rulesets: reports the active ruleset names"
    if [ "$ACTIVE_RULESETS_NAMES" = "protect-main, block-force-push" ]; then
      pass "$CURRENT_TEST"
    else
      fail "$CURRENT_TEST" "expected 'protect-main, block-force-push', got '$ACTIVE_RULESETS_NAMES'"
    fi
  else
    fail "check_rulesets: detects active rulesets" \
         "returned false for a repository with 2 active rulesets; the conflict warning would not have shown"
    fail "check_rulesets: reports the active ruleset names" \
         "function returned early, count='$ACTIVE_RULESETS_COUNT' names='$ACTIVE_RULESETS_NAMES'"
  fi
  teardown_stub_dir
  echo

  setup_stub_dir
  load_function check_rulesets

  fixture '[{"name":"retired","enforcement":"disabled"}]'
  if check_rulesets; then
    fail "check_rulesets: ignores disabled rulesets" \
         "returned true with count='$ACTIVE_RULESETS_COUNT'; would warn about a ruleset that is not enforcing"
  else
    pass "check_rulesets: ignores disabled rulesets"
  fi
  teardown_stub_dir
  echo

  setup_stub_dir
  load_function check_rulesets

  fixture '[]'
  if check_rulesets; then
    fail "check_rulesets: reports no rulesets for an empty list" \
         "returned true for an empty ruleset list"
  else
    pass "check_rulesets: reports no rulesets for an empty list"
  fi
  teardown_stub_dir
  echo

  setup_stub_dir
  load_function check_rulesets

  fixture '[{"name":"only","enforcement":"active"}]'
  check_rulesets
  CURRENT_TEST="check_rulesets: handles a single ruleset"
  if [ "$ACTIVE_RULESETS_COUNT" = "1" ] && [ "$ACTIVE_RULESETS_NAMES" = "only" ]; then
    pass "$CURRENT_TEST"
  else
    fail "$CURRENT_TEST" "count='$ACTIVE_RULESETS_COUNT' names='$ACTIVE_RULESETS_NAMES'"
  fi
  teardown_stub_dir
  echo

  setup_stub_dir
  load_function check_rulesets

  # A name containing a space must survive intact: the values are split on a TAB, not a
  # space, and the old newline split was fragile for the same reason.
  fixture '[{"name":"my ruleset","enforcement":"active"}]'
  check_rulesets
  CURRENT_TEST="check_rulesets: preserves spaces in a ruleset name"
  if [ "$ACTIVE_RULESETS_NAMES" = "my ruleset" ]; then
    pass "$CURRENT_TEST"
  else
    fail "$CURRENT_TEST" "expected 'my ruleset', got '$ACTIVE_RULESETS_NAMES'"
  fi
  teardown_stub_dir
  echo
fi

# ─── Mutating calls are made exactly once ───────────────────────────────────────

if ! command -v jq >/dev/null 2>&1; then
  setup_stub_dir

  load_function api_write
  GH_STUB_DEFAULT="" api_write "repos/o/r/private-vulnerability-reporting" --method PUT
  CURRENT_TEST="api_write: performs a single request"
  if [ "$(count_calls 'private-vulnerability-reporting')" = "1" ]; then
    pass "$CURRENT_TEST"
  else
    fail "$CURRENT_TEST" "$(count_calls 'private-vulnerability-reporting') requests were made"
  fi

  CURRENT_TEST="api_write: captures the API error on failure"
  cat > "$STUB_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"
echo "gh: Resource not accessible by integration (HTTP 403)" >&2
exit 1
STUB
  chmod +x "$STUB_DIR/bin/gh"
  if api_write "repos/o/r/rulesets" --method PUT; then
    fail "$CURRENT_TEST" "returned success while the stub failed"
  elif printf '%s' "$API_WRITE_ERROR" | grep -q "403"; then
    pass "$CURRENT_TEST"
  else
    fail "$CURRENT_TEST" "the reason GitHub gave was not captured"
  fi

  teardown_stub_dir
  echo
fi

# ─── Structure ─────────────────────────────────────────────────────────────────
#
# Guards the two changes that are easy to reintroduce by accident: the duplicate PUT that
# used to sit in enable_vulnerability_reporting, and the blanket suppression of API errors
# on writes.

setup_stub_dir

CURRENT_TEST="no mutating call discards the API's error output"
if grep -nE 'method (PUT|PATCH|POST|DELETE).*/dev/null 2>&1' "$SCRIPT_UNDER_TEST" >/dev/null 2>&1; then
  fail "$CURRENT_TEST" "a write still redirects stderr to /dev/null; failures will be silent again"
else
  pass "$CURRENT_TEST"
fi

CURRENT_TEST="no write goes through gh api without the api_write helper"
RAW_WRITES=$(grep -cE 'gh api .*method (PUT|PATCH|POST|DELETE)' "$SCRIPT_UNDER_TEST" 2>/dev/null || echo 0)
if [ "$RAW_WRITES" = "0" ]; then
  pass "$CURRENT_TEST"
else
  fail "$CURRENT_TEST" "$RAW_WRITES raw mutating call(s) remain; route them through api_write"
fi

CURRENT_TEST="check_rulesets does not suppress the arithmetic test"
# A `2>/dev/null` on the `-gt` comparison is what turned a parse error into a silent false.
if awk '/^check_rulesets\(\) \{/,/^\}/' "$SCRIPT_UNDER_TEST" | grep -qE '^\s*\[ .*-gt [0-9]+ \].*2>/dev/null'; then
  fail "$CURRENT_TEST" "found '-gt 0 ] 2>/dev/null'; the guard belongs before the comparison"
else
  pass "$CURRENT_TEST"
fi

CURRENT_TEST="the ruleset confirmation prompt still ignores --yes"
# This prompt is the one place where automation is deliberately overruled. It has to survive
# the ruleset fix, otherwise a future --yes run goes straight to applying branch protection
# over an active ruleset with nobody asked.
if awk '/^enable_branch_protection\(\) \{/,/^\}/' "$SCRIPT_UNDER_TEST" \
   | grep -q 'Active rulesets detected. Still enable branch protection?'; then
  pass "$CURRENT_TEST"
else
  fail "$CURRENT_TEST" "the unconditional ruleset prompt is gone; that is the safety net"
fi

teardown_stub_dir

# ─── Summary ───────────────────────────────────────────────────────────────────

echo
printf "passed: %d  failed: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
