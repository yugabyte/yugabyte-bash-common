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

# -------------------------------------------------------------------------------------------------
# OS, CPU count, and cloud environment detection
# -------------------------------------------------------------------------------------------------

[[ "${_YB_OS_INCLUDED:-}" == "true" ]] && return 0
_YB_OS_INCLUDED=true

# -------------------------------------------------------------------------------------------------
# functions
# -------------------------------------------------------------------------------------------------


detect_num_cpus() {
  if [[ ! ${YB_NUM_CPUS:-} =~ ^[0-9]+$ ]]; then
    if is_linux; then
      YB_NUM_CPUS=$(nproc)
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

# We don't want to detect the OS more than once.
yb_os_detected=false
detect_os() {
  if "$yb_os_detected"; then
    return
  fi
  is_mac=false
  is_linux=false
  is_debian=false
  is_ubuntu=false
  is_centos=false
  is_alma=false
  is_rhel=false
  short_os_name="unknown_os"

  case $OSTYPE in
    darwin*)
      # shellcheck disable=SC2034
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
    if [[ -f /etc/os-release ]]; then
      short_os_name=$(grep '^ID=' /etc/os-release | cut -d= -f2 | sed -e 's/^"//' -e 's/"$//')
      case "${short_os_name}" in
        'ubuntu')
          is_ubuntu=true
          is_debian=true
          ;;
        'debian')
          is_debian=true
          ;;
        'centos')
          is_centos=true
          ;;
        'almalinux')
          is_alma=true
          ;;
        'rhel')
          is_rhel=true
          ;;
        *)
          warn "${short_os_name} is not a supported Linux distribution"
          ;;
      esac
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

is_alma() {
  [[ $is_alma == "true" ]]
}

is_rhel() {
  [[ $is_rhel == "true" ]]
}

is_redhat_family() {
  [[ $is_rhel == "true" || $is_centos == "true" ||  $is_alma == "true" ]]
}

is_ubuntu() {
  [[ $is_ubuntu == "true" ]]
}

is_debian() {
  [[ $is_debian == "true" ]]
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
# create some OS independant variables for things like sha256sums
# -------------------------------------------------------------------------------------------------
yb_sha256sum='sha256sum'
if [[ $OSTYPE =~ darwin ]]; then
  yb_sha256sum='shasum --binary --algorithm 256'
fi
# shellcheck disable=SC2034
readonly yb_sha256sum
