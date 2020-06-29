#!/usr/bin/env bash

set -euo pipefail
cd "${BASH_SOURCE%/*}"
# shellcheck source=src/yugabyte-bash-common.sh
. "../src/yugabyte-bash-common.sh"

declare -i num_assertions_succeeded=0
declare -i num_assertions_failed=0

declare -i num_assertions_succeeded_in_current_test=0
declare -i num_assertions_failed_in_current_test=0

cleanup() {
  local exit_code=$?
  if [[ -d $TEST_TMPDIR && $TEST_TMPDIR == /tmp/* ]]; then
    ( set -x; rm -rf "$TEST_TMPDIR" )
  fi
  exit "$exit_code"
}

increment_successful_assertions() {
  (( num_assertions_succeeded+=1 ))
  (( num_assertions_succeeded_in_current_test+=1 ))
}

increment_failed_assertions() {
  (( num_assertions_failed+=1 ))
  (( num_assertions_failed_in_current_test+=1 ))
}

# -------------------------------------------------------------------------------------------------
# assert_... functions
# -------------------------------------------------------------------------------------------------

assert_equals() {
  # Not using "expect_num_args", "log", "fatal", etc. in these assertion functions, because
  # those functions themselves need to be tested.
  if [[ $# -ne 2 ]]; then
    echo "assert_equals expects two arguments, got $#: $*" >&2
    exit 1
  fi
  local expected=$1
  local actual=$2
  if [[ $expected == "$actual" ]]; then
    increment_successful_assertions
  else
    echo "Assertion failed: expected '$expected', got '$actual'" >&2
    increment_failed_assertions
  fi
}

assert_matches_regex() {
  if [[ $# -ne 2 ]]; then
    echo "assert_matches_regex expects two arguments, got $#: $*" >&2
    exit 1
  fi
  local expected_pattern=$1
  local actual=$2
  if [[ $actual =~ $expected_pattern ]]; then
    increment_successful_assertions
  else
    echo "Assertion failed: expected '$actual' to match pattern '$expected_pattern'" >&2
    increment_failed_assertions
  fi
}


assert_failure() {
  if "$@"; then
    log "Command succeeded -- NOT EXPECTED: $*"
    increment_failed_assertions
  else
    log "Command failed as expected: $*"
    increment_successful_assertions
  fi
}

assert_incorrect_num_args() {
  local result
  set +e
  result=$( expect_num_args "$@" 2>&1 )
  set -e
  if [[ $result =~ expects\ .*\ arguments,\ got ]]; then
    increment_successful_assertions
  else
    log "Unexpected output from expect_num_args $*: $result"
    increment_failed_assertions
  fi
}

assert_egrep() {
  if grep -Eq "$@"; then
    increment_successful_assertions
  else
    log "grep -Eq $* failed"
    increment_failed_assertions
  fi
}

assert_egrep_no_results() {
  if grep -Eq "$@"; then
    log "grep -Eq $* found results:"
    grep -E "$@" >&2
    increment_failed_assertions
  else
    increment_successful_assertions
  fi
}

# -------------------------------------------------------------------------------------------------
# Test cases
# -------------------------------------------------------------------------------------------------

yb_test_logging() {
  assert_equals "$( log "Foo bar" 2>&1 | sed 's/.*\] //g' )" "Foo bar"
}

yb_test_sed_i() {
  local file_path=$TEST_TMPDIR/sed_i_test.txt
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

yb_test_sha256sum() {
  local file_path=$TEST_TMPDIR/myfile.txt
  echo "Data data data" >"$file_path"
  local computed_sha256sum
  compute_sha256sum "$file_path"
  local expected_sha256sum=cda1ee400a07d94301112707836aafaaa1760359e3cb80c9754299b82586d4ec
  assert_equals "$expected_sha256sum" "$computed_sha256sum"
  local checksum_file_path=$file_path.sha256
  echo "$expected_sha256sum" >"$checksum_file_path"
  verify_sha256sum "$checksum_file_path" "$file_path"
  assert_equals "true" "$sha256sum_is_correct"

  # Checksum file format that has a filename.
  echo "$expected_sha256sum  myfile.txt" >"$checksum_file_path"
  assert_equals "true" "$sha256sum_is_correct"

  log "The 'Incorrect checksum' message below is OK."
  local wrong_sha256sum=cda1ee400a07d94301112707836aafaaa1760359e3cb80c9754299b82586d4ed
  local wrong_checksum_file_path=$checksum_file_path.wrong
  echo "$wrong_sha256sum" >"$wrong_checksum_file_path"
  verify_sha256sum "$wrong_checksum_file_path" "$file_path"
  assert_equals "false" "$sha256sum_is_correct"
}

yb_test_expect_num_args() {
  expect_num_args 0
  expect_num_args 1 foo
  expect_num_args 1-2 foo
  expect_num_args 1-3 foo
  expect_num_args 2 foo bar
  expect_num_args 1-2 foo bar
  expect_num_args 2-3 foo bar

  assert_incorrect_num_args 0 foo bar
  assert_incorrect_num_args 1
  assert_incorrect_num_args 1 foo bar
  assert_incorrect_num_args 2
  assert_incorrect_num_args 2 foo
  assert_incorrect_num_args 2 foo bar baz
}

# Arguments:
#   - Python interpreter (e.g. python.7 or python3)
#   - Regular expression that that the Python version should match
#   - One or more modules to install in the virtualenv.
check_virtualenv() {
  local python_interpreter=$1
  local python_version_regex=$2
  shift 2
  local venv_parent_dir=$TEST_TMPDIR/${python_interpreter}_venv_parent_dir
  mkdir -p "$venv_parent_dir"
  local requirement
  for requirement in "$@"; do
    echo "$requirement"
  done >"$venv_parent_dir/requirements.txt"
  local pip_list_output_path=$venv_parent_dir/pip_list_output.txt
  local python_interpreter_path_file=$venv_parent_dir/python_interpreter_path.txt
  (
    yb_activate_virtualenv "$venv_parent_dir" "$python_interpreter"
    pip list >"$pip_list_output_path"
    command -v python >"$python_interpreter_path_file"
  )
  for requirement in "$@"; do
    assert_egrep "^${requirement}[[:space:]]" "$pip_list_output_path"
  done

  local python_interpreter_path_in_venv
  python_interpreter_path_in_venv=$(<"$python_interpreter_path_file")
  local actual_python_version
  actual_python_version=$( "$python_interpreter_path_in_venv" --version 2>&1 )
  assert_matches_regex "Python $python_version_regex" "$actual_python_version"
}

yb_test_activate_virtualenv() {
  check_virtualenv python2.7 "2([.][0-9]+)+" psutil
  check_virtualenv python3 "3([.][0-9]+)+" requests
}

check_switching_virtualenv() {
  local python_interpreter=$1
  shift
  local venv_parent_dir1=$TEST_TMPDIR/${python_interpreter}_venv_parent_dir1
  mkdir -p "$venv_parent_dir1"
  local venv_parent_dir2=$TEST_TMPDIR/${python_interpreter}_venv_parent_dir2
  mkdir -p "$venv_parent_dir2"

  # Only install requirements in the second virtualenv.
  local requirement
  for requirement in "$@"; do
    echo "$requirement"
  done >"$venv_parent_dir2/requirements.txt"

  local pip_list_output_path1=$venv_parent_dir1/pip_list_output.txt
  local pip_list_output_path2=$venv_parent_dir2/pip_list_output.txt
  local pip_list_deactivated_output_path=$venv_parent_dir2/pip_list_deactivated.txt
  local python_interpreter_path_file1=$venv_parent_dir1/python_interpreter_path.txt
  local python_interpreter_path_file2=$venv_parent_dir2/python_interpreter_path.txt

  (
    yb_activate_virtualenv "$venv_parent_dir1" "$python_interpreter"
    pip list >"$pip_list_output_path1"
    command -v python >"$python_interpreter_path_file1"

    yb_activate_virtualenv "$venv_parent_dir2" "$python_interpreter"
    pip list >"$pip_list_output_path2"
    command -v python >"$python_interpreter_path_file2"

    yb_deactivate_virtualenv
    pip list >"$pip_list_deactivated_output_path"
  )

  for requirement in "$@"; do
    assert_egrep_no_results "^${requirement}[[:space:]]" "$pip_list_output_path1"
    assert_egrep "^${requirement}[[:space:]]" "$pip_list_output_path2"
    assert_egrep_no_results "^${requirement}[[:space:]]" "$pip_list_deactivated_output_path"
  done
}

yb_test_switching_virtualenv() {
  declare -a modules
  modules=( requests numpy )
  check_switching_virtualenv python2.7 "${modules[@]}"
  check_switching_virtualenv python3 "${modules[@]}"
}

yb_test_make_regex_from_list() {
  make_regex_from_list MY_TEST_LIST foo bar baz
  assert_equals "^(foo|bar|baz)$" "$MY_TEST_LIST_RE"
}

yb_test_make_regex_from_lists() {
  local MY_TEST_LIST_RE
  local MY_TEST_LIST_RAW_RE
  make_regex_from_list MY_TEST_LIST foo bar baz
  assert_equals "^(foo|bar|baz)$" "$MY_TEST_LIST_RE"
  assert_equals "foo|bar|baz" "$MY_TEST_LIST_RAW_RE"
}

# -------------------------------------------------------------------------------------------------
# Command line argument parsing
# -------------------------------------------------------------------------------------------------

print_usage() {
  cat <<-EOT
Usage: ${0##*/} [<options>]
Options:
  -h, --help
    Show usage
  -t, --test-filter-regex [<test_re>]
    Only run tests whose names match the given regular expression (anchored). The yb_test_ prefix
    of the test function name is not included when matching. E.g. specify "logging" to only run the
    yb_test_logging test function, and specify .*virtualenv.* to run all test functions containing
    the word virtualenv.
EOT
}

parse_args() {
  yb_test_case_filter_regex=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        print_usage
        exit
      ;;
      -t|--test-filter-regex)
        yb_test_case_filter_regex=$2
        shift
      ;;
      *)
        echo >&2 "Invalid argument: $1"
        exit 1
    esac
    shift
  done
}

