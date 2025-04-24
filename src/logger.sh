#!/usr/bin/env bash
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

[[ "${_YB_LOGGER_INCLUDED:-}" == "true" ]] && return 0
_YB_LOGGER_INCLUDED=true
# -------------------------------------------------------------------------------------------------
# Global variables used in this module
# -------------------------------------------------------------------------------------------------
yb_fatal_quiet=${yb_fatal_quiet:-false}
yb_log_quiet=${yb_log_quiet:-false}
FAIL_ON_WARNING=${FAIL_ON_WARNING:-false}
YB_VERBOSE=${YB_VERBOSE:-false}
# -------------------------------------------------------------------------------------------------
# Global variables defined in this module
# -------------------------------------------------------------------------------------------------
# shellcheck disable=SC2034,SC2155
readonly YB_BASH_COMMON_ROOT=$( cd "${BASH_SOURCE/*}" && cd .. && pwd )

# shellcheck disable=SC2034,SC2155
readonly YELLOW_COLOR="\033[0;33m"

# shellcheck disable=SC2034,SC2155
readonly RED_COLOR="\033[0;31m"

# shellcheck disable=SC2034,SC2155
readonly CYAN_COLOR="\033[0;36m"

# shellcheck disable=SC2034,SC2155
readonly NO_COLOR="\033[0m"

# shellcheck disable=SC2034,SC2155
# http://stackoverflow.com/questions/5349718/how-can-i-repeat-a-character-in-bash
readonly HORIZONTAL_LINE=$( printf '=%.0s' {1..80} )

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

function yb::verbose_log() {
  # Print our info messages to stderr and only when asked (YB_VERBOSE=true).
  local msg="$*"
  if [[ ${YB_VERBOSE} != "true" ]]; then
    return
  fi
  local stack_idx0=${yb_log_skip_top_frames:-0}
  local stack_idx1=$(( stack_idx0 + 1 ))

  # shellcheck disable=SC2048,SC2086
  echo -e "[$( get_timestamp )" \
       "${BASH_SOURCE[$stack_idx1]##*/}:${BASH_LINENO[$stack_idx0]}" \
       "${FUNCNAME[$stack_idx1]}]" "${msg}" >&2
}

print_stack_trace() {
  local -i i=${1:-1}  # Allow the caller to set the line number to start from.
  echo "Stack trace:" >&2
  while [[ $i -lt "${#FUNCNAME[@]}" ]]; do
    echo "  ${BASH_SOURCE[$i]}:${BASH_LINENO[$((i - 1))]} ${FUNCNAME[$i]}" >&2
    (( i+=1 ))
  done
}

fatal() {
  if [[ -n "${yb_fatal_quiet}" ]]; then
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
  if [[ ${yb_log_quiet} == "true" ]]; then
    return
  fi
  echo >&2
}

log_separator() {
  if [[ ${yb_log_quiet} == "true" ]]; then
    return
  fi
  log_empty_line
  echo >&2 "--------------------------------------------------------------------------------------"
  log_empty_line
}

heading() {
  if [[ ${yb_log_quiet} == "true" ]]; then
    return
  fi
  log_empty_line
  echo >&2 "--------------------------------------------------------------------------------------"
  echo >&2 "$1"
  echo >&2 "--------------------------------------------------------------------------------------"
  log_empty_line
}

log() {
  if [[ ${yb_log_quiet} == "true" ]]; then
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
  local stack_idx1=$(( stack_idx0 + 1 ))

  # shellcheck disable=SC2048,SC2086
  echo -e "[$( get_timestamp )" \
       "${BASH_SOURCE[$stack_idx1]##*/}:${BASH_LINENO[$stack_idx0]}" \
       "${FUNCNAME[$stack_idx1]}]" $* >&2
}

log_with_color() {
  local log_color=$1
  shift
  log "$log_color$*$NO_COLOR"
}

warn() {
  local stack_idx0=${yb_log_skip_top_frames:-0}
  local stack_idx1=$(( stack_idx0 + 1 ))

  # shellcheck disable=SC2048,SC2086
  echo -e "[$( get_timestamp )" \
    "${BASH_SOURCE[$stack_idx1]##*/}:${BASH_LINENO[$stack_idx0]}" \
    "${FUNCNAME[$stack_idx1]}]" $* >&2

  if ${FAIL_ON_WARNING}; then
    exit 1
  fi
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

to_lowercase() {
  tr '[:upper:]' '[:lower:]'
}
