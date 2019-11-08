#@IgnoreInspection BashAddShebang

# Copyright (c) YugaByte, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.  You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License
# is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
# or implied.  See the License for the specific language governing permissions and limitations
# under the License.
#

set -euo pipefail

if [[ $BASH_SOURCE == $0 ]]; then
  echo "$BASH_SOURCE must be sourced, not executed" >&2
  exit 1
fi

readonly YB_BASH_COMMON_ROOT=$( cd "${BASH_SOURCE/*}" && cd .. && pwd )

readonly YELLOW_COLOR="\033[0;33m"
readonly RED_COLOR="\033[0;31m"
readonly CYAN_COLOR="\033[0;36m"
readonly NO_COLOR="\033[0m"

# http://stackoverflow.com/questions/5349718/how-can-i-repeat-a-character-in-bash
readonly HORIZONTAL_LINE=$( printf '=%.0s' {1..80} )

# This could be switched to e.g. python3 or a Python interpreter in a specific location.
yb_python_interpeter=python2.7
yb_os_detected=false

# -------------------------------------------------------------------------------------------------
# Git related
# -------------------------------------------------------------------------------------------------

# Returns current git SHA1 in the variable current_git_sha1.
get_current_git_sha1() {
  current_git_sha1=$( git rev-parse HEAD )
  if [[ ! $current_git_sha1 =~ ^[0-9a-f]{40}$ ]]; then
    fatal "Could not get current git SHA1 in $PWD, got: $current_git_sha1"
  fi
}

# -------------------------------------------------------------------------------------------------
# OS, CPU count, and cloud environment detection
# -------------------------------------------------------------------------------------------------

detect_num_cpus() {
  if [[ ! ${YB_NUM_CPUS:-} =~ ^[0-9]+$ ]]; then
    if is_linux; then
      YB_NUM_CPUS=$(grep -c processor /proc/cpuinfo)
    elif is_mac; then
      YB_NUM_CPUS=$(sysctl -n hw.ncpu)
    else
      fatal "Don't know how to detect the number of CPUs on OS $OSTYPE."
    fi

    if [[ ! $YB_NUM_CPUS =~ ^[0-9]+$ ]]; then
      fatal "Invalid number of CPUs detected: '$YB_NUM_CPUS' (expected a number)."
    fi
  fi
}

detect_os() {
  if "$yb_os_detected"; then
    return
  fi
  is_mac=false
  is_linux=false
  is_debian=false
  is_ubuntu=false
  is_centos=false
  short_os_name="unknown_os"

  case $OSTYPE in
    darwin*)
      is_mac=true
      short_os_name="mac"
    ;;
    linux*)
      is_linux=true
      short_os_name="linux"
    ;;
    *)
      fatal "Unknown operating system: $OSTYPE"
    ;;
  esac

  if "$is_linux"; then
    # Detect Linux flavor
    if [[ -f /etc/issue ]]; then
      if grep -q Ubuntu /etc/issue; then
        is_debian=true
        is_ubuntu=true
        short_os_name="ubuntu"
      elif grep -q Debian /etc/issue; then
        is_debian=true
        short_os_name="debian"
      fi
    elif [[ -f /etc/redhat-release ]] && grep CentOS /etc/redhat-release > /dev/null; then
      is_centos=true
      short_os_name="centos"
    fi
  fi

  readonly yb_os_detected=true
}

is_mac() {
  [[ $OSTYPE =~ ^darwin ]]
}

is_linux() {
  [[ $OSTYPE =~ ^linux ]]
}

is_centos() {
  [[ $is_centos == "true" ]]
}

# Detect if we're running on Google Compute Platform. We perform this check lazily as there might be
# a bit of a delay resolving the domain name.
detect_gcp() {
  # How to detect if we're running on Google Compute Engine:
  # https://cloud.google.com/compute/docs/instances/managing-instances#dmi
  if [[ -n ${YB_PRETEND_WE_ARE_ON_GCP:-} ]] || \
     curl metadata.google.internal --silent --output /dev/null --connect-timeout 1; then
    readonly is_running_on_gcp_exit_code=0  # "true" exit code
  else
    readonly is_running_on_gcp_exit_code=1  # "false" exit code
  fi
}

