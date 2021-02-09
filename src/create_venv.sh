#!/usr/bin/env bash


# Use SHA of requirements.txt as a comment in requirements_frozen.txt
# 

function text_file_sha() {
  local file="${1}"
  local tmp
  tmp="$(sort -u <<<"$(grep -v '^#' "${file}")")"
  awk '{print $1}'<<<"$(sha256sum <<<"${tmp}")"
}

set -e -u -o pipefail

YB_PYTHON_VERSION=${YB_PYTHON_VERSION:-3.7}
py_major_version=$(cut -f1 -d. <<<"${YB_PYTHON_VERSION}")

YB_VENV_BASE_DIR=${YB_VENV_BASE_DIR:-~/.venv/yb}
YB_RECREATE_VIRTUALENV=${YB_RECREATE_VIRTUALENV:-false}

VERBOSE=${VERBOSE:-false}

echo "Using YB_PYTHON_VERSION=${YB_PYTHON_VERSION}"

set +u
if [[ -n "${VIRTUAL_ENV}" ]] && [[ -d "${VIRTUAL_ENV}" ]]; then
  echo "Please exit your current venv first."
  echo "type 'deactivate' in your shell"
  exit 1
fi
set -u

py_cmd=''
for cmd in "python${YB_PYTHON_VERSION}" "python${py_major_version}" "python"; do
  if cmd="$(command -v "${cmd}")"; then
    if "${cmd}" --version 2>&1 | grep "${YB_PYTHON_VERSION}"; then
      py_cmd="${cmd}"
      break
    fi
  fi
done

if [[ -z "${py_cmd}" ]]; then
  echo "No python executable found matching ${YB_PYTHON_VERSION}"
  exit 1
fi

py_version=$(${py_cmd} --version 2>&1 | awk '{print $2}')

echo "Using ${py_cmd} (${py_version})"

root_dir=${1:-$(pwd)}
reqs_file="${root_dir}/requirements.txt"
frzn_file="${root_dir}/requirements_frozen.txt"

echo "Using root_dir=${root_dir}"
echo "Using reqs_file=${reqs_file}"

# Include the OS and h/w arch.  This allows to use a VM or container with a shared persistent
# externally mounted YB_VENV_BASE_DIR
unique_input="$(uname -s)$(uname -m)${py_cmd}"
if [[ ! -f "${reqs_file}" ]]; then
  echo "WARNING: No requirements.txt file found!"
  exit 1
fi
reqs_sha="$(text_file_sha "${reqs_file}")"

unique_input="${unique_input}$(sort -u "${reqs_file}")"

refreeze=false
if [[ -f "${frzn_file}" ]]; then
  unique_input="${unique_input}$(sort -u "${frzn_file}")"
  if ! grep "# YB_SHA: ${reqs_sha}" "${frzn_file}" >/dev/null 2>&1; then
    refreeze=true
  else
    reqs_file="${frzn_file}"
  fi
else
  refreeze=true
fi

unique_sha=$(sha256sum - <<<"${unique_input}"| awk '{print $1}')
venv_dir="${YB_VENV_BASE_DIR}/${unique_sha}/$(basename ${root_dir})-venv"

echo "Using venv_dir=${venv_dir}"

if ! mkdir -p "${YB_VENV_BASE_DIR}"; then
  echo "Error creating YB_VENV_BASE_DIR '${YB_VENV_BASE_DIR}'"
  exit 1
fi

# Remove the venv, we want to ensure it is fresh
if [[ "${YB_RECREATE_VIRTUALENV}" == 'true' ]]; then
  rm -rf "${venv_dir}"
fi

if [[ -d ${venv_dir} ]]; then
  echo "Using existing venv"
else
  echo "Creating new venv"
  case "${py_major_version}" in
    2)
      "${py_cmd}" -m pip install virtualenv --user
      create_cmd="${py_cmd} -m virtualenv"
      ;;
    3)
      create_cmd="${py_cmd} -m venv"
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
echo "Installing ${reqs_file}"
if ! out=$(pip install -r "${reqs_file}" 2>&1); then
  echo "Error installing requirements from requirements.txt!"
  echo -e "${out}"
  exit 1
fi

if [[ "${refreeze}" == "true" ]]; then
  echo "Recreating ${frzn_file}"
  echo "# YB_SHA: ${reqs_sha}" > "${frzn_file}"
  pip freeze >> "${frzn_file}"
fi

echo "source '${venv_dir}/bin/activate'"
