#!/bin/bash

# Name: tests/support/test_helper.bash
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   Bats test-helper orchestrator for the copy-past suite.
#
#   This file is the only entry point that test files load
#   (`load '../support/test_helper.bash'`).
#   It wires up the focused modules below
#   so individual concerns stay separate
#   without forcing every test to know about each module's name.
#
#   Modules:
#     - fakes.bash:      hermetic wl-copy / wl-paste / xclip / xsel stubs
#     - clipboard.bash:  inspection & byte-fidelity helpers
#     - runners.bash:    high-level subshell runners (replaces
#                        inline `bash -c 'source ...'` boilerplate)
#     - debug_log.bash:  matchers for the structured --debug log

# Path of the project root (parent of tests/).
# shellcheck disable=SC2034 # consumed by every test file via load
COPY_PAST_ROOT="${BATS_TEST_DIRNAME}/../.."

# Resolve the directory of THIS file so the loads below
# work no matter from which subdirectory the test ran.
__CP_SUPPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=fakes.bash
source "${__CP_SUPPORT_DIR}/fakes.bash"
# shellcheck source=clipboard.bash
source "${__CP_SUPPORT_DIR}/clipboard.bash"
# shellcheck source=runners.bash
source "${__CP_SUPPORT_DIR}/runners.bash"
# shellcheck source=debug_log.bash
source "${__CP_SUPPORT_DIR}/debug_log.bash"

### End of file