is_running_on_gcp() {
  if [[ -z ${is_running_on_gcp_exit_code:-} ]]; then
    detect_gcp
  fi
  return "$is_running_on_gcp_exit_code"
}

# -------------------------------------------------------------------------------------------------
# Wrappers for common UNIX utilities
# -------------------------------------------------------------------------------------------------

# sed -i works differently on Linux vs macOS.
sed_i() {
  if is_mac; then
    sed -i "" "$@"
  else
    sed -i "$@"
  fi
}

to_lowercase() {
  tr A-Z a-z
}

# For each file provided as an argument, gzip the given file if it exists and is not already
# compressed.
gzip_if_exists() {
  local f
  for f in "$@"; do
    if [[ -f $f && $f != *.gz && $f != *.bz2 ]]; then
      gzip "$f"
    fi
  done
}

# -------------------------------------------------------------------------------------------------
# pushd/popd wrappers
# -------------------------------------------------------------------------------------------------

# Make pushd and popd quiet.
# http://stackoverflow.com/questions/25288194/dont-display-pushd-popd-stack-accross-several-bash-scripts-quiet-pushd-popd
pushd() {
  local dir_name=$1
  if [[ ! -d $dir_name ]]; then
    fatal "Directory '$dir_name' does not exist"
  fi
  command pushd "$@" > /dev/null
}

popd() {
  command popd "$@" > /dev/null
}

# -------------------------------------------------------------------------------------------------
# Timestamps
# -------------------------------------------------------------------------------------------------

get_timestamp() {
  date +%Y-%m-%dT%H:%M:%S
}

get_timestamp_for_filenames() {
  date +%Y-%m-%dT%H_%M_%S
}

# -------------------------------------------------------------------------------------------------
# Logging and stack traces
# -------------------------------------------------------------------------------------------------

print_stack_trace() {
  local -i i=${1:-1}  # Allow the caller to set the line number to start from.
  echo "Stack trace:" >&2
  while [[ $i -lt "${#FUNCNAME[@]}" ]]; do
    echo "  ${BASH_SOURCE[$i]}:${BASH_LINENO[$((i - 1))]} ${FUNCNAME[$i]}" >&2
    let i+=1
  done
}

fatal() {
  if [[ -n "${yb_fatal_quiet:-}" ]]; then
    yb_log_quiet=$yb_fatal_quiet
  else
    yb_log_quiet=false
  fi
  yb_log_skip_top_frames=1
  log "$@"
  if ! "$yb_log_quiet"; then
    print_stack_trace 2  # Exclude this line itself from the stack trace (start from 2nd line).
  fi
  exit "${yb_fatal_exit_code:-1}"
}

log_empty_line() {
  if [[ ${yb_log_quiet:-} == "true" ]]; then
    return
  fi
  echo >&2
}

log_separator() {
  if [[ ${yb_log_quiet:-} == "true" ]]; then
    return
  fi
  log_empty_line
  echo >&2 "--------------------------------------------------------------------------------------"
  log_empty_line
}

heading() {
  if [[ ${yb_log_quiet:-} == "true" ]]; then
    return
  fi
  log_empty_line
  echo >&2 "--------------------------------------------------------------------------------------"
  echo >&2 "$1"
  echo >&2 "--------------------------------------------------------------------------------------"
  log_empty_line
}

log() {
  if [[ ${yb_log_quiet:-} == "true" ]]; then
    return
  fi
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
  local stack_idx1=$(( $stack_idx0 + 1 ))

  echo "[$( get_timestamp )" \
       "${BASH_SOURCE[$stack_idx1]##*/}:${BASH_LINENO[$stack_idx0]}" \
       "${FUNCNAME[$stack_idx1]}]" $* >&2
}

log_with_color() {
  local log_color=$1
  shift
  log "$log_color$*$NO_COLOR"
}

