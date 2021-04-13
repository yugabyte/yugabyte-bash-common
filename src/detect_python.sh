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

[[ "${_YB_DETECT_PYTHON_SHLIB:=""}" == "yes" ]] && return 0
_YB_DETECT_PYTHON_SHLIB=yes

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "${BASH_SOURCE[0]} must be sourced, not executed" >&2
  exit 1
fi

readonly YB_PYTHON_VERSION=${YB_PYTHON_VERSION:-3.7}
#export YB_PYTHON_VERSION
readonly py_major_version=$(cut -f1 -d. <<<"${YB_PYTHON_VERSION}")
#export py_major_version
yb_python_interpreter=''
for cmd in "python${YB_PYTHON_VERSION}" "python${py_major_version}" "python"; do
  if cmd="$(command -v "${cmd}")"; then
    if "${cmd}" --version 2>&1 | grep "${YB_PYTHON_VERSION}" >/dev/null 2>&1; then
      yb_python_interpreter="${cmd}"
      break
    fi
  fi
done
if [[ -z "${yb_python_interpreter}" ]]; then
  echo "No python executable found matching ${YB_PYTHON_VERSION}"
  exit 1
fi
readonly yb_python_interpreter
