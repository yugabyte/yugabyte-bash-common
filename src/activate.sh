#!/usr/bin/env bash
set -euo pipefail

if [[ $BASH_SOURCE == $0 ]]; then
  echo "$BASH_SOURCE must be sourced, not executed" >&2
  exit 1
fi

YB_BASH_COMMON_ROOT=$( cd "${BASH_SOURCE/*}" && cd .. && pwd )

yb_log_lite() {
  echo >&2 "[$( date +%Y-%m-%dT%H:%M:%S )] $*"
}

# Checks out the version of the yugabyte-bash-common repository defined by the
# YB_BASH_COMMON_VERSION environment variable.
yb_bash_common_set_version() {
  if [[ -z ${YB_BASH_COMMON_VERSION:-} ]]; then
    return
  fi
  pushd "$YB_BASH_COMMON_ROOT"
  local ref=$YB_BASH_COMMON_VERSION
  if ! git diff --queit "$ref"; then
    yb_log_lite "Trying to check out ref '$ref' in $PWD"
    if ! git checkout "$ref"; then
      yb_log_lite "Trying to fetch the 'origin' remote and then check out ref '$ref' in $PWD"
      git fetch origin
      # If this fails, we bail out.
      git checkout "$YB_BASH_COMMON_VERSION"
    fi
  fi
  popd
}

yb_bash_common_set_version
unset -f yb_bash_common_set_version

# Now that we've ensured that the version of yugabyte-bash-common we're using is the correct one,
# let's source it into the current shell.
. "$YB_BASH_COMMON_ROOT/src/common.sh"
