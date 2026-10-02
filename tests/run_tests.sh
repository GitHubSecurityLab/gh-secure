#!/usr/bin/env bash
#
# Tests for gh-secure.
#
# The suite never touches the network and needs no token: every `gh api` call is served by a
# stub on PATH that applies the caller's --jq with real jq before answering, so code under
# test sees exactly what GitHub would have returned. An earlier version of this file ignored
# --jq, which meant it never exercised the filtering logic it claimed to cover.
#
# Requires: bash, jq.   Run: ./tests/run_tests.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/gh-secure"

PASS=0
FAIL=0

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

pass() { PASS=$((PASS + 1)); printf "  ${GREEN}ok${NC}   %s\n" "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf "  ${RED}FAIL${NC} %s\n" "$1"
  [ -n "${2:-}" ] && printf "       %s\n" "$2"
  return 0
}

if ! command -v jq >/dev/null 2>&1; then
  echo "${YELLOW}jq is required. Install it with: apt-get install jq / brew install jq / winget install jqlang.jq${NC}"
  exit 1
fi

# ─── Stub ──────────────────────────────────────────────────────────────────────

STUB_DIR=""
CALL_LOG=""

setup_stub() {
  STUB_DIR="$(mktemp -d)"
  CALL_LOG="$STUB_DIR/calls.log"
  : > "$CALL_LOG"
  # The stub runs as a separate process, so it needs the path in its environment.
  export CALL_LOG

  # Honours --jq the way gh does, so filtering under test is actually exercised.
  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"

jq_filter=""
endpoint=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jq_filter="$2"; shift 2 ;;
    --jq=*) jq_filter="${1#--jq=}"; shift ;;
    *) if [ -z "$endpoint" ]; then endpoint="$1"; fi; shift ;;
  esac
done

if [ -n "${GH_STUB_FAIL:-}" ]; then
  echo "$GH_STUB_FAIL" >&2
  exit 1
fi

body="${GH_STUB_BODY:-}"
if [ -n "${GH_STUB_BODY_FILE:-}" ] && [ -f "$GH_STUB_BODY_FILE" ]; then
  body="$(cat "$GH_STUB_BODY_FILE")"
fi

if [ -n "$jq_filter" ]; then
  printf '%s' "$body" | jq -r "$jq_filter"
else
  printf '%s' "$body"
fi
STUB
  chmod +x "$STUB_DIR/gh"
  PATH="$STUB_DIR:$PATH"
  export PATH
}

teardown_stub() {
  [ -n "$STUB_DIR" ] && rm -rf "$STUB_DIR"
  STUB_DIR=""
}

# Count how many logged calls contain a substring. `grep -c` exits 1 on no match while
# still printing 0, so a `|| echo 0` fallback would append a second 0 and break any
# equality comparison. `wc -l` after a plain grep has neither problem.
count_calls() {
  grep -- "$1" "$CALL_LOG" 2>/dev/null | wc -l | tr -d ' '
}

# Pull one function out of the script so it can be tested without running main().
load_function() {
  local name="$1"
  eval "$(awk -v fn="$name" '
    $0 ~ "^"fn"\\(\\) \\{" { capture = 1 }
    capture { print }
    capture && $0 ~ "^\\}" { exit }
  ' "$SCRIPT_UNDER_TEST")"
}

# Stub output printers so output under test stays readable.
print_success() { printf '    success: %s\n' "$*"; }
print_info()    { printf '    info:    %s\n' "$*"; }
print_warning() { printf '    warning: %s\n' "$*"; }
print_error()   { printf '    error:   %s\n' "$*"; }
print_skip()    { printf '    skip:    %s\n' "$*"; }

# Used by check_rulesets, which is loaded into this shell by load_function. shellcheck only
# sees the assignment here, not the use inside the extracted function body.
# shellcheck disable=SC2034
OWNER="acme"
# shellcheck disable=SC2034
REPO_NAME="widget"

echo "gh-secure test suite"
echo

# ─── api_write ─────────────────────────────────────────────────────────────────

echo "api_write"
setup_stub
load_function api_write

GH_STUB_BODY='{"ok":true}' api_write "repos/acme/widget/branches/main/protection" --method PUT
T="api_write: returns success on a 2xx"
if [ $? -eq 0 ]; then pass "$T"; else fail "$T"; fi

