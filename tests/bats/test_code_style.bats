#!/usr/bin/env bats

# Name: tests/bats/test_code_style.bats
# Author: Nikita Neverov (BMTLab)
# Version: 1.1.0
# Date: 2026-05-17
# License: MIT
#
# Description:
#   Style enforcement gate for the copy-past project.
#   Each test collects violations across the full set of source files,
#   and only then asserts the failure list is empty
#   (accumulate, then exit).
#   Covers shellcheck and bash -n syntax checks,
#   plus the cdl-style header convention
#   shared with the rest of the BMTLab repos.
#
#   Each test follows the Arrange-Act-Assert (AAA) pattern,
#   where the "Act" phase iterates over every source file
#   and aggregates the failures.
#
# Disclaimer:
#   This script is provided "as is", without any warranty.

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  cd "$PROJECT_ROOT" || exit 1

  # Source files under test (the two CLI scripts).
  SCRIPTS=(
    "${PROJECT_ROOT}/copy.sh"
    "${PROJECT_ROOT}/past.sh"
  )
}

# region Helpers

# Render a list of failures (one per indented line) and return 1.
# Centralises the failure formatting used by every test in this file,
# so the report layout stays consistent across rules.
__report_failures() {
  local label=$1
  shift

  local f
  printf '  %s:\n' "$label" >&2
  for f in "$@"; do
    printf '    - %s\n' "$f" >&2
  done

  return 1
}

# endregion


# region Syntax & static analysis

@test "every source script passes 'bash -n' syntax check" {
  # Arrange
  local f
  local -a failures=()

  # Act
  for f in "${SCRIPTS[@]}"; do
    if ! bash -n "$f" 2>&1 >&2; then
      failures+=("$f")
    fi
  done

  # Assert
  if [ "${#failures[@]}" -gt 0 ]; then
    __report_failures "'bash -n' syntax errors in" "${failures[@]}"
  fi
}

@test "shellcheck passes on every source script" {
  # Arrange
  if ! command -v shellcheck > /dev/null 2>&1; then
    skip 'shellcheck not installed'
  fi

  local f
  local -a failures=()

  # Act:
  # SC2155 is suppressed,
  # because the project deliberately uses `local var=$(…)`
  # for readability;
  # the loss of the inner exit code is acceptable
  # for these small helpers.
  for f in "${SCRIPTS[@]}"; do
    if ! shellcheck -S warning -e SC2155 "$f" >&2; then
      failures+=("$f")
    fi
  done

  # Assert
  if [ "${#failures[@]}" -gt 0 ]; then
    __report_failures 'shellcheck failures' "${failures[@]}"
  fi
}

# endregion


# region Header conventions

@test "every source script starts with a cdl-style header" {
  # Arrange:
  # each script must declare at least Name and Description
  # in the first ~30 header lines.
  local f
  local -a failures=()

  # Act
  for f in "${SCRIPTS[@]}"; do
    local head
    head=$(head -n 30 "$f")

    if ! grep -qE '^# Name:' <<< "$head" \
      || ! grep -qE '^# Description:' <<< "$head"; then
      failures+=("$f")
    fi
  done

  # Assert
  if [ "${#failures[@]}" -gt 0 ]; then
    __report_failures 'missing cdl-style header in' "${failures[@]}"
  fi
}

@test "every source script declares a Version and Date" {
  # Arrange
  local f
  local -a failures=()

  # Act
  for f in "${SCRIPTS[@]}"; do
    local head
    head=$(head -n 30 "$f")

    if ! grep -qE '^# Version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' <<< "$head" \
      || ! grep -qE '^# Date:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}' <<< "$head"; then
      failures+=("$f")
    fi
  done

  # Assert
  if [ "${#failures[@]}" -gt 0 ]; then
    __report_failures 'missing Version/Date header in' "${failures[@]}"
  fi
}

# endregion


# region Formatting

@test "shfmt -d reports no diff on source scripts" {
  # Arrange
  if ! command -v shfmt > /dev/null 2>&1; then
    skip 'shfmt not installed'
  fi

  local f
  local -a failures=()

  # Act:
  # match the formatting used in the rest of the BMTLab repos.
  for f in "${SCRIPTS[@]}"; do
    if ! shfmt -d -i 2 -ci -bn "$f" >&2; then
      failures+=("$f")
    fi
  done

  # Assert
  if [ "${#failures[@]}" -gt 0 ]; then
    __report_failures 'shfmt diff in' "${failures[@]}"
  fi
}

# endregion

### End of file
