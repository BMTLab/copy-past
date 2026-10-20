#!/usr/bin/env bash

# Run copy and past for the tests: sourced here, in a new bash, or in a terminal.

# A snippet for a new bash is code alone: its values come as arguments,
# "$1" and on, never inside the code, so a quote in a value breaks nothing.

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
# they source the scripts from the project root in $1, shift the root away,
# and turn on the options of the guard.
#
# Arguments:
#   $@: The scripts to source: copy.sh, past.sh or both.
#
# Outputs:
#   The lines, to stdout.
#######################################
function print_snippet_prelude() {
  local script_name

  for script_name in "$@"; do
    printf 'source "$1/%s"\n' "${script_name}"
  done
  printf '%s\n' 'shift' 'set -o nounset -o pipefail' 'shopt -s inherit_errexit'
}

# endregion Sourced scripts

# region A new bash

#######################################
# Run a snippet in a new bash that sourced copy.sh and past.sh.
#
# Arguments:
#   1: The snippet.
#   2...: Its values, which it reads as "$1" and on.
#
# Globals:
#   COPY_PAST_ROOT: read.
#######################################
function run_snippet() {
  local -r snippet="$1"
  local prelude
  shift

  prelude="$(print_snippet_prelude copy.sh past.sh)"

  bash -c "${prelude}"$'\n'"${snippet}" run_snippet "${COPY_PAST_ROOT}" "$@"
}

#######################################
# Run past and print what it prints, trailing newlines too.
#
# Arguments:
#   $@: The options of past.
#
# Globals:
#   COPY_PAST_ROOT: read.
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
  ' run_past_keeping_newlines "${COPY_PAST_ROOT}" "$@"
}

#######################################
# Write a payload with copy, read it back with past, and print it as hex.
#
# Arguments:
#   1: The payload, as printf prints it with %b, so \033 and \n work.
#   2...: The options of copy, such as --raw.
#
# Globals:
#   COPY_PAST_ROOT: read.
#
# Outputs:
#   What past read, as one line of lowercase hex.
#######################################
function run_roundtrip_hex() {
  local prelude

  prelude="$(print_snippet_prelude copy.sh past.sh)"

  bash -c "${prelude}"'
    payload="$1"
    shift
    printf "%b" "${payload}" | copy "$@"
    output="$(past; printf x)"
    printf "%s" "${output%x}" | xxd -p | tr -d "\n"
  ' run_roundtrip_hex "${COPY_PAST_ROOT}" "$@"
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
#   2...: Its values, which it reads as "$1" and on.
#
# Globals:
#   COPY_PAST_ROOT: read.
#######################################
function run_without_backends() {
  local -r snippet="$1"
  local -r empty_bin="${BATS_TEST_TMPDIR}/empty-bin"
  local prelude bash_path
  shift

  prelude="$(print_snippet_prelude copy.sh past.sh)"
  bash_path="$(command -v bash)"
  mkdir -p -- "${empty_bin}"

  env -i HOME="${HOME}" PATH="${empty_bin}" \
    "${bash_path}" -c "${prelude}"$'\n'"${snippet}" \
    run_without_backends "${COPY_PAST_ROOT}" "$@"
}

#######################################
# Run a command, and stop it once it runs longer than a limit.
#
# macOS has no timeout, so bash keeps the time:
# the command runs in the background, and a loop waits for its end.
#
# Arguments:
#   1: The limit, in seconds.
#   2...: The command.
#
# Inputs:
#   The stdin of the command.
#
# Returns:
#   The status of the command, or 124 when it ran too long, as timeout does.
#######################################
function run_with_time_limit() {
  local -ir limit="$1"
  local -i command_pid=0 waited_tenths=0 command_status=0
  shift

  # A background command reads /dev/null unless it names its stdin,
  # so the stdin of this function goes to it on purpose.
  "$@" <&0 &
  command_pid=$!

  while kill -0 "${command_pid}" 2>/dev/null; do
    if ((waited_tenths >= limit * 10)); then
      # A bash that waits for a child runs its TERM trap only after the child,
      # so the children go first. The command may end at any moment here,
      # so a signal that finds no process is fine.
      pkill -TERM -P "${command_pid}" 2>/dev/null || true
      kill -TERM "${command_pid}" 2>/dev/null || true
      wait "${command_pid}" 2>/dev/null || true

      return 124
    fi
    sleep 0.1
    waited_tenths=$((waited_tenths + 1))
  done

  wait "${command_pid}" || command_status=$?

  return "${command_status}"
}

# endregion A new bash

# region A terminal

#######################################
# Run a snippet with a terminal as its stdin, in a bash that sourced copy.sh,
# so copy takes its arguments as the text.
#
# bats gives a test no terminal, and in CI its stdin is a pipe,
# so only a pseudo-terminal from script reaches argument mode.
# util-linux script takes its command as one string for a shell,
# so the values go to a file beside the snippet,
# and the snippet reads them back into "$1" and on.
# Both files lie in the directory of the test, which bats removes.
#
# Arguments:
#   1: The snippet.
#   2...: Its values, which it reads as "$1" and on.
#
# Globals:
#   COPY_PAST_ROOT: read.
#
# Outputs:
#   The output of the snippet, with CRLF line ends from the terminal.
#######################################
function run_in_terminal() {
  local -r snippet="$1"
  local -r snippet_path="${BATS_TEST_TMPDIR}/terminal_snippet.sh"
  local prelude bash_path
  shift

  prelude="$(print_snippet_prelude copy.sh)"
  bash_path="$(command -v bash)"
  printf '%s\0' "${COPY_PAST_ROOT}" "$@" >"${BATS_TEST_TMPDIR}/terminal_values"
  {
    printf '#!%s\n' "${bash_path}"
    printf '%s\n' \
      'mapfile -d "" -t values <"${BASH_SOURCE[0]%/*}/terminal_values"' \
      'set -- "${values[@]}"' \
      "${prelude}" \
      "${snippet}"
  } >"${snippet_path}"
  chmod +x -- "${snippet_path}"

  if [[ "${OSTYPE}" == darwin* ]]; then
    # BSD script takes the command and its arguments after the file.
    script -q /dev/null "${snippet_path}" </dev/null
  else
    # util-linux script takes the command as one string for a shell.
    script -qec "${snippet_path@Q}" /dev/null </dev/null
  fi
}

#######################################
# Run copy in a terminal, in argument mode.
#
# Only copy.sh is sourced, so --append runs the past.sh beside it.
#
# Arguments:
#   $@: The arguments of copy.
#######################################
function run_copy_in_terminal() {
  run_in_terminal 'copy "$@"' "$@"
}

# endregion A terminal

### End
