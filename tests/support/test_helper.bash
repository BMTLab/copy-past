#!/usr/bin/env bash

# Load the support modules of the tests; every test file loads this file.

# shellcheck disable=SC2034 # The test files and the modules read it.
COPY_PAST_ROOT="${BATS_TEST_DIRNAME}/../.."
SUPPORT_DIRECTORY="${BASH_SOURCE[0]%/*}"

# shellcheck source=fakes.bash
source "${SUPPORT_DIRECTORY}/fakes.bash"
# shellcheck source=clipboard.bash
source "${SUPPORT_DIRECTORY}/clipboard.bash"
# shellcheck source=runners.bash
source "${SUPPORT_DIRECTORY}/runners.bash"
# shellcheck source=debug_log.bash
source "${SUPPORT_DIRECTORY}/debug_log.bash"

### End
