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

[[ "${_YB_CREATE_VENV_SHLIB:=""}" == "yes" ]] && return 0
_YB_CREATE_VENV_SHLIB=yes

set -e -u -o pipefail

DIR="${BASH_SOURCE%/*}"
if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi
. "${DIR}"/detect_python.sh

function text_file_sha() {
  local file="${1}"
  local tmp
  tmp="$(sort -u <<<"$(grep -v '^#' "${file}")")"
  awk '{print $1}'<<<"$(sha256sum <<<"${tmp}")"
}

function verbose() {
  # Print our info messages to stderr and only when asked (VERBOSE=true).
  local msg="$@"
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e "${msg}" >&2
  fi
}

function needs_refreeze() {
  local reqs_sha="${1}"
  local frzn_file="${2}"
  local refreeze=`false`
  if [[ -f "${frzn_file}" ]]; then
    if ! grep "# YB_SHA: ${reqs_sha}" "${frzn_file}" >/dev/null 2>&1; then
      refreeze=`true`
    fi
  else
    refreeze=`true`
  fi
  return ${refreeze}
}

YB_BUILD_STRICT=${YB_BUILD_STRICT:-false}
YB_RECREATE_VIRTUALENV=${YB_RECREATE_VIRTUALENV:-false}
YB_VENV_BASE_DIR=${YB_VENV_BASE_DIR:-~/.venv/yb}

VERBOSE=${VERBOSE:-false}

verbose "Using YB_PYTHON_VERSION=${YB_PYTHON_VERSION}"

py_version=$(${yb_python_interpreter} --version 2>&1 | awk '{print $2}')

verbose "Using ${yb_python_interpreter} (${py_version})"

root_dir=${1:-$(pwd)}
reqs_file="${root_dir}/requirements.txt"
frzn_file="${root_dir}/requirements_frozen.txt"

verbose "Using root_dir=${root_dir}"
verbose "Using reqs_file=${reqs_file}"

# Include the OS and h/w arch.  This allows to use a VM or container with a shared persistent
# externally mounted YB_VENV_BASE_DIR
unique_input="$(uname -s)$(uname -m)${py_version}"
if [[ ! -f "${reqs_file}" ]]; then
  echo "WARNING: No requirements.txt file found!"
  exit 1
fi
reqs_sha="$(text_file_sha "${reqs_file}")"

unique_input="${unique_input}$(sort -u "${reqs_file}")"

refreeze=false
if needs_refreeze "${reqs_sha}" "${frzn_file}"; then
  if ${YB_BUILD_STRICT}; then
    echo "YB_BUILD_STRICT: ${frzn_file} is out of date or doesn't exist and YB_BUILD_STRICT is true"
    exit 1
  fi
  refreeze=true
else
  reqs_file="${frzn_file}"
  unique_input="${unique_input}$(sort -u "${frzn_file}")"
fi

unique_sha=$(sha256sum - <<<"${unique_input}"| awk '{print $1}')
venv_dir="${YB_VENV_BASE_DIR}/${unique_sha}/$(basename ${root_dir})-venv"

verbose "Using venv_dir=${venv_dir}"

if ! mkdir -p "${YB_VENV_BASE_DIR}"; then
  echo "Error creating YB_VENV_BASE_DIR '${YB_VENV_BASE_DIR}'"
  exit 1
fi

# Remove the venv, we want to ensure it is fresh
if [[ "${YB_RECREATE_VIRTUALENV}" == 'true' ]]; then
  rm -rf "${venv_dir}"
fi

if [[ -d ${venv_dir} ]]; then
  verbose "Using existing venv"
else
  verbose "Creating new venv"
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
      exit 1
      ;;
  esac
  if ! ${create_cmd} "${venv_dir}"; then
    echo "Error creating venv!"
    exit 1
  fi
fi

# shellcheck source=/dev/null
source "${venv_dir}/bin/activate"
## Update pip to latest
pip install --upgrade pip
verbose "Installing ${reqs_file}"
if ! out=$(pip install -r "${reqs_file}" 2>&1); then
  echo "Error installing requirements from ${reqs_file}!"
  echo -e "${out}"
  exit 1
fi

verbose "${out}"

if ${refreeze}; then
  verbose "Recreating ${frzn_file}"
  echo "# YB_SHA: ${reqs_sha}" > "${frzn_file}"
  pip freeze >> "${frzn_file}"
fi

echo "source '${venv_dir}/bin/activate'"
