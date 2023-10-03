# yugabyte-bash-common

[![CI](https://github.com/yugabyte/yugabyte-bash-common/workflows/CI/badge.svg)](https://github.com/yugabyte/yugabyte-bash-common/actions?query=workflow%3ACI)

A common set of functionality in Bash to be used across YugabyteDB's repositories, e.g. as part of
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

`YB_VERBOSE`: This enables verbose logging, useful for debugging.

`FAIL_ON_WARNING`: This causes `warn` messages from the `logger.sh` to become fatal instead.

`YB_PYTHON_VERSION`: This defines which version of python to use.  It takes a python version number
like `3` or `3.8`.  The default is `3` but you are encouraged to set this to something more specific
for your own project.  If the specified version can't be found in $PATH the library exits with an
error.

`YB_BUILD_STRICT`: venv only. This tells `yb_activate_virtualenv` from `create_venv.sh` how strict
it should be when evaluating the `requirements.txt`, `requrements_frozen.xt`, and python version
changes from what was used to generate the `requrements_frozen.xt`.  If `YB_BUILD_STRICT` is true
the following conditions all cause an immediate error exit:
* `requirements.txt` is newer than `requirements_frozen.txt`
* The in-use version of python is different than the version used to generate `requirements_frozen.txt`
* The contents of `requirements.txt` has changed since `requirements_frozen.txt` was generated.
* `requirements_frozen.txt` is missing the `YB_SHA` line
* The venv exists but has changed

If `YB_BUILD_STRICT` is false, the above conditions cause the venv to be refreshed or recreated as
needed.

`YB_RECREATE_VIRTUALENV`: Setting this to true will cause the venv to get recreated everytime even
if no changes to the venv, python version, or requirements files are detected.  Default is false.

`YB_PUT_VENV_IN_PROJECT_DIR`: When true (the default), the venv directory is placed next to the
requirements.txt file.

`YB_VENV_BASE_DIR`: Only takes effect when `YB_PUT_VENV_IN_PROJECT_DIR` is false.  This defines the
root directory under which venvs should be placed.  The path to each venv under this root includes a
unique SHA derived from the requirements.txt contents and python version.  This can help when
switching between branches with different requirements.txt changes for the same project.  Default
is `~/.venv/yb`

## Functions and Modules

### `create_venv.sh`

`create_venv.sh` is both a standalone script and includable bash library.  Internally it makes use
of the `logger.sh`, `os.sh`, and `detect_python.sh` modules.  When used as a standalone script,
it simply calls `yb_activate_virtualenv` on the supplied argument (defaulting to the current
directory if no argument was supplied).  It creates an empty venv using `YB_PYTHON_VERSION` if no
requirements.txt is found.
```bash
# create a venv in the current directory.
/path/to/yugabyte-bash-common/src/create_venv.sh
```
When sourced it provides the following global functions:

#### `yb_activate_virtualenv`

The `yb_activate_virtualenv` function takes one argument, the top-level directory containing
a `requirements.txt` or a `requirements_frozen.txt` file. It creates a virtual env according to
the rules described above.

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

### `detect_python.sh`
This module looks for the first instance of a python executable that matches the version specified
by `YB_PYTHON_VERSION` in $PATH and then sets `yb_python_interpreter` to that executable.  It also
sets `py_major_version` and `yb_python_version_actual` with the major version and full version number
respectively.  It provides a single function `run_python` that will pass whatever is provided to it
as an argument for the `yb_python_interpreter`.  This makes no use of any venv that may exist and
shouldn't be used from within one.

### `os.sh`
This module tries to detect some info about the host we are running on (linux or mac, linux
distribution, core count) and provides some helper function for same (`is_linux()`, `is_mac()`,
`is_rhel()`, etc).  Core count is exposed through the global variable `YB_NUM_CPUS`

### `logger.sh`
This modules provides a number of logging functions complete with colored output and timestamps.
Please look in the module itself for the full list of available functions.  Most commonly useful
will be `log`, `fatal`, and `yb::verbose_log`

# Copyright

Copyright (c) YugaByte, Inc.

See the LICENSE file in the root of this repository for details.
