# yugabyte-bash-common

[![CI](https://github.com/yugabyte/yugabyte-bash-common/workflows/CI/badge.svg)](https://github.com/yugabyte/yugabyte-bash-common/actions?query=workflow%3ACI)

A common set of functionality in Bash to be used across Yugabyte's repositories, e.g. as part of
build scripts, etc. Could also be used in other projects. As a rule, new scripts of any significant
complexity should be written in Python, not in Bash.

## Using this library in your project

### Using a submodule-like technique

Submodules might make switching branches more difficult. Here is how to import yugabyte-bash-common in a project using a submodule-style mechanism without actually creating a submodule.

Create a file: yugabyte-bash-common-sha1.txt with the SHA1 of the target commit of the yugabyte-bash-common repository that you want to use.

Create a script: `update-yugabyte-bash-common.sh`. The script assumes that is it in the root directory of the project but it could be placed in any directory, as long as the paths that it uses are updated accordingly.
```
#!/usr/bin/env bash

set -euo pipefail

project_dir=$( cd "${BASH_SOURCE[0]%/*}" && pwd )
set -euo pipefail

target_sha1=$(<"$project_dir/yugabyte-bash-common-sha1.txt")
if [[ ! $target_sha1 =~ ^[0-9a-f]{40}$ ]]; then
  echo >&2 "Invalid yugabyte-bash-common SHA1: $sha1"
  exit 1
fi
yugabyte_bash_common_dir=$project_dir/yugabyte-bash-common
if [[ ! -d $yugabyte_bash_common_dir ]]; then
  git clone https://github.com/yugabyte/yugabyte-bash-common.git "$yugabyte_bash_common_dir"
fi
cd "$yugabyte_bash_common_dir"
current_sha1=$( git rev-parse HEAD )
if [[ ! $current_sha1 =~ ^[0-9a-f]{40}$ ]]; then
  echo >&2 "Could not get current git SHA1 in $PWD"
  exit 1
fi
if [[ $current_sha1 != $target_sha1 ]]; then
  if ! ( set -x; git checkout "$target_sha1" ); then
    (
      set -x
      git fetch
      git checkout "$target_sha1"
    )
  fi
fi
```

### As a submodule
First, in another project's git repository:
```bash
git submodule add https://github.com/yugabyte/yugabyte-bash-common
```

Then in your shell script we recommend that you add a file called `common.sh` somewhere, and source
that file from all shell scripts in that repository. Then from `common.sh` you can import the
`yugabyte-bash-common` library itself. Replace `my_project` below with your project's name.

```bash
set -euo pipefail

if [[ $BASH_SOURCE == $0 ]]; then
  echo "$BASH_SOURCE must be sourced, not executed" >&2
  exit 1
fi

my_project_root=$( cd "${BASH_SOURCE%/*}" && cd .. && pwd )
if [[ ! -d $my_project_root/yugabyte-bash-common || 
      -z "$( ls -A "$my_project_root/yugabyte-bash-common" )" ]]; then
  ( cd "$my_project_root"; git submodule update --init --recursive )
fi

. "$my_project_root"/yugabyte-bash-common/src/yugabyte-bash-common.sh

```


## User-overridable variables

The `yb_python_interpeter` variable should be set to the default Python interpreter of your
project. It is prefereable to use Python 3 as Python 2.7 is going away in 2020,
e.g. `yb_python_interpeter=python3`. However, as of 03/2019 the default value of
`yb_python_interpeter` in this library is `python2.7`.

## Functions

### `yb_activate_virtualenv`

The `yb_activate_virtualenv` function takes one argument, the top-level directory containing
a `requirements.txt` or a `requirements_frozen.txt` file, and creates a virtual env called
`venv` in that directory in case it does not already exist. Then it installs Python module
described by `requirements_frozen.txt` (if exists) or `requirements.txt` into that `venv`
virtualenv.

For a repository containing just one top-level Python project it would usually be invoked
like this from a `common.sh` script:

```bash
# Assuming my_project_root is set as above
yb_activate_virtualenv "$my_project_root"
```

For multiple Python projects in one repository, this function could be invoked like so:

```bash
yb_activate_virtualenv "$my_project_root/python_project_foo"
```

In case the virtualenv is already present and up-to-date, this function is very fast, so
it could be invoked in wrapper scripts. E.g. suppose we have wrapper script `bin/my_tool`
for a Python tool whose source is located in `python/my_package/my_tool.py`. Then
the `bin/my_tool` wrapper script could be as follows:

```bash
#!/usr/bin/env bash
. "${BASH_SOURCE%/*}/common.sh"
yb_activate_virtualenv "$my_project_root"
export PYTHONPATH=$my_project_root/python:$PYTHONPATH
yb_activate_virtualenv "$my_project_root"
. "$my_project_root/python/my_package/my_tool.py" "$@"
```

# Copyright

Copyright (c) YugaByte, Inc.

See the LICENSE file in the root of this repository for details.
