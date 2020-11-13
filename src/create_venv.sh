#!/usr/bin/env bash


# Use SHA of requirements.txt as a comment in requirements_frozen.txt
# 

set -e -u -o pipefail

YB_PYTHON_VERSION=${YB_PYTHON_VERSION:-3.7}
py_major_version=$(cut -f1 -d. <<<"${YB_PYTHON_VERSION}")

YB_VENV_BASE_DIR=${YB_VENV_BASE_DIR:-~/.venv/yb}
YB_REFRESH_VENV=${YB_REFRESH_VENV:-false}

echo "Using YB_PYTHON_VERSION=${YB_PYTHON_VERSION}"

set +u
if [[ -n "${VIRTUAL_ENV}" ]] && [[ -d "${VIRTUAL_ENV}" ]]; then
  echo "Please exit your current venv first."
  echo "type 'deactivate' in your shell"
  exit 1
fi
set -u

py_cmd=''
if which python${YB_PYTHON_VERSION} > /dev/null 2>&1; then
  py_cmd=$(which python${YB_PYTHON_VERSION})
else
  if python --version | grep ${YB_PYTHON_VERSION}; then
    py_cmd=$(which python)
  fi
fi

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

unique_input="${unique_input}$(sort -u ${reqs_file})"

if [[ -f ${frzn_file} ]]; then
  unique_input="${unique_input}$(sort -u ${frzn_file})"
fi

venv_dir="${YB_VENV_BASE_DIR}/$(sha256sum - <<<${unique_input}| awk '{print $1}')/YB_VENV"

echo "Using venv_dir=${venv_dir}"

if ! mkdir -p ${YB_VENV_BASE_DIR}; then
  echo "Error creating YB_VENV_BASE_DIR '${YB_VENV_BASE_DIR}'"
  exit 1
fi

# Remove the venv, we want to ensure it is fresh
if [[ "${YB_REFRESH_VENV}" == 'true' ]]; then
  rm -rf "${venv_dir}"
fi

if [[ -d ${venv_dir} ]]; then
  echo "Using existing venv"
else
  echo "Creating new venv"
  if ! "${py_cmd}" -m venv "${venv_dir}"; then
    echo "Error creating venv!"
    exit 1
  fi
fi

source "${venv_dir}/bin/activate"
## Update pip to latest
pip install --upgrade pip
echo "Installing requirements.txt"
if ! out=$(pip install -r "${reqs_file}" 2>&1); then
  echo "Error installing requirements from requirements.txt!"
  echo -e "${out}"
fi

echo "source '${venv_dir}/bin/activate'"
