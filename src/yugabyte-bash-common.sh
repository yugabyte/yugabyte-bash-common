#!/usr/bin/env bash

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

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "${BASH_SOURCE[0]} must be sourced, not executed" >&2
  exit 1
fi

# -------------------------------------------------------------------------------------------------
# Bash version warning
# -------------------------------------------------------------------------------------------------

#
# Pull in our needed libs
# 
DIR="${BASH_SOURCE%/*}"
if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi
# shellcheck disable=SC1091,SC1090
. "${DIR}"/logger.sh
# shellcheck disable=SC1091,SC1090
. "${DIR}"/os.sh
# shellcheck disable=SC1091,SC1090
. "${DIR}"/detect_python.sh
# shellcheck disable=SC1091,SC1090
. "${DIR}"/create_venv.sh

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

# This helps validate that the number of arguments passed to a function is within a certain range.
# Should also be passed all the arguments.
# arguments using "$@".
# Examples:
#   - To check if a function is passed exactly one argument:
#
#     expect_num_args 1 "$@"
#
#   - To check that the number of arguments passed to a function is within a certain range:
#
#     expect_num_args 1-2 "$@"
expect_num_args() {
  expect_some_args "$@"
  local expected_num_args=$1
  local num_args_lower_bound
  local num_args_upper_bound
  if [[ $expected_num_args == *-* ]]; then
    if [[ ! $expected_num_args =~ ^[0-9]+-[0-9]+$ ]]; then
      fatal "Invalid range of the expected number of arguments: '$expected_num_args'"
    fi
    num_args_lower_bound=${1%%-*}
    num_args_upper_bound=${1##*-}
    if [[ $num_args_lower_bound -gt num_args_upper_bound ]]; then
      fatal "Invalid range of the expected number of arguments (reversed lower/upper bound):" \
            "'$expected_num_args'"
    fi
  else
    num_args_lower_bound=$expected_num_args
    num_args_upper_bound=$expected_num_args
  fi

  local calling_func_name=${FUNCNAME[1]}
  shift
  if [[ $# -lt $num_args_lower_bound || $# -gt $num_args_upper_bound ]]; then
    # shellcheck disable=SC2034
    yb_log_quiet=false
    if [[ $num_args_lower_bound -eq $num_args_upper_bound ]]; then
      local error_msg="$calling_func_name expects $expected_num_args arguments, got $#."
    else
      local error_msg=\
"$calling_func_name expects from $num_args_lower_bound to $num_args_upper_bound arguments, got $#."
    fi
    if [[ $# -eq 0 ]]; then
      error_msg+=" Check if \"\$@\" was included in the call to expect_num_args."
    else
      log "Logging actual arguments to '$calling_func_name' before a fatal error (XML-style):"
      local arg
      for arg in "$@"; do
        log "  - <argument>$arg</argument>"
      done
    fi
    fatal "$error_msg"
  fi
}

# Make a regular expression from a list of values.
# Arguments:
#   - list_var_name: the prefix for output variable names.
#     ${list_var_name}_RE becomes the anchored regex with parentheses, e.g.: ^(foo|bar)$
#     ${list_var_name}_RAW_RE becomes the unanchored regex with no parentheses, e.g.: foo|bar
#   - The list of possible values to include in the regex.
make_regex_from_list() {
  if [[ $# -lt 2 ]]; then
    fatal "make_regex_from_list expects at least two arguments"
  fi
  local list_var_name=$1
  shift
  local regex=""
  for item in "$@"; do
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

# -------------------------------------------------------------------------------------------------
# Variable validation
# -------------------------------------------------------------------------------------------------

expect_vars_to_be_set() {
  local calling_func_name=${FUNCNAME[1]}
  local var_name
  for var_name in "$@"; do
    if [[ -z ${!var_name:-} ]]; then
      fatal "The '$var_name' variable must be set by the caller of $calling_func_name." \
            "$calling_func_name expects the following variables to be set: $*."
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
    sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' <"$file_name"
  else
    log "File '$file_name' does not exist"
    return 1
  fi
}

# -------------------------------------------------------------------------------------------------
# SHA256 checksums
# -------------------------------------------------------------------------------------------------

# Output variable: sha256sum_is_correct
verify_sha256sum() {
  expect_num_args 2 "$@"
  local checksum_file=$1
  local data_file=$2
  ensure_file_exists "$checksum_file"
  ensure_file_exists "$data_file"
  local expected_sha256sum
  expected_sha256sum=$(<"$checksum_file")
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
  if [[ $computed_sha256sum != "$expected_sha256sum" ]]; then
    log "Incorrect checksum for '$data_file' -- expected: $expected_sha256sum," \
         "actual: $computed_sha256sum"
    # shellcheck disable=SC2034
    sha256sum_is_correct=false
  else
    log "Checksum for '$data_file' is correct: $computed_sha256sum"
    # shellcheck disable=SC2034
    sha256sum_is_correct=true
  fi
}

# Returns the result in the computed_sha256sum variable
compute_sha256sum() {
  computed_sha256sum=$(
    # shellcheck disable=SC2154
    ${yb_sha256sum} "$@" | awk '{print $1}'
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
  while [[ $PATH != "$prev_path" ]]; do
    prev_path=$PATH
    PATH=:$PATH:
    PATH=${PATH//:$path_entry:/:}
    PATH=${PATH#:}
    PATH=${PATH%:}
  done
  export PATH
}

# This is used for escaping command lines for remote execution.
# From StackOverflow: https://goo.gl/sTKReB
# Using this approach: "Put the whole string in single quotes. This works for all chars except
# single quote itself. To escape the single quote, close the quoting before it, insert the single
# quote, and re-open the quoting."
#
escape_cmd_line() {
  escape_cmd_line_rv=""
  for arg in "$@"; do
    # shellcheck disable=SC2027
    escape_cmd_line_rv+=" '"${arg/\'/\'\\\'\'}"'"
    # This should be equivalent to the sed command below.  The quadruple backslash encodes one
    # backslash in the replacement string. We don't need that in the pure-bash implementation above.
    # sed -e "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/"
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
    # shellcheck disable=SC2034
    (( attempt_index+=1 ))
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
  local new_java_home
  new_java_home=$( $cmd_to_get_java_home )
  if [[ ! -d $new_java_home ]]; then
    fatal "Directory returned by '$cmd_to_get_java_home' does not exist: $new_java_home"
  fi
  if [[ -n ${JAVA_HOME:-} && $JAVA_HOME != "$new_java_home" ]]; then
    log "Warning: updating JAVA_HOME from $JAVA_HOME to $new_java_home"
  else
    log "Setting JAVA_HOME: $new_java_home"
  fi
  export JAVA_HOME=$new_java_home
  put_path_entry_first "$JAVA_HOME/bin"
}

# -------------------------------------------------------------------------------------------------
# Initialization
# -------------------------------------------------------------------------------------------------

detect_os
