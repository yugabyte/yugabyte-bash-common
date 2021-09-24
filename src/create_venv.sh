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
YB_VERBOSE=${YB_VERBOSE:-false}

set -e -u -o pipefail

_src_dir="${BASH_SOURCE%/*}"
if [[ ! -d "${_src_dir}" ]]; then _src_dir="$PWD"; fi
# shellcheck disable=SC1091,SC1090
. "${_src_dir}"/logger.sh
# shellcheck disable=SC1091,SC1090
. "${_src_dir}"/os.sh
# shellcheck disable=SC1091,SC1090
. "${_src_dir}"/detect_python.sh

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
  local file=$1
  local tmp
  tmp="$(sort -u <<<"$(grep -v '^#' "${file}")")"
  # shellcheck disable=SC2154
  awk '{print $1}'<<<"$(${yb_sha256sum} <<<"${tmp}")"
}

function needs_refreeze() {
  local reqs_sha=$1
  local frozen_file=$2
  if [[ -f "${frozen_file}" ]]; then
    if ! grep "# YB_SHA: ${reqs_sha}" "${frozen_file}" >/dev/null 2>&1; then
      return 0
    fi
  else
    return 0
  fi
  # shellcheck disable=SC2086
  false
}

# Recreate the venv if the python if it was created with a different version of python
function venv_needs_recreation() {
  local venv_dir=$1
  [[ -f "${venv_dir}/bin/activate" ]] \
    && [[ "$(run_python --version)" != "$(source "${venv_dir}/bin/activate" && python --version)" ]]
}


# This returns true if venv is generally useable but maybe not be up to date
# e.g. a new module has been installed since creation
function venv_needs_refresh() {
  local venv_dir=$1
  local unique_sha=$2

  # First check that no files are newer than our special sentry file
  # Get the most recently modified file under the venv
  local most_recent_file
  most_recent_file=$(find "${venv_dir}" -type f -print0 \
                     | xargs -0 stat --format '%Y :%y %n' \
                     | sort -nr \
                     | cut -d' ' -f5- \
                     | head -1)
  if [[ "${most_recent_file}" == "${venv_dir}/YB_VENV_SHA" ]]; then
    # no modifications to venv since creation, check the SHA to ensure it was created with the
    # correct requirements.txt and frozen_requirements.txt
    if [[ "${unique_sha}" == "$(cat "${venv_dir}/YB_VENV_SHA")" ]]; then
      verbose "Existing venv is current and will be used as is."
      return 1
    fi
  fi
  verbose "The venv needs refreshing"
  true
}

# -------------------------------------------------------------------------------------------------
# Main functions
# -------------------------------------------------------------------------------------------------
function yb_deactivate_virtualenv() {
  # shellcheck disable=SC2031
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
  local frozen_file="${root_dir}/requirements_frozen.txt"

  # Allow the caller to optionally pass in a venv path to use instead of trying to calculate it
  # This is to support the use case in yugabyte-db:yb_build.sh
  local venv_dir=${2:-}
  # By default we create a unique VENV dir based on a combination of python version, OS, arch,
  # and the non-comment contents of the requirements.txt file.  If YB_USE_TOP_LEVEL_VENV is set
  # true we fall back to the older behaviour of using a directory called 'venv' in the same
  # directory that contains the requirements.txt file.  It is possible for this older style venv
  # dir to go out of date in a way that is hard to detect.
  # Include the OS and h/w arch.  This allows to use a VM or container with a shared persistent
  # externally mounted YB_VENV_BASE_DIR
  local unique_input
  unique_input="$(uname -s)$(uname -m)${yb_python_version_actual}"
  local refreeze=false
  if [[ -f "${reqs_file}" ]]; then
    local reqs_sha
    reqs_sha="$(text_file_sha "${reqs_file}")"
    unique_input="${unique_input}$(sort -u "${reqs_file}")"
    if needs_refreeze "${reqs_sha}" "${frozen_file}"; then
      if ${YB_BUILD_STRICT}; then
        warn "YB_BUILD_STRICT: ${frozen_file} is out of date or doesn't exist and YB_BUILD_STRICT is true"
        # shellcheck disable=SC2046
        return 1
      fi
      refreeze=true
    else
      reqs_file="${frozen_file}"
      unique_input="${unique_input}$(sort -u "${frozen_file}")"
    fi
  else
    warn "WARNING: No requirements.txt file found!"
  fi

  local unique_sha
  unique_sha=$(sha256sum - <<<"${unique_input}"| awk '{print $1}')

  if [[ -z $venv_dir ]]; then
    if ${YB_USE_TOP_LEVEL_VENV}; then
      venv_dir="$root_dir/venv"
    else
      # This setup allows us switch to branches and then reuse an existing venv created in the past.
      venv_dir="${YB_VENV_BASE_DIR}/${unique_sha}/$(basename "${root_dir}")-venv"
    fi
  fi

  verbose "Using root_dir=${root_dir}"
  verbose "Using reqs_file=${reqs_file}"
  verbose "Using venv_dir=${venv_dir}"

  if ! ${YB_USE_TOP_LEVEL_VENV}; then
    if ! mkdir -p "${YB_VENV_BASE_DIR}"; then
      warn "Error creating YB_VENV_BASE_DIR '${YB_VENV_BASE_DIR}'"
      return 1
    fi
  fi

  # Remove the venv, we want to ensure it is fresh
  if [[ "${YB_RECREATE_VIRTUALENV}" == 'true' ]] || venv_needs_recreation "${venv_dir}"; then
    rm -rf "${venv_dir}"
  fi

  # The venv was modifed after creation OR it was created with a different requirements.txt file
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
        warn "Error determining venv creation command"
        warn "Unknown python major version: '${py_major_version}'"
        return 1
        ;;
    esac
    if ! ${create_cmd} "${venv_dir}"; then
      warn "Error creating venv!"
      return 1
    fi
  fi

  # shellcheck source=/dev/null
  if ! source "${venv_dir}/bin/activate"; then
    fatal "venv at ${venv_dir} failed to activate!"
  fi
  if venv_needs_refresh "${venv_dir}" "${unique_sha}"; then
    verbose "Update pip to the latest version"
    ## Update pip to latest
    if ! out=$(pip install --upgrade pip 2>&1); then
      warn "Error installing pip!\n${out}"
      # shellcheck disable=SC2046
      return 1
    fi
    if [[ -f "${reqs_file}" ]]; then
      verbose "Installing ${reqs_file}"
      if ! out=$(pip install -r "${reqs_file}" 2>&1); then
        warn "Error installing requirements from ${reqs_file}!\n${out}"
        # shellcheck disable=SC2046
        return 1
      fi
    fi

    echo "${unique_sha}" > "${venv_dir}/YB_VENV_SHA"

    verbose "${out}"

    if ${refreeze}; then
      verbose "Recreating ${frozen_file}"
      echo "# YB_SHA: ${reqs_sha}" > "${frozen_file}"
      pip freeze >> "${frozen_file}"
    fi
  fi

}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  yb_activate_virtualenv "${@:1}" || exit 1
  log "To use this venv run the following: source '${VIRTUAL_ENV}/bin/activate'"
fi
