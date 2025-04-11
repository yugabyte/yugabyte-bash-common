#!/usr/bin/env bash

set -euo pipefail
cd "${BASH_SOURCE%/*}"

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

#
# local log functions
#
log() {
  # Weirdly, when we put $* inside double quotes, that has an effect of making the following log
  # statement produce multi-line output:
  #
  #   log "Some long log statement" \
  #       "continued on the other line."
  #
  # We want that to produce a single line the same way the echo command would. Putting $* by
  # itself achieves that effect. That has a side effect of passing echo-specific arguments
  # (e.g. -n or -e) directly to the final echo command.
  #
  # On why the index for BASH_LINENO is one lower than that for BASH_SOURECE and FUNCNAME:
  # This is different from the manual says at
  # https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html:
  #
  #   An array variable whose members are the line numbers in source files where each
  #   corresponding member of FUNCNAME was invoked. ${BASH_LINENO[$i]} is the line number in the
  #   source file (${BASH_SOURCE[$i+1]}) where ${FUNCNAME[$i]} was called (or ${BASH_LINENO[$i-1]}
  #   if referenced within another shell function). Use LINENO to obtain the current line number.
  #
  # Our experience is that FUNCNAME indexes exactly match those of BASH_SOURCE.
  local stack_idx0=${yb_log_skip_top_frames:-0}
  local stack_idx1=$(( stack_idx0 + 1 ))

  # shellcheck disable=SC2048,SC2086
  echo "[$( get_timestamp )" \
       "${BASH_SOURCE[$stack_idx1]##*/}:${BASH_LINENO[$stack_idx0]}" \
       "${FUNCNAME[$stack_idx1]}]" $* >&2
}

heading() {
  echo >&2
  echo >&2 "--------------------------------------------------------------------------------------"
  echo >&2 "$1"
  echo >&2 "--------------------------------------------------------------------------------------"
  echo >&2
}

get_timestamp() {
  date +%Y-%m-%dT%H:%M:%S
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
  if [[ $actual == "$expected" ]]; then
    increment_successful_assertions
  else
    echo "Assertion failed: expected '$expected', got '$actual'" >&2
    increment_failed_assertions
  fi
}

assert_not_equals() {
  local unexpected=$1
  local actual=$2
  if [[ $actual == "$unexpected" ]]; then
    echo "Assertion failed: did not expect '$unexpected'" >&2
    increment_failed_assertions
  else
    increment_successful_assertions
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
  result=$( . src/yugabyte-bash-common.sh; expect_num_args "$@" 2>&1 )
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
  assert_equals "$( . "./src/logger.sh"; log "Foo bar" 2>&1 | sed 's/.*\] //g' )" "Foo bar"
}

yb_test_sed_i() {
  local file_path=$TEST_TMPDIR/sed_i_test.txt
  cat >"$file_path" <<EOT
Hello world hello world
Hello world hello world
EOT
  (
    . "./src/yugabyte-bash-common.sh"
    sed_i 's/lo wo/lo database wo/g' "$file_path"
  )
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
  computed_sha256sum=$(
    . "./src/yugabyte-bash-common.sh"
    compute_sha256sum "$file_path"
    echo ${computed_sha256sum}
  )
  local expected_sha256sum=cda1ee400a07d94301112707836aafaaa1760359e3cb80c9754299b82586d4ec
  assert_equals "$expected_sha256sum" "$computed_sha256sum"
  local checksum_file_path=$file_path.sha256
  echo "$expected_sha256sum" >"$checksum_file_path"
  local sha256sum_is_correct
  sha256sum_is_correct=$(
    . "./src/yugabyte-bash-common.sh"
    verify_sha256sum "$checksum_file_path" "$file_path"
    echo ${sha256sum_is_correct}
  )
  assert_equals "true" "$sha256sum_is_correct"

  # Checksum file format that has a filename.
  echo "$expected_sha256sum  myfile.txt" >"$checksum_file_path"
  assert_equals "true" "$sha256sum_is_correct"

  log "The 'Incorrect checksum' message below is OK."
  local wrong_sha256sum=cda1ee400a07d94301112707836aafaaa1760359e3cb80c9754299b82586d4ed
  local wrong_checksum_file_path=$checksum_file_path.wrong
  echo "$wrong_sha256sum" >"$wrong_checksum_file_path"
  sha256sum_is_correct=$(
    . "./src/yugabyte-bash-common.sh"
    verify_sha256sum "$wrong_checksum_file_path" "$file_path"
    echo "$sha256sum_is_correct"
  )
  assert_equals "false" "$sha256sum_is_correct"
}

