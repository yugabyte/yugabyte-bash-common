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

[[ "${_YB_CREATE_VENV_INCLUDED:-}" == "true" ]] && return 0
_YB_CREATE_VENV_INCLUDED="true"

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

# This preserves the legacy behavior as of 2/16/2022 of assuming requirements_frozen.txt is
# always up to date.
# TODO: default this to true to ensure frozen file is 'correct' before using it.
YB_BUILD_STRICT=${YB_BUILD_STRICT:-false}

# Set this to true to force recreation of requirements_frozen.txt.
YB_RECREATE_VIRTUALENV=${YB_RECREATE_VIRTUALENV:-false}

# New-style VENV base dir, only used when YB_PUT_VENV_IN_PROJECT_DIR is false.
YB_VENV_BASE_DIR=${YB_VENV_BASE_DIR:-~/.venv/yb}

# This preserves the current existing behavior of putting the VENV in the same directory
# as requirements.txt
YB_PUT_VENV_IN_PROJECT_DIR=${YB_PUT_VENV_IN_PROJECT_DIR:-true}

yb::verbose_log "Using YB_PYTHON_VERSION=${YB_PYTHON_VERSION}"
# shellcheck disable=SC2154
yb::verbose_log "Using ${yb_python_interpreter} (${yb_python_version_actual})"

# -------------------------------------------------------------------------------------------------
# Internal functions used in this module.  These shouldn't be called directly outside this module.
# -------------------------------------------------------------------------------------------------

function yb::venv::text_file_sha_ignore_comments() {
  local file=$1
  local tmp
  tmp="$(sort -u <<<"$(grep -Ev '^[[:space:]]*#' "${file}")")"
  # shellcheck disable=SC2154
  awk '{print $1}'<<<"$(${yb_sha256sum} <<<"${tmp}")"
}

function yb::venv::needs_refreeze() {
  local reqs_sha=$1
  local frozen_file=$2
  if [[ -f "${frozen_file}" ]]; then
    if ! grep "# YB_SHA: ${reqs_sha}" "${frozen_file}" >/dev/null 2>&1; then
      yb::verbose_log "Refreezing '${frozen_file}', missing YB_SHA"
      return 0
    fi
  else
    yb::verbose_log "Frozen file doesn't exist at '${frozen_file}', refreezing"
    return 0
  fi
  yb::verbose_log "Frozen file is up to date"
  return 1
}

# Recreate the venv if the python if it was created with a different version of python.
function yb::venv::venv_needs_recreation() {
  local venv_dir=$1
  # shellcheck disable=SC1091,SC1090
  [[ -f "${venv_dir}/bin/activate" ]] \
    && [[ "$(run_python --version)" != "$(source "${venv_dir}/bin/activate" && python --version)" ]]
}