T="api_write: makes exactly one request per call"
if [ "$(count_calls 'branches/main/protection')" = "1" ]; then
  pass "$T"
else
  fail "$T" "expected 1, got $(count_calls 'branches/main/protection')"
fi

T="api_write: leaves API_WRITE_ERROR empty on success"
if [ -z "$API_WRITE_ERROR" ]; then pass "$T"; else fail "$T" "got [$API_WRITE_ERROR]"; fi

# The bug that made the first attempt at this helper unusable: an uninitialized variable
# redirected stderr to a filename that was the empty string, and the call died with
# "No such file or directory" instead of reporting the API error.
T="api_write: captures the API error on failure"
if GH_STUB_FAIL="gh: Resource not accessible by integration (HTTP 403)" \
   api_write "repos/acme/widget/rulesets" --method PUT; then
  fail "$T" "returned success while the stub failed"
elif printf '%s' "$API_WRITE_ERROR" | grep -q "403"; then
  pass "$T"
else
  fail "$T" "API_WRITE_ERROR=[$API_WRITE_ERROR]"
fi

T="api_write: keeps the error across the whole call"
if printf '%s' "$API_WRITE_ERROR" | grep -q "Resource not accessible"; then
  pass "$T"
else
  fail "$T" "the reason GitHub gave did not survive"
fi

# A payload passed as @file must reach gh as --input, and API_WRITE_ERROR must survive.
# Piping into the function instead would run it in a subshell and lose the assignment,
# which is exactly what the earlier implementation got wrong.
T="api_write: accepts a @file payload without a pipeline"
payload="$STUB_DIR/payload.json"
printf '{"state":"configured"}' > "$payload"
if GH_STUB_FAIL="HTTP 404 Not Found" api_write "repos/acme/widget/code-scanning/default-setup" --method PATCH "@$payload"; then
  fail "$T" "returned success while the stub failed"
elif printf '%s' "$API_WRITE_ERROR" | grep -q "404"; then
  pass "$T"
else
  fail "$T" "API_WRITE_ERROR=[$API_WRITE_ERROR] — the error was lost"
fi

T="api_write: passes the payload file to gh as --input"
if grep -q -- "--input $payload" "$CALL_LOG"; then
  pass "$T"
else
  fail "$T" "gh was not called with --input $(basename "$payload")"
fi

teardown_stub
echo

# ─── print_api_error ───────────────────────────────────────────────────────────

echo "print_api_error"
setup_stub
load_function print_api_error

# Called with no argument at every call site, so it has to read API_WRITE_ERROR itself.
# The earlier version tested $API_WRITE_ERROR but printed $1, so it printed nothing.
T="print_api_error: prints API_WRITE_ERROR when called with no argument"
API_WRITE_ERROR="gh: Missing required parameter (HTTP 422)"
out="$(print_api_error)"
if printf '%s' "$out" | grep -q "Missing required parameter"; then
  pass "$T"
else
  fail "$T" "output was [$out]"
fi

T="print_api_error: accepts an explicit message"
out="$(print_api_error "explicit reason")"
if printf '%s' "$out" | grep -q "explicit reason"; then
  pass "$T"
else
  fail "$T" "output was [$out]"
fi

T="print_api_error: prints nothing when there is no error"
API_WRITE_ERROR=""
out="$(print_api_error)"
if [ -z "$out" ]; then pass "$T"; else fail "$T" "output was [$out]"; fi

T="print_api_error: returns 0 with no error (safe under set -e)"
API_WRITE_ERROR=""
if print_api_error >/dev/null; then pass "$T"; else fail "$T" "returned non-zero"; fi

teardown_stub
echo

# ─── check_rulesets ────────────────────────────────────────────────────────────
#
# Regression coverage for the parsing that this branch deliberately does NOT change.
# The original --jq filter and head -n1/tail -n1 split are exercised against a stub that
# honours --jq, so if a future change breaks that parsing the suite notices. An earlier
# version of this PR claimed a critical bug here that turned out not to exist.

echo "check_rulesets"
setup_stub
load_function check_rulesets

rulesets='[{"name":"protect-main","enforcement":"active"},{"name":"block-force-push","enforcement":"active"},{"name":"retired","enforcement":"disabled"}]'
body_file="$STUB_DIR/rulesets.json"
printf '%s' "$rulesets" > "$body_file"
export GH_STUB_BODY_FILE="$body_file"

