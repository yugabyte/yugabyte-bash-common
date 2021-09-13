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

[[ "${_YB_CREATE_VENV_INCLUDED:=""}" == "yes" ]] && return 0
_YB_CREATE_VENV_INCLUDED=yes
VERBOSE=${VERBOSE:-false}

set -e -u -o pipefail

DIR="${BASH_SOURCE%/*}"
if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi
# shellcheck disable=SC1091,SC1090
. "${DIR}"/logger.sh
# shellcheck disable=SC1091,SC1090
. "${DIR}"/os.sh
# shellcheck disable=SC1091,SC1090
. "${DIR}"/detect_python.sh

# -------------------------------------------------------------------------------------------------
# Global variables used in this module
# -------------------------------------------------------------------------------------------------
# This preserves the current existing behavior of assuming requirements_frozen.txt is always
# up to date.  TODO: default this to true to ensure frozen file is 'correct'
YB_BUILD_STRICT=${YB_BUILD_STRICT:-false}
# Set this to true to force recreation of requirements_frozen.txt
YB_RECREATE_VIRTUALENV=${YB_RECREATE_VIRTUALENV:-false}
# New-style VENV base dir, only used when YB_USE_TOP_LEVEL_VENV is false
YB_VENV_BASE_DIR=${YB_VENV_BASE_DIR:-~/.venv/yb}
# This preserves the current existing behavior of putting the VENV in the same dirextory
# as requirements.txt
YB_USE_TOP_LEVEL_VENV=${YB_USE_TOP_LEVEL_VENV:-true}

verbose "Using YB_PYTHON_VERSION=${YB_PYTHON_VERSION}"
# shellcheck disable=SC2154
verbose "Using ${yb_python_interpreter} (${yb_python_version_actual})"

# -------------------------------------------------------------------------------------------------
# Internal functions used in this module.  These shouldn't be called directly outside this module.
# -------------------------------------------------------------------------------------------------

function text_file_sha() {
  local file="${1}"
  local tmp
  tmp="$(sort -u <<<"$(grep -v '^#' "${file}")")"
  # shellcheck disable=SC2154
  awk '{print $1}'<<<"$(${yb_sha256sum} <<<"${tmp}")"
}

function needs_refreeze() {
  local reqs_sha="${1}"
  local frzn_file="${2}"
  local refreeze
  refreeze=$(false)
  if [[ -f "${frzn_file}" ]]; then
    if ! grep "# YB_SHA: ${reqs_sha}" "${frzn_file}" >/dev/null 2>&1; then
      refreeze=$(true)
    fi
  else
    refreeze=$(true)
  fi
  # shellcheck disable=SC2086
  return ${refreeze}
}


# -------------------------------------------------------------------------------------------------
# Main functions
# -------------------------------------------------------------------------------------------------
function yb_deactivate_virtualenv() {
  if [[ -n ${VIRTUAL_ENV:-} && -f "$VIRTUAL_ENV/bin/activate" ]]; then
    set +u
    # The "deactivate" function is defined by virtualenv's "activate" script.
    deactivate
    set -u

    unset PYTHONPATH
  fi
}

# Arguments:
#   - Parent directory of the virtualenv
#   - Python interpreter to use (optional)
function yb_activate_virtualenv() {

  local root_dir=${1}
  local reqs_file="${root_dir}/requirements.txt"
  local frzn_file="${root_dir}/requirements_frozen.txt"

  verbose "Using root_dir=${root_dir}"
  verbose "Using reqs_file=${reqs_file}"

  # Include the OS and h/w arch.  This allows to use a VM or container with a shared persistent
  # externally mounted YB_VENV_BASE_DIR
  local unique_input
  unique_input="$(uname -s)$(uname -m)${yb_python_version_actual}"
  local refreeze=false
  if [[ -f "${reqs_file}" ]]; then
    local reqs_sha
    reqs_sha="$(text_file_sha "${reqs_file}")"
    unique_input="${unique_input}$(sort -u "${reqs_file}")"
    if needs_refreeze "${reqs_sha}" "${frzn_file}"; then
      if ${YB_BUILD_STRICT}; then
        echo "YB_BUILD_STRICT: ${frzn_file} is out of date or doesn't exist and YB_BUILD_STRICT is true"
        # shellcheck disable=SC2046
        return $(false)
      fi
      refreeze=true
    else
      reqs_file="${frzn_file}"
      unique_input="${unique_input}$(sort -u "${frzn_file}")"
    fi
  else
    echo "WARNING: No requirements.txt file found!"
  fi
  
  # By default we create a unique VENV dir based on a combination of python version, OS, arch,
  # and the non-comment contents of the requirements.txt file.  If YB_USE_TOP_LEVEL_VENV is set
  # true we fall back to the older behaviour of using a directory called 'venv' in the same
  # directory that contains the requirements.txt file.  It is possible for this older style venv
  # dir to go out of date in a way that is hard to detect.
  local venv_dir=''
  if ${YB_USE_TOP_LEVEL_VENV}; then
    venv_dir="$root_dir/venv"
  else
    local unique_sha
    unique_sha=$(sha256sum - <<<"${unique_input}"| awk '{print $1}')
    venv_dir="${YB_VENV_BASE_DIR}/${unique_sha}/$(basename "${root_dir}")-venv"
  fi

  verbose "Using venv_dir=${venv_dir}"

  if ! mkdir -p "${YB_VENV_BASE_DIR}"; then
    echo "Error creating YB_VENV_BASE_DIR '${YB_VENV_BASE_DIR}'"
    # shellcheck disable=SC2046
    return $(false)
  fi

  # Remove the venv, we want to ensure it is fresh
  if [[ "${YB_RECREATE_VIRTUALENV}" == 'true' ]]; then
    rm -rf "${venv_dir}"
  fi

  if [[ -d ${venv_dir} ]]; then
    verbose "Using existing venv"
  else
    verbose "Creating new venv"
    local create_cmd=''
    # shellcheck disable=SC2154
    case "${py_major_version}" in
      2) # python2 instalations don't always include pip
        "${yb_python_interpreter}" -m pip install virtualenv --user >/dev/null 2>&1
        create_cmd="${yb_python_interpreter} -m virtualenv"
        ;;
      3)
        create_cmd="${yb_python_interpreter} -m venv"
        ;;
      *)
        echo "Error determining venv creation command"
        echo "Unknown python major version: '${py_major_version}'"
        # shellcheck disable=SC2046
        return $(false)
        ;;
    esac
    if ! ${create_cmd} "${venv_dir}"; then
      echo "Error creating venv!"
      # shellcheck disable=SC2046
      return $(false)
    fi
  fi

  # shellcheck source=/dev/null
  source "${venv_dir}/bin/activate"
  ## Update pip to latest
  if ! out=$(pip install --upgrade pip 2>&1); then
    warn "Error installing pip!\n${out}"
    # shellcheck disable=SC2046
    return $(false)
  fi
  if [[ -f "${reqs_file}" ]]; then
    verbose "Installing ${reqs_file}"
    if ! out=$(pip install -r "${reqs_file}" 2>&1); then
      warn "Error installing requirements from ${reqs_file}!\n${out}"
      # shellcheck disable=SC2046
      return $(false)
    fi
  fi

  verbose "${out}"

  if ${refreeze}; then
    verbose "Recreating ${frzn_file}"
    echo "# YB_SHA: ${reqs_sha}" > "${frzn_file}"
    pip freeze >> "${frzn_file}"
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  yb_activate_virtualenv "${1:-$(pwd)}" || exit 1
  echo "source '${VIRTUAL_ENV}/bin/activate'"
fi
