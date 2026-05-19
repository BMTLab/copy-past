#!/usr/bin/env bats

# Name: tests/unit/test_debug_log.bats
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   Unit tests for the debug-logging helpers:
#     - __cp_debug
#     - __ps_debug
#
#   These tests pin the exact line format
#   ('[copy debug] event=NAME k1=v1 k2=v2'),
#   because that format is the project's stable contract
#   for downstream tooling and integration tests
#   that parse the log to assert internal decisions.
#
#   Each test follows the Arrange-Act-Assert (AAA) pattern.
#
# Disclaimer:
#   This script is provided 'as is', without any warranty.

bats_require_minimum_version 1.5.0

load '../support/test_helper.bash'

setup() {
  __cp_setup_fake_backend
  __cp_load_scripts
}


# region Silence by default

@test "__cp_debug is a no-op when debug_mode=0" {
  # Arrange / Act
  local stderr_out
  stderr_out="$(__cp_debug 0 'should-not-fire' 'key=value' 2>&1 1>/dev/null)"

  # Assert
  [ -z "$stderr_out" ]
}

# endregion


# region Line format

@test "__cp_debug emits a single structured line when debug_mode=1" {
  # Arrange / Act
  local stderr_out
  stderr_out="$(__cp_debug 1 'sample' 'k1=v1' 'k2=v2' 2>&1 1>/dev/null)"

  # Assert:
  # exact line layout, including the [copy debug] prefix.
  [ "$stderr_out" = '[copy debug] event=sample k1=v1 k2=v2' ]
}

@test "__cp_debug quotes values that contain whitespace" {
  # Arrange / Act
  local stderr_out
  stderr_out="$(
    __cp_debug 1 'spacy' 'plain=ok' 'with-space=hello world' \
      2>&1 1>/dev/null
  )"

  # Assert:
  # plain values stay bare;
  # whitespace-bearing values are wrapped in single quotes.
  [[ "$stderr_out" == *'plain=ok'* ]]
  [[ "$stderr_out" == *"with-space='hello world'"* ]]
}

@test "__cp_debug emits a bare event line when no key=value pairs follow" {
  # Arrange / Act
  local stderr_out
  stderr_out="$(__cp_debug 1 'lone-event' 2>&1 1>/dev/null)"

  # Assert
  [ "$stderr_out" = '[copy debug] event=lone-event' ]
}

@test "__ps_debug uses the [past debug] prefix" {
  # Arrange / Act
  local stderr_out
  stderr_out="$(__ps_debug 1 'p-event' 'k=v' 2>&1 1>/dev/null)"

  # Assert
  [ "$stderr_out" = '[past debug] event=p-event k=v' ]
}

# endregion

### End of file
