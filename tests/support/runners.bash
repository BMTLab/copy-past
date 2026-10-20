#!/usr/bin/env bash

# Run copy and past for the tests: sourced here, in a new bash, or in a terminal.

# region Sourced scripts

#######################################
# Source copy.sh and past.sh into the test shell,
# then turn on the options of their guard,
# so the functions run as they do in a program.
#
# Globals:
#   COPY_PAST_ROOT: read.
#######################################
function load_scripts() {
  # shellcheck source=../../copy.sh
  source "${COPY_PAST_ROOT}/copy.sh"
  # shellcheck source=../../past.sh
  source "${COPY_PAST_ROOT}/past.sh"
  set -o nounset -o pipefail
  shopt -s inherit_errexit
}

#######################################
# Print the lines that a new bash runs first:
# it sources the scripts and turns on the options of their guard.
#
# Arguments:
#   $@: The scripts to source: copy.sh, past.sh or both.
#
# Globals:
#   COPY_PAST_ROOT: read.
#
# Outputs:
#   The lines, to stdout.
#######################################
function print_snippet_prelude() {
  local script_name

  for script_name in "$@"; do
    printf 'source %s/%s\n' "${COPY_PAST_ROOT@Q}" "${script_name}"
  done
  printf '%s\n' 'set -o nounset -o pipefail' 'shopt -s inherit_errexit'
}

# endregion Sourced scripts

# region A new bash

#######################################
# Run a snippet in a new bash that sourced copy.sh and past.sh.
#
# Arguments:
#   1: The snippet.
#######################################
function run_snippet() {
  local -r snippet="$1"
  local prelude

  prelude="$(print_snippet_prelude copy.sh past.sh)"

  bash -c "${prelude}"$'\n'"${snippet}"
}

#######################################
# Run past and print what it prints, trailing newlines too.
#
# Arguments:
#   $@: The options of past.
#
# Outputs:
#   The output of past, to stdout, byte for byte.
#######################################
function run_past_keeping_newlines() {
  local prelude

  prelude="$(print_snippet_prelude past.sh)"

  # past prints, then x; removing the x keeps the newlines before it.
  bash -c "${prelude}"'
    output="$(past "$@"; printf x)"
    printf "%s" "${output%x}"
  ' run_past_keeping_newlines "$@"
}

#######################################
# Write a payload with copy, read it back with past, and print it as hex.
#
# Arguments:
#   1: The payload, as printf prints it with %b, so \033 and \n work.
#   2...: The options of copy, such as --raw.
#
# Outputs:
#   What past read, as one line of lowercase hex.
#######################################
function run_roundtrip_hex() {
  local -r payload="$1"
  local prelude
  shift

  prelude="$(print_snippet_prelude copy.sh past.sh)"

  bash -c "${prelude}"'
    payload="$1"
    shift
    printf "%b" "${payload}" | copy "$@"
    output="$(past; printf x)"
    printf "%s" "${output%x}" | xxd -p | tr -d "\n"
  ' run_roundtrip_hex "${payload}" "$@"
}

#######################################
# Run a snippet with a PATH of one empty directory,
# so no backend is found, as on a host without one.
#
# WAYLAND_DISPLAY and XDG_SESSION_TYPE are gone too.
# The snippet runs in a bash that sourced copy.sh and past.sh.
#
# Arguments:
#   1: The snippet.
#######################################
function run_without_backends() {
  local -r snippet="$1"
  local -r empty_bin="${BATS_TEST_TMPDIR}/empty-bin"
  local prelude bash_path

  prelude="$(print_snippet_prelude copy.sh past.sh)"
  bash_path="$(command -v bash)"
  mkdir -p -- "${empty_bin}"

  env -i HOME="${HOME}" PATH="${empty_bin}" \
    "${bash_path}" -c "${prelude}"$'\n'"${snippet}"
}

# endregion A new bash

# region A terminal

#######################################
# Run a snippet with a terminal as its stdin,
# so copy takes its arguments as the text.
#
# bats gives a test no terminal, and in CI its stdin is a pipe,
# so only a pseudo-terminal from script reaches argument mode.
# script runs a command through /bin/sh, which knows no bash,
# so the snippet goes into a file that bash runs.
# The file lies in the directory of the test, which bats removes.
#
# Arguments:
#   $@: The snippet; the words are joined by spaces.
#
# Outputs:
#   The output of the snippet, with CRLF line ends from the terminal.
#######################################
function run_in_terminal() {
  local -r snippet="$*"
  local -r snippet_path="${BATS_TEST_TMPDIR}/terminal_snippet.sh"
  local bash_path

  bash_path="$(command -v bash)"
  printf '#!%s\n%s\n' "${bash_path}" "${snippet}" >"${snippet_path}"
  chmod +x -- "${snippet_path}"

  if [[ "${OSTYPE}" == darwin* ]]; then
    # BSD script takes the command after the file.
    script -q /dev/null "${bash_path}" "${snippet_path}" </dev/null
  else
    # util-linux script takes the command as one string.
    script -qec "${bash_path} ${snippet_path@Q}" /dev/null </dev/null
  fi
}

#######################################
# Run copy in a terminal, in argument mode.
#
# Only copy.sh is sourced, so --append runs the past.sh beside it.
#
# Arguments:
#   $@: The words of the command line of copy, joined by spaces:
#       they are shell code, so a word with a space needs quotes.
#######################################
function run_copy_in_terminal() {
  local -r command_line="$*"
  local prelude

  prelude="$(print_snippet_prelude copy.sh)"

  run_in_terminal "${prelude}"$'\n'"copy ${command_line}"
}

# endregion A terminal

### End
