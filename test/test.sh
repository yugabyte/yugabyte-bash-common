#!/usr/bin/env bash

set -euo pipefail
cd "${BASH_SOURCE%/*}"
. ../src/yugabyte-bash-common.sh

declare -i num_assertions_succeeded=0
declare -i num_assertions_failed=0

assert_equals() {
  # Not using "expect_num_args", "log", "fatal", etc. in these assertion functions, because
  # those functions themselves need to be tested.
  if [[ $# -ne 2 ]]; then
    echo "assert_equals expects two arguments, got $#: $*" >&2
    exit 1
  fi
  local expected=$1
  local actual=$2
  if [[ $expected == $actual ]]; then
    let num_assertions_succeeded+=1
  else
    echo "Assertion failed: expected '$expected', got '$actual'" >&2
    let num_assertions_failed+=1
  fi
}

assert_equals "$( log "Foo bar" 2>&1 | sed 's/.*\] //g' )" "Foo bar"

echo "Assertions succeeded: $num_assertions_succeeded, failed: $num_assertions_failed"
if [[ $num_assertions_failed -gt 0 ]]; then
  echo "Tests FAILED"
  exit 1
fi
echo "Tests SUCCEEDED"
