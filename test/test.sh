#!/usr/bin/env bash

set -euo pipefail
cd "${BASH_SOURCE%/*}"
. ../src/yugabyte-bash-common.sh

declare -i num_assertions_succeeded=0
declare -i num_assertions_failed=0

declare -i num_assertions_succeeded_in_current_test=0
declare -i num_assertions_failed_in_current_test=0

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
    let num_assertions_succeeded_in_current_test+=1
  else
    echo "Assertion failed: expected '$expected', got '$actual'" >&2
    let num_assertions_failed+=1
    let num_assertions_failed_in_current_test+=1
  fi
}

yb_test_logging() {
  assert_equals "$( log "Foo bar" 2>&1 | sed 's/.*\] //g' )" "Foo bar"
}

yb_test_sed_i() {
  local file_path=/tmp/sed_i_test.txt
  cat >"$file_path" <<EOT
Hello world hello world
Hello world hello world
EOT
  sed_i 's/lo wo/lo database wo/g' "$file_path"
  local expected_result
  expected_result=\
'Hello database world hello database world
Hello database world hello database world'
  assert_equals "$expected_result" "$( <"$file_path" )"
}

# -------------------------------------------------------------------------------------------------
# Main test runner code

global_exit_code=0
test_fn_names=$(
  declare -F | sed 's/^declare -f //g' | grep '^yb_test_' 
)

for fn_name in $test_fn_names; do
  num_assertions_succeeded_in_current_test=0
  num_assertions_failed_in_current_test=0
  fn_status="[   OK   ]"
  if ! "$fn_name" || [[ $num_assertions_failed_in_current_test -gt 0 ]]; then
    fn_status="[ FAILED ]"
    global_exit_code=1
  fi
  echo -e "$fn_status Function: $fn_name \t" \
          "Assertions succeeded: $num_assertions_succeeded_in_current_test," \
          "failed: $num_assertions_failed_in_current_test"
done

echo >&2 "Total assertions succeeded: $num_assertions_succeeded, failed: $num_assertions_failed"
if [[ $global_exit_code -eq 0 ]]; then
  echo "Tests SUCCEEDED"
else
  echo "Tests FAILED"
fi
exit "$global_exit_code"
