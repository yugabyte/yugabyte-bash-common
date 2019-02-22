# yugabyte-bash-common

A common set of functionality in Bash to be used across YugaByte's repositories, e.g. as part of
build scripts, etc. Could also be used in other projects.


## Using this library in your project

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
if [[ ! -d $my_project_root/yugabyte-bash-common ]]; then
  git submodule update
fi

. "$my_project_root"/src/yugabyte-bash-common.sh

```

# Copyright

Copyright (c) YugaByte, Inc.

See the LICENSE file in the root of this repository for details.
