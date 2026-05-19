#!/bin/bash

# Name: tests/support/runners.bash
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   High-level helpers that run copy.sh / past.sh in the right
#   environment and return the result for `run`-style assertions.
#
#   Replaces ~60 inline copies of:
#     bash -c '
#       source "${COPY_PAST_ROOT}/copy.sh"
#       ...
#     '
#
#   Loaded by tests/support/test_helper.bash.

# region Source loaders

#######################################
# Source copy.sh and past.sh into the current shell,
# so tests can call the functions directly.
# Both scripts' execution guards skip auto-running when sourced.
#######################################
__cp_load_scripts() {
  # shellcheck source=../../copy.sh
  source "${COPY_PAST_ROOT}/copy.sh"
  # shellcheck source=../../past.sh
  source "${COPY_PAST_ROOT}/past.sh"
}

# endregion

# region Subshell runners

#######################################
# Run a bash snippet that has both copy.sh and past.sh sourced.
#
# Designed for use with `run --separate-stderr`, e.g.:
#
#   run --separate-stderr __cp_run "printf '%s' hi | copy --debug"
#
# Arguments:
#   1: bash snippet (single string, may use $-vars and quoting).
#######################################
__cp_run() {
  local -r snippet="$1"
  bash -c "
    source '${COPY_PAST_ROOT}/copy.sh'
    source '${COPY_PAST_ROOT}/past.sh'
    ${snippet}
  "
}

#######################################
# Run `past` and capture its raw output preserving trailing newlines.
#
# Replaces the duplicated sentinel pattern:
#   out="$(past; printf x)"
#   out="${out%x}"
#   printf '%s' "$out"
#
# Designed for use with `run --separate-stderr`. The captured value
# is written to stdout verbatim, so subsequent assertions can pipe
# it to `xxd -p` etc.
#
# Arguments:
#   $@: extra flags to pass to past (e.g. --type, --image, --debug).
#######################################
__cp_run_past_raw() {
  bash -c "
    source '${COPY_PAST_ROOT}/past.sh'
    out=\"\$(past \"\$@\"; printf x)\"
    out=\"\${out%x}\"
    printf '%s' \"\$out\"
  " __cp_run_past_raw "$@"
}

# endregion

# region Pseudo-terminal runner

#######################################
# Run a snippet under a pseudo-terminal so that
# `if [[ ! -t 0 ]]; then # pipe mode` evaluates to false
# and the script enters argument-mode.
#
# Why this is needed:
#   bats by itself does not allocate a pty for `run`,
#   and `bash -c` inherits whatever stdin bats has.
#   When bats is launched from a non-interactive shell (CI),
#   stdin is a pipe, not a tty,
#   so argument-mode code paths cannot be reached
#   without explicit pty allocation.
#
# Implementation note:
#   util-linux `script -qec '<cmd>' /dev/null` looks tempting,
#   but `script` runs the command string through /bin/sh, which
#   does not understand bash quoting like $'...' and `[[`.
#   We sidestep that by writing the snippet to a temp file and
#   asking script to run it via an explicit bash invocation.
#
# Cross-platform notes:
#   - util-linux script (Linux) and BSD script (macOS) share
#     `-q`, but their argv layouts diverge slightly.
#   - The temp file is auto-cleaned at end of the bats test,
#     because $BATS_TEST_TMPDIR is recreated per-test.
#
# Arguments:
#   $@: the shell snippet to execute (single string).
#######################################
__cp_run_with_tty() {
  local -r snippet="$*"
  local bash_bin
  bash_bin="$(command -v bash)"

  local script_file="${BATS_TEST_TMPDIR:-/tmp}/__cp_tty_snippet.sh"
  {
    printf '#!%s\n' "$bash_bin"
    printf '%s\n' "$snippet"
  } > "$script_file"
  chmod +x "$script_file"

  if [[ "$(uname -s)" == 'Darwin' ]]; then
    # BSD script: `script [-q] file [command...]`
    script -q /dev/null "$bash_bin" "$script_file" < /dev/null
  else
    # util-linux script: `script [-q] [-c command] file`.
    # Pass an explicit bash invocation so the snippet does not
    # have to pass through script's default /bin/sh wrapper.
    script -qec "$bash_bin $script_file" /dev/null < /dev/null
  fi
}

#######################################
# Run a `copy` invocation in argument mode (with a tty stdin).
#
# Convenience wrapper around __cp_run_with_tty for the common case
# of "source copy.sh, then call copy with these positional words"
# without manually splicing $COPY_PAST_ROOT into the snippet.
#
# Arguments:
#   $@: positional words for `copy` (already as separate args).
#
# Note:
#   The args are joined with single spaces here, mirroring the way
#   the user would type them on the shell. If you need to pass an
#   arg that contains a literal space, fall back to __cp_run_with_tty
#   directly so you can quote things explicitly.
#######################################
__cp_run_copy_argv() {
  local args="$*"
  __cp_run_with_tty "
    source '${COPY_PAST_ROOT}/copy.sh'
    copy ${args}
  "
}

# endregion

# region Empty-PATH runner (for no-backend tests)

#######################################
# Run a snippet with PATH stripped to a single empty directory,
# so backend detection cannot find wl-copy / xclip / xsel.
#
# WAYLAND_DISPLAY and XDG_SESSION_TYPE are unset, mirroring a host
# without any clipboard tooling installed. HOME is preserved
# so bash itself can locate its rc files if it cares.
#
# Designed for use with `run --separate-stderr`, e.g.:
#
#   run --separate-stderr __cp_run_no_backend "
#     source '${COPY_PAST_ROOT}/copy.sh'
#     printf '%s' x | copy
#   "
#
# Arguments:
#   1: bash snippet (single string).
#######################################
__cp_run_no_backend() {
  local -r snippet="$1"
  local -r empty_bin="${BATS_TEST_TMPDIR}/empty-bin"
  local bash_bin
  bash_bin="$(command -v bash)"

  mkdir -p "$empty_bin"

  env -i \
    HOME="$HOME" \
    PATH="$empty_bin" \
    "$bash_bin" -c "
      unset WAYLAND_DISPLAY XDG_SESSION_TYPE
      ${snippet}
    "
}

# endregion

# region Roundtrip runner

#######################################
# Run a payload through `copy | past` and emit the result as hex.
#
# Centralises the byte-fidelity round-trip pattern that
# test_roundtrip.bats relies on:
#   1. write payload via printf | copy
#   2. read it back via past, preserving trailing newlines
#   3. dump the captured bytes as one continuous hex line
#
# Designed for use with `run --separate-stderr`, e.g.:
#
#   run --separate-stderr __cp_run_roundtrip_hex \
#     '\033[31mred\033[0m' --raw
#
#   [ "$output" = '1b5b33316d7265641b5b306d' ]
#
# Arguments:
#   1:    payload string (passed verbatim to printf, so '\033', '\n'
#         and other escapes are honoured).
#   2..N: extra flags to forward to copy (e.g. --raw, --debug).
#######################################
__cp_run_roundtrip_hex() {
  local -r payload="$1"
  shift

  bash -c "
    source '${COPY_PAST_ROOT}/copy.sh'
    source '${COPY_PAST_ROOT}/past.sh'
    printf '${payload}' | copy \"\$@\"
    out=\"\$(past; printf x)\"
    out=\"\${out%x}\"
    printf '%s' \"\$out\" | xxd -p | tr -d '\n'
  " __cp_run_roundtrip_hex "$@"
}

# endregion


### End of file