log_file_existence() {
  expect_num_args 1 "$@"
  local file_name=$1
  if [[ -L $file_name && -f $file_name ]]; then
    log "Symlink exists and points to a file: $file_name"
  elif [[ -L $file_name && -d $file_name ]]; then
    log "Symlink exists and points to a directory: $file_name"
  elif [[ -L $file_name ]]; then
    log "Symlink exists but it might be broken: $file_name"
  elif [[ -f $file_name ]]; then
    log "File exists: $file_name"
  elif [[ -d $file_name ]]; then
    log "Directory exists: $file_name"
  elif [[ ! -e $file_name ]]; then
    log "File does not exist: $file_name"
  else
    log "File exists but we could not determine its type: $file_name"
  fi
}

horizontal_line() {
  echo "------------------------------------------------------------------------------------------"
}

thick_horizontal_line() {
  echo "=========================================================================================="
}

debug_log_boolean_function_result() {
  expect_num_args 1 "$@"
  local fn_name=$1
  if "$fn_name"; then
    log "$fn_name is true"
  else
    log "$fn_name is false"
  fi
}

# -------------------------------------------------------------------------------------------------
# Function argument validation
# -------------------------------------------------------------------------------------------------

# Usage: expect_some_args "$@"
# Fatals if there are no arguments.
expect_some_args() {
  local calling_func_name=${FUNCNAME[1]}
  if [[ $# -eq 0 ]]; then
    fatal "$calling_func_name expects at least one argument"
  fi
}

# Validates the number of arguments passed to its caller. Should also be passed all the caller's
# arguments using "$@".
# Example:
#   expect_num_args 1 "$@"
expect_num_args() {
  expect_some_args "$@"
  local caller_expected_num_args=$1
  local calling_func_name=${FUNCNAME[1]}
  shift
  if [[ $# -ne $caller_expected_num_args ]]; then
    yb_log_quiet=false
    local error_msg="$calling_func_name expects $caller_expected_num_args arguments, got $#."
    if [[ $# -eq 0 ]]; then
      error_msg+=" Check if \"\$@\" was included in the call to expect_num_args."
    fi
    if [[ $# -gt 0 ]]; then
      log "Logging actual arguments to '$calling_func_name' before a fatal error (XML-style):"
      local arg
      for arg in "$@"; do
        log "  - <argument>$arg</argument>"
      done
    fi
    fatal "$error_msg"
  fi
}

# Make a regular expression from a list of possible values. This function takes any non-zero number
# of arguments, but each argument is further broken down into components separated by whitespace,
# and those components are treated as separate possible values. Empty values are ignored.
make_regex_from_list() {
  expect_num_args 1 "$@"
  local list_var_name=$1
  local regex=""
  local list_var_name_full="$list_var_name[@]"
  for item in "${!list_var_name_full}"; do
    if [[ -z $item ]]; then
      continue
    fi
    if [[ -n $regex ]]; then
      regex+="|"
    fi
    regex+="$item"
  done
  eval "${list_var_name}_RE=\"^($regex)$\""
  eval "${list_var_name}_RAW_RE=\"$regex\""
}

make_regexes_from_lists() {
  local list_var_name
  for list_var_name in "$@"; do
    make_regex_from_list "$list_var_name"
  done
}

# -------------------------------------------------------------------------------------------------
# Colors
# -------------------------------------------------------------------------------------------------

yellow_color() {
  echo -ne "$YELLOW_COLOR"
}

red_color() {
  echo -ne "$RED_COLOR"
}

cyan_color() {
  echo -ne "$CYAN_COLOR"
}

no_color() {
  echo -ne "$NO_COLOR"
}

# -------------------------------------------------------------------------------------------------
# Variable validation
# -------------------------------------------------------------------------------------------------

expect_vars_to_be_set() {
  local calling_func_name=${FUNCNAME[1]}
  local var_name
  for var_name in "$@"; do
    if [[ -z ${!var_name:-} ]]; then
      fatal "The '$var_name' variable must be set by the caller of $calling_func_name." \
            "$calling_func_name expects the following variables to be set: $@."
    fi
  done
}

# -------------------------------------------------------------------------------------------------
# File/directory manipulation
# -------------------------------------------------------------------------------------------------

check_directory_exists() {
  expect_num_args 1 "$@"
  local directory_path=$1
  if [[ ! -d $directory_path ]]; then
    fatal "Directory '$directory_path' does not exist or is not a directory"
  fi
}

# Deprecated. Use check_directory_exists instead.
ensure_directory_exists() {
  check_directory_exists "$@"
}

check_file_exists() {
  expect_num_args 1 "$@"
  local file_name=$1
  if [[ ! -f $file_name ]]; then
    fatal "File '$file_name' does not exist or is not a file"
  fi
}

# Deprecated. Use check_file_exists instead.
ensure_file_exists() {
  check_file_exists "$@"
}

mkdir_safe() {
  expect_num_args 1 "$@"
  local dir_path=$1
  # Check if this is a broken link.
  if [[ -h $dir_path && ! -d $dir_path ]]; then
    unlink "$dir_path"
  fi
  mkdir -p "$dir_path"
}

read_file_and_trim() {
  expect_num_args 1 "$@"
  local file_name=$1
  if [[ -f $file_name ]]; then
    cat "$file_name" | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//'
  else
    log "File '$file_name' does not exist"
    return 1
  fi
}

# -------------------------------------------------------------------------------------------------
# SHA256 checksums
# -------------------------------------------------------------------------------------------------

run_sha256sum_on_mac() {
  shasum --portable --algorithm 256 "$@"
}

# Output variable: sha256sum_is_correct
verify_sha256sum() {
  expect_num_args 2 "$@"
  local checksum_file=$1
  local data_file=$2
  ensure_file_exists "$checksum_file"
  ensure_file_exists "$data_file"
  local expected_sha256sum=$(<"$checksum_file")
  # Some expected checksum files also have the file name. Let's remove that.
  if [[ $expected_sha256sum =~ ^([0-9a-f]{64})[^0-9a-f].*$ ]]; then
    expected_sha256sum=${BASH_REMATCH[1]}
  fi
  if [[ ! $expected_sha256sum =~ ^[0-9a-f]{64}$ ]]; then
    fatal "Expected checksum has wrong format: '$expected_sha256sum'" \
          "(from '$checksum_file')"
  fi
  local computed_sha256sum
  compute_sha256sum "$data_file"
  if [[ $computed_sha256sum != $expected_sha256sum ]]; then
    log "Incorrect checksum for '$data_file' -- expected: $expected_sha256sum," \
         "actual: $computed_sha256sum"
    sha256sum_is_correct=false
  else
    log "Checksum for '$data_file' is correct: $computed_sha256sum"
    sha256sum_is_correct=true
  fi
}

# Returns the result in the computed_sha256sum variable
compute_sha256sum() {
  computed_sha256sum=$(
    if [[ $OSTYPE =~ darwin ]]; then
      run_sha256sum_on_mac "$@"
    else
      sha256sum "$@"
    fi | awk '{print $1}'
  )
  if [[ ! $computed_sha256sum =~ ^[0-9a-f]{64}$ ]]; then
    fatal "Could not compute SHA256 checksum, got '$computed_sha256sum' which is not a valid" \
          "SHA256 checksum. Arguments to compute_sha256sum: $*"
  fi
}

# -------------------------------------------------------------------------------------------------
# PATH manipulation
# -------------------------------------------------------------------------------------------------

remove_path_entry() {
  expect_num_args 1 "$@"
  local path_entry=$1
  local prev_path=""
  # Remove all occurrences of the given entry.
  while [[ $PATH != $prev_path ]]; do
    prev_path=$PATH
    PATH=:$PATH:
    PATH=${PATH//:$path_entry:/:}
    PATH=${PATH#:}
    PATH=${PATH%:}
  done
  export PATH
}

put_path_entry_first() {
  expect_num_args 1 "$@"
  local path_entry=$1
  remove_path_entry "$path_entry"
  export PATH=$path_entry:$PATH
}

add_path_entry() {
  expect_num_args 1 "$@"
  local path_entry=$1
  if [[ $PATH != *:$path_entry && $PATH != $path_entry:* && $PATH != *:$path_entry:* ]]; then
    export PATH+=:$path_entry
  fi
}

# -------------------------------------------------------------------------------------------------
# Retry loops
# -------------------------------------------------------------------------------------------------

run_with_retries() {
  if [[ $# -lt 2 ]]; then
    fatal "run_with_retries requires at least three arguments: max_attempts, delay_sec, and " \
          "the command to run (at least one additional argument)."
  fi
  declare -i -r max_attempts=$1
  declare -r delay_sec=$2
  shift 2

  declare -i attempt_index=1
  while [[ $attempt_index -le $max_attempts ]]; do
    set +e
    "$@"
    declare exit_code=$?
    set -e
    if [[ $exit_code -eq 0 ]]; then
      return
    fi
    log "Warning: command failed with exit code $exit_code at attempt $attempt_index: $*." \
        "Waiting for $delay_sec sec, will then re-try for up to $max_attempts attempts."
    let attempt_index+=1
    sleep "$delay_sec"
  done
  fatal "Failed to execute command after $max_attempts attempts: $*"
}

# -------------------------------------------------------------------------------------------------
# Java support
# -------------------------------------------------------------------------------------------------

set_java_home() {
  if ! is_mac; then
    return
  fi
  # macOS has a peculiar way of setting JAVA_HOME
  local cmd_to_get_java_home="/usr/libexec/java_home --version 1.8"
  local new_java_home=$( $cmd_to_get_java_home )
  if [[ ! -d $new_java_home ]]; then
    fatal "Directory returned by '$cmd_to_get_java_home' does not exist: $new_java_home"
  fi
  if [[ -n ${JAVA_HOME:-} && $JAVA_HOME != $new_java_home ]]; then
    log "Warning: updating JAVA_HOME from $JAVA_HOME to $new_java_home"
  else
    log "Setting JAVA_HOME: $new_java_home"
  fi
  export JAVA_HOME=$new_java_home
  put_path_entry_first "$JAVA_HOME/bin"
}

# -------------------------------------------------------------------------------------------------
# Python and virtualenv support
# -------------------------------------------------------------------------------------------------

run_python() {
  "$yb_python_interpreter" "$@"
}

yb_deactivate_virtualenv() {
  if [[ -n ${VIRTUAL_ENV:-} ]]; then
    remove_path_entry "$VIRTUAL_ENV/bin"
    unset PYTHONPATH
  fi
}

# Creates (if necessary) and activates a virtualenv at a "venv" subdirectory of the given top-level
# directory. Also if there is a requirements_frozen.txt or a requirements.txt file in that
# directory, installs the dependencies described by that file into the virtualenv. This opinionated
# setup creates a common structure across multiple Python projects.
yb_activate_virtualenv() {
  expect_num_args 1 "$@"
  local top_dir=$1
  if [[ ! -d $top_dir ]]; then
    fatal "Top-level directory to create a virtualenv subdirectory in does not exist: $top_dir"
  fi
  local venv_dir=$top_dir/venv
  if [[ ! -d $venv_dir ]]; then
    yb_deactivate_virtualenv
    run_python -m pip install virtualenv --user
    run_python -m virtualenv "$venv_dir"
  fi

  set +u
  . "$venv_dir"/bin/activate
  set -u

  local requirements_path=$top_dir/requirements.txt
  local frozen_requirements_path=$top_dir/requirements_frozen.txt
  if [[ -f $frozen_requirements_path ]]; then
    requirements_path=$frozen_requirements_path
  fi
  if [[ -f $requirements_path ]]; then
    # Don't fail if every output line from pip is of the "Requirements already satisfied" form.
    "$venv_dir"/bin/pip install -r "$requirements_path" | \
        egrep -v '^Requirement already satisfied: ' || true
  else
    log "Warning: no requirements.txt or requirements_frozen.txt found at $top_dir"
  fi
}

# -------------------------------------------------------------------------------------------------
# Initialization
# -------------------------------------------------------------------------------------------------

detect_os