# This returns true if venv is generally usable but maybe not be up to date
# e.g. a new module has been installed since creation.
function yb::venv::needs_refresh() {
  local venv_dir=$1
  local unique_sha=$2

  # First check that no files are newer than our special sentry file.
  # Get the most recently modified file under the venv.
  # Taken from https://mywiki.wooledge.org/BashFAQ/099.
  local most_recent_file
  local files
  # shellcheck disable=SC2206
  files=(${venv_dir}/*)
  most_recent_file=${files[0]}
  for f in "${files[@]}"; do
    if [[ $f -nt $most_recent_file ]]; then
      most_recent_file=$f
    fi
  done
  if [[ "${most_recent_file}" == "${venv_dir}/YB_VENV_SHA" ]]; then
    # no modifications to venv since creation, check the SHA to ensure it was created with the
    # correct requirements.txt and frozen_requirements.txt.
    if [[ "${unique_sha}" == "$(cat "${venv_dir}/YB_VENV_SHA")" ]]; then
      yb::verbose_log "Existing venv is current and will be used as is."
      return 1
    fi
  fi
  yb::verbose_log "The venv needs refreshing"
  return 0
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
#   - Directory containing the requirements.txt file
#   - Venv directory (optional)
function yb_activate_virtualenv() {
  # Expand the path here, we don't want it to be ".".
  local root_dir
  root_dir=$(realpath "${1}")
  local reqs_file="${root_dir}/requirements.txt"
  local frozen_file="${root_dir}/requirements_frozen.txt"

  # Allow the caller to optionally pass in a venv path to use instead of trying to calculate it.
  # Used in https://github.com/yugabyte/yugabyte-db/blob/master/yb_build.sh.
  local venv_dir=${2:-}
  # By default we create a directory called 'venv' in the same directory that contains the 
  # requirements.txt file.
  # By setting YB_PUT_VENV_IN_PROJECT_DIR=false, a unique VENV dir based on a combination of python
  # version, OS, arch, and the non-comment contents of the requirements_frozen.txt file (or 
  # requirements.txt if there is no frozen file).
  # Include the OS and h/w arch.  This allows to use a VM or container with a shared persistent
  # externally mounted YB_VENV_BASE_DIR.
  local unique_input
  unique_input="$(uname -s)$(uname -m)${yb_python_version_actual}"
  local refreeze=false
  if [[ -f "${reqs_file}" ]]; then
    local reqs_sha
    reqs_sha="$(yb::venv::text_file_sha_ignore_comments "${reqs_file}")"
    unique_input="${unique_input}$(sort -u "${reqs_file}")"
    if yb::venv::needs_refreeze "${reqs_sha}" "${frozen_file}"; then
      if [[ "${YB_BUILD_STRICT}" == "true" ]]; then
        warn "YB_BUILD_STRICT: ${frozen_file} is out of date or doesn't exist and YB_BUILD_STRICT is true"
        # shellcheck disable=SC2046
        return 1
      fi
      yb::verbose_log "Setting refreeze to true"
      refreeze=true
    else
      reqs_file="${frozen_file}"
      unique_input="${unique_input}$(sort -u "${frozen_file}")"
    fi
  else
    warn "WARNING: No requirements.txt file found in '${root_dir}'!"
  fi

  local unique_sha
  unique_sha=$(${yb_sha256sum} - <<<"${unique_input}"| awk '{print $1}')

  if [[ -z $venv_dir ]]; then
    if ${YB_PUT_VENV_IN_PROJECT_DIR}; then
      venv_dir="$root_dir/venv"
    else
      # This setup allows us switch branches and then reuse an existing venv created in the past.
      venv_dir="${YB_VENV_BASE_DIR}/${unique_sha}/$(basename "${root_dir}")-venv"
    fi
  fi

  yb::verbose_log "Using root_dir=${root_dir}"
  yb::verbose_log "Using reqs_file=${reqs_file}"
  yb::verbose_log "Using venv_dir=${venv_dir}"

  if ! ${YB_PUT_VENV_IN_PROJECT_DIR}; then
    if ! mkdir -p "${YB_VENV_BASE_DIR}"; then
      warn "Error creating YB_VENV_BASE_DIR '${YB_VENV_BASE_DIR}'"
      return 1
    fi
  fi

  # Remove the venv, we want to ensure it is fresh.
  if [[ "${YB_RECREATE_VIRTUALENV}" == 'true' ]] || yb::venv::venv_needs_recreation "${venv_dir}"; then
    rm -rf "${venv_dir}"
  fi

  # The venv was modifed after creation OR it was created with a different requirements.txt file.
  if [[ -d ${venv_dir} ]]; then
    yb::verbose_log "Using existing venv"
  else
    yb::verbose_log "Creating new venv"
    local create_cmd=''
    # shellcheck disable=SC2154
    case "${py_major_version}" in
      2) # python2 instalations don't always include pip.
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

  if yb::venv::needs_refresh "${venv_dir}" "${unique_sha}"; then
    yb::verbose_log "Update pip to the latest version"
    ## Update pip to latest.
    if ! out=$(pip install --upgrade pip 2>&1); then
      warn "Error installing pip!\n${out}"
      # shellcheck disable=SC2046
      return 1
    fi
    if [[ -f "${reqs_file}" ]]; then
      yb::verbose_log "Installing ${reqs_file}"
      if ! out=$(pip install -r "${reqs_file}" 2>&1); then
        warn "Error installing requirements from ${reqs_file}!\n${out}"
        # shellcheck disable=SC2046
        return 1
      fi
    fi

    echo "${unique_sha}" > "${venv_dir}/YB_VENV_SHA"

    yb::verbose_log "${out}"

    if [[ "${refreeze}" == "true" ]]; then
      yb::verbose_log "Recreating ${frozen_file}"
      echo "# YB_SHA: ${reqs_sha}" > "${frozen_file}"
      pip freeze >> "${frozen_file}"
    fi
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  yb_activate_virtualenv "${1:-$(pwd)}" || exit 1
  log "To use this venv run the following: source '${VIRTUAL_ENV}/bin/activate'"
fi