# -------------------------------------------------------------------------------------------------
# Main test runner code
# -------------------------------------------------------------------------------------------------

cd "$YB_BASH_COMMON_ROOT"

echo "Bash version: $BASH_VERSION"
echo

parse_args "$@"

if command -v shellcheck >/dev/null; then
  # https://github.com/koalaman/shellcheck/wiki/SC2207
  # This has to work on Bash 3.x as well.
  shell_scripts=()
  while IFS='' read -r shell_script; do shell_scripts+=( "$shell_script"); done < <(
    find . -name "*.sh" -type f
  )

  for shell_script in "${shell_scripts[@]}"; do
    log "Checking script $shell_script with shellcheck"
    shellcheck -x "$shell_script"
  done
fi

TEST_TMPDIR=/tmp/yugabyte-bash-common-test.$$.$RANDOM.$RANDOM.$RANDOM
mkdir -p "$TEST_TMPDIR"

trap cleanup EXIT

global_exit_code=0
test_fn_names=$(
  declare -F | sed 's/^declare -f //' | grep '^yb_test_' | sort
)

num_test_functions_skipped=0
for fn_name in $test_fn_names; do
  if [[ -n $yb_test_case_filter_regex &&
        ! ${fn_name#yb_test_} =~ $yb_test_case_filter_regex ]]; then
    (( num_test_functions_skipped+=1 ))
    continue
  fi

  heading "Running test case $fn_name"
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

# OK to duplicate the version information -- it is important.
echo "Ran tests with Bash version: $BASH_VERSION"

echo >&2 "Total assertions succeeded: $num_assertions_succeeded, failed: $num_assertions_failed"
if [[ $global_exit_code -eq 0 ]]; then
  echo "Tests SUCCEEDED"
else
  echo "Tests FAILED"
fi

if [[ $num_test_functions_skipped -gt 0 ]]; then
  echo >&2 "Test functions skipped: $num_test_functions_skipped"
fi
exit "$global_exit_code"