yb_test_expect_num_args() {
  (
    . src/yugabyte-bash-common.sh
    expect_num_args 0
    expect_num_args 1 foo
    expect_num_args 1-2 foo
    expect_num_args 1-3 foo
    expect_num_args 2 foo bar
    expect_num_args 1-2 foo bar
    expect_num_args 2-3 foo bar
  )

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

  local should_upgrade_pip_str=$3
  if [[ $should_upgrade_pip_str == "no_pip_upgrade" ]]; then
    yb_virtualenv_upgrade_pip=false
  elif [[ $should_upgrade_pip_str == "upgrade_pip" ]]; then
    yb_virtualenv_upgrade_pip=true
  else
    fatal "Invalid value of 3rd parameter: $should_upgrade_pip_str (must be 'no_pip_upgrade' or" \
          "'upgrade_pip')."
  fi

  local should_expect_success_str=$4
  if [[ $should_expect_success_str == "expect_success" ]]; then
    expect_success=true
  elif [[ $should_expect_success_str == "expect_failure" ]]; then
    expect_success=false
  else
    fatal "Invalid value of 4th parameter: $should_expect_success_str" \
          "(must be 'expect_success' or 'expect_failure')."
  fi

  log "-------------------------------------------------------------------------------------------"
  log "python_interpreter=$python_interpreter"
  log "python_version_regex=$python_version_regex"
  log "yb_virtualenv_upgrade_pip=$yb_virtualenv_upgrade_pip"
  log "expect_success=$expect_success"
  log "-------------------------------------------------------------------------------------------"

  shift 4
  local python_modules_to_install=( "$@" )

  local venv_parent_dir=$TEST_TMPDIR/${python_interpreter}_venv_parent_dir
  mkdir -p "$venv_parent_dir"
  local requirement
  for requirement in "${python_modules_to_install[@]}"; do
    echo "$requirement"
  done >"$venv_parent_dir/requirements.txt"
  local pip_list_output_path=$venv_parent_dir/pip_list_output.txt
  local exit_code_output_path=$venv_parent_dir/yb_activate_virtualenv_exit_code.txt
  local python_interpreter_path_file=$venv_parent_dir/python_interpreter_path.txt
  (
    set +e
    export YB_PYTHON_VERSION=${python_interpreter}
    export YB_USE_TOP_LEVEL_VENV=true
    . "./src/create_venv.sh"
    yb_activate_virtualenv "$venv_parent_dir" "$python_interpreter"
    echo "$?" >"$exit_code_output_path"
    set -e
    pip list >"$pip_list_output_path"
    command -v python >"$python_interpreter_path_file"
  )
  local yb_activate_virtualenv_exit_code
  yb_activate_virtualenv_exit_code=$(<"$exit_code_output_path")

  # We still expect the virtualenv to be created in all of our expected-failure use cases.
  # It is the module installation that may fail.
  local python_interpreter_path_in_venv
  python_interpreter_path_in_venv=$(<"$python_interpreter_path_file")
  local actual_python_version
  actual_python_version=$( "$python_interpreter_path_in_venv" --version 2>&1 )
  assert_matches_regex "Python $python_version_regex" "$actual_python_version"

  if [[ "$expect_success" == "true" ]]; then
    assert_equals 0 "$yb_activate_virtualenv_exit_code"
    for requirement in "${python_modules_to_install[@]}"; do
      assert_egrep "^${requirement}[[:space:]]" "$pip_list_output_path"
    done
  else
    assert_not_equals 0 "$yb_activate_virtualenv_exit_code"
  fi
}

yb_test_activate_virtualenv() {
  check_virtualenv 3 "3([.][0-9]+)+"   no_pip_upgrade expect_success requests
  check_virtualenv 3 "3([.][0-9]+)+"   upgrade_pip    expect_success codecheck
  check_virtualenv 3 "3([.][0-9]+)+"   upgrade_pip    expect_failure nosuchmodule
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
  local python_interpreter_path_deactivated=$venv_parent_dir2/python_deactivated_path.txt
  local python_interpreter_path_initial=$venv_parent_dir2/python_initial_path.tx


  (
    export YB_USE_TOP_LEVEL_VENV=true
    export YB_PYTHON_VERSION=${python_interpreter}
    . "./src/create_venv.sh"
    command -v python > "$python_interpreter_path_initial"
    yb_activate_virtualenv "$venv_parent_dir1"
    pip list >"$pip_list_output_path1"
    command -v python >"$python_interpreter_path_file1"

    yb_activate_virtualenv "$venv_parent_dir2"
    pip list >"$pip_list_output_path2"
    command -v python >"$python_interpreter_path_file2"

    yb_deactivate_virtualenv
    pip list >"$pip_list_deactivated_output_path"
    command -v python >"$python_interpreter_path_deactivated"
  )

  for requirement in "$@"; do
    assert_egrep_no_results "^${requirement}[[:space:]]" "$pip_list_output_path1"
    assert_egrep "^${requirement}[[:space:]]" "$pip_list_output_path2"
  done
  assert_equals "$(<$python_interpreter_path_initial)" "$(<$python_interpreter_path_deactivated)"
}

yb_test_switching_virtualenv() {
  declare -a modules
  modules=( requests numpy )
  check_switching_virtualenv 3 "${modules[@]}"
}

yb_test_make_regex_from_list() {
  MY_TEST_LIST_RE=$(
    . "./src/yugabyte-bash-common.sh"
    make_regex_from_list MY_TEST_LIST foo bar baz
    echo "${MY_TEST_LIST_RE}"
  )
  assert_equals "^(foo|bar|baz)$" "$MY_TEST_LIST_RE"
}

yb_test_make_regex_from_lists() {
  local MY_TEST_LIST_RE
  MY_TEST_LIST_RE=$(
    . "./src/yugabyte-bash-common.sh"
    make_regex_from_list MY_TEST_LIST foo bar baz
    echo "${MY_TEST_LIST_RE}"
  )
  local MY_TEST_LIST_RAW_RE
  MY_TEST_LIST_RAW_RE=$(
    . "./src/yugabyte-bash-common.sh"
    make_regex_from_list MY_TEST_LIST foo bar baz
    echo "${MY_TEST_LIST_RAW_RE}"
  )
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

cd ".."
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
    if [[ "${shell_script}" == "./test/test.sh" ]]; then
      continue
    fi
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