T="check_rulesets: detects active rulesets"
if check_rulesets; then pass "$T"; else fail "$T" "returned false with 2 active rulesets"; fi

T="check_rulesets: counts only the active ones"
if [ "$ACTIVE_RULESETS_COUNT" = "2" ]; then
  pass "$T"
else
  fail "$T" "expected 2, got [$ACTIVE_RULESETS_COUNT]"
fi

T="check_rulesets: reports the active ruleset names"
if [ "$ACTIVE_RULESETS_NAMES" = "protect-main, block-force-push" ]; then
  pass "$T"
else
  fail "$T" "expected 'protect-main, block-force-push', got [$ACTIVE_RULESETS_NAMES]"
fi

unset GH_STUB_BODY_FILE
printf '%s' '[{"name":"retired","enforcement":"disabled"}]' > "$body_file"
export GH_STUB_BODY_FILE="$body_file"

T="check_rulesets: ignores disabled rulesets"
if check_rulesets; then
  fail "$T" "returned true for a repo whose only ruleset is disabled"
else
  pass "$T"
fi

printf '%s' '[]' > "$body_file"
T="check_rulesets: reports none for an empty list"
if check_rulesets; then
  fail "$T" "returned true for an empty ruleset list"
else
  pass "$T"
fi

printf '%s' '[{"name":"only","enforcement":"active"}]' > "$body_file"
T="check_rulesets: handles a single ruleset"
if check_rulesets && [ "$ACTIVE_RULESETS_COUNT" = "1" ] && [ "$ACTIVE_RULESETS_NAMES" = "only" ]; then
  pass "$T"
else
  fail "$T" "count=[$ACTIVE_RULESETS_COUNT] names=[$ACTIVE_RULESETS_NAMES]"
fi

T="check_rulesets: the ruleset conflict prompt is still unconditional"
# This prompt deliberately ignores --yes. It is the only place where automation is
# overruled, and it must not be quietly removed by a refactor of the checks above.
if awk '/^enable_branch_protection\(\) \{/,/^\}/' "$SCRIPT_UNDER_TEST" \
     | grep -q 'Active rulesets detected. Still enable branch protection?'; then
  pass "$T"
else
  fail "$T" "the unconditional ruleset prompt is gone"
fi

unset GH_STUB_BODY_FILE
teardown_stub
echo

# ─── Structural guards ─────────────────────────────────────────────────────────

echo "structure"
setup_stub

T="no mutating call bypasses api_write"
raw="$(grep -cE 'gh api .*--method (PUT|PATCH|POST|DELETE)' "$SCRIPT_UNDER_TEST" 2>/dev/null | head -n1 | tr -d ' ')"
if [ "${raw:-0}" = "0" ]; then
  pass "$T"
else
  fail "$T" "$raw raw mutating call(s) remain"
fi

T="no write discards the API's error output"
if grep -E -- '--method (PUT|PATCH|POST|DELETE)' "$SCRIPT_UNDER_TEST" | grep -q '/dev/null 2>&1'; then
  fail "$T" "a write still redirects stderr to /dev/null"
else
  pass "$T"
fi

T="no payload is piped into api_write (subshell loses API_WRITE_ERROR)"
if grep -E '\| *(api_write|gh api)' "$SCRIPT_UNDER_TEST" | grep -q -- '--input -'; then
  fail "$T" "a payload still travels through a pipe into an API call"
else
  pass "$T"
fi

T="the duplicated PUT in enable_vulnerability_reporting is gone"
# Matches code only: the word status_code survives in a comment explaining the old bug,
# so a bare grep reports a false failure. Excluding comment lines keeps the check honest.
if awk '/^enable_vulnerability_reporting\(\) \{/,/^\}/' "$SCRIPT_UNDER_TEST" \
     | grep -vE '^\s*#' | grep -q 'status_code'; then
  fail "$T" "status_code is back, which means the PUT runs twice"
else
  pass "$T"
fi

T="the dry-run message no longer implies a validated write"
if grep -q 'Not validated: the PUT is skipped' "$SCRIPT_UNDER_TEST"; then
  pass "$T"
else
  fail "$T" "the dry-run message does not say it validated nothing"
fi

teardown_stub

# ─── Summary ───────────────────────────────────────────────────────────────────

echo
printf "passed: %d  failed: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]