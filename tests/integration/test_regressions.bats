#!/usr/bin/env bats

# Tests the bugs that were fixed, so none of them comes back.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
}

# region past reports a failure of wl-paste

@test "past reports a failure of wl-paste with the backend code" {
  # Arrange:
  # past puts x and the status of wl-paste after its output,
  # and once the trailing x hid the failure.
  set_clipboard 'irrelevant'

  # Act
  run --separate-stderr run_snippet '
    export FAKE_WL_PASTE_CODE=42
    past
  '

  # Assert
  ((status == PAST_ERR_BACKEND_FAILED))
  [[ "${stderr}" == *'clipboard backend failed to read'* ]]
}

# endregion past reports a failure of wl-paste

# region copy reports a failure of any stage

@test "copy reports a failure of wl-copy with the backend code" {
  # Arrange
  install_failing_wl_copy 7

  # Act
  run --separate-stderr run_snippet 'printf "%s" "data" | copy'

  # Assert
  ((status == COPY_ERR_BACKEND_FAILED))
  [[ "${stderr}" == *'clipboard backend failed'* ]]
}

@test "copy reports a failing backend after a filter that worked" {
  # Arrange:
  # sed removes the colors and succeeds, then the backend fails;
  # without pipefail, a stage before the last one would hide it.
  install_failing_wl_copy 13

  # Act
  run --separate-stderr run_snippet 'printf "\033[31mred\033[0m" | copy'

  # Assert
  ((status == COPY_ERR_BACKEND_FAILED))
}

# endregion copy reports a failure of any stage

# region copy keeps the backend off the output of its caller

@test "copy inside \$(...) returns while the backend still serves the clipboard" {
  # Arrange:
  # like the real wl-copy, the fake leaves a process behind
  # that keeps the stdout and stderr it got, here for 10 s.
  install_forking_wl_copy 10

  # Act: $(...) waits until no process holds its pipe.
  run --separate-stderr run_snippet '
    started="${SECONDS}"
    captured="$(printf "%s" "data" | copy)"
    printf "%s" "$((SECONDS - started))"
  '

  # Assert: the capture ends long before the process left behind.
  ((status == 0))
  [[ "${output}" =~ ^[0-9]+$ ]]
  ((output < 5))
  [[ "$(print_clipboard)" == 'data' ]]
}

@test "copy still shows the error message of a failing backend" {
  # Arrange
  install_failing_wl_copy 1 'wl-copy: failed to connect to a Wayland server'

  # Act
  run --separate-stderr run_snippet 'printf "%s" "data" | copy'

  # Assert: the message of the backend comes with the one of copy.
  ((status == COPY_ERR_BACKEND_FAILED))
  [[ "${stderr}" == *'wl-copy: failed to connect to a Wayland server'* ]]
  [[ "${stderr}" == *'clipboard backend failed'* ]]
}

# endregion copy keeps the backend off the output of its caller

# region copy leaves the shell that sourced it alone

@test "copy sourced into a shell leaves the stdin of that shell alone" {
  local -r report_path="${BATS_TEST_TMPDIR}/stdin-after-copy"

  # Arrange:
  # in argument mode, copy once handed the buffered payload on with exec,
  # which took the stdin of the shell that sourced copy.sh:
  # an interactive shell then read EOF and ended right after copy.

  # Act
  run_in_terminal '
    copy hello
    if [[ -t 0 ]]; then
      printf terminal >"$1"
    else
      printf "no terminal" >"$1"
    fi
  ' "${report_path}" >/dev/null

  # Assert
  [[ "$(<"${report_path}")" == 'terminal' ]]
  [[ "$(print_clipboard)" == 'hello' ]]
}

# endregion copy leaves the shell that sourced it alone

# region copy writes its arguments exactly

#######################################
# Check that copy writes the words of the text exactly:
# joined by spaces, with no newline added and none removed.
#
# Arguments:
#   1: The bytes expected in the clipboard, as hex.
#   2...: The arguments of copy.
#######################################
function argument_mode_writes_the_words_exactly() {
  local -r expected_hex="$1"
  shift

  # Arrange: the arguments are the input.

  # Act
  run --separate-stderr run_copy_in_terminal "$@"

  # Assert
  ((status == 0))
  [[ "$(print_clipboard_hex)" == "${expected_hex}" ]]
}

# Auto-detection once added a newline,
# --no-auto once dropped the newlines at the end of the words,
# and echo once took -n, -e and -E for its own options.
bats_test_function --description "copy 'hello world' writes the words exactly" \
  -- argument_mode_writes_the_words_exactly 68656c6c6f20776f726c64 'hello world'
bats_test_function \
  --description "copy --no-auto 'hello world' writes the words exactly" \
  -- argument_mode_writes_the_words_exactly 68656c6c6f20776f726c64 \
  --no-auto 'hello world'
bats_test_function \
  --description "copy keeps the newline that its words end with" \
  -- argument_mode_writes_the_words_exactly 6c696e650a $'line\n'
bats_test_function \
  --description "copy --no-auto keeps the newline that its words end with" \
  -- argument_mode_writes_the_words_exactly 6c696e650a --no-auto $'line\n'

# Samples: "flag|hex".
for echo_sample in '-n|2d6e' '-e|2d65' '-E|2d45'; do
  bats_test_function \
    --description "copy -- ${echo_sample%%|*} writes ${echo_sample%%|*}" \
    -- argument_mode_writes_the_words_exactly "${echo_sample#*|}" \
    -- "${echo_sample%%|*}"
done
bats_test_function --description "copy --no-auto -- -n writes -n" \
  -- argument_mode_writes_the_words_exactly 2d6e --no-auto -- -n

# endregion copy writes its arguments exactly

# region copy --append through the installed link

@test "copy run through the installed link appends with past beside it" {
  local -r link_directory="${BATS_TEST_TMPDIR}/bin"
  local -r payload_path="${BATS_TEST_TMPDIR}/payload.txt"

  # Arrange:
  # make install links copy and past, without .sh, into one directory,
  # and copy once looked only for a past.sh next to the link.
  mkdir -p -- "${link_directory}"
  ln -s -- "${COPY_PAST_ROOT}/copy.sh" "${link_directory}/copy"
  ln -s -- "${COPY_PAST_ROOT}/past.sh" "${link_directory}/past"
  set_clipboard 'old '
  printf '%s' 'new' >"${payload_path}"

  # Act
  run --separate-stderr "${link_directory}/copy" --append <"${payload_path}"

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == 'old new' ]]
}

# endregion copy --append through the installed link

# region copy refuses an image that xsel cannot take

@test "copy with xsel refuses a detected image and leaves the clipboard alone" {
  # Arrange:
  # xsel takes no MIME type; copy once printed the error,
  # then wrote an empty clipboard and exited 0.
  enable_fake_xsel
  set_clipboard 'previous'

  # Act
  run --separate-stderr run_snippet '
    export COPY_PAST_BACKEND=xsel
    printf "\x89PNG\r\n\x1a\nrest" | copy
  '

  # Assert
  ((status == COPY_ERR_TYPE_MISMATCH))
  [[ "${stderr}" == *'xsel does not support MIME types'* ]]
  [[ "$(print_clipboard)" == 'previous' ]]
}

# endregion copy refuses an image that xsel cannot take

# region copy takes its arguments over stdin

@test "copy writes its arguments when stdin is /dev/null" {
  # Arrange:
  # cron, systemd and the shell of an agent give no terminal as stdin;
  # copy once read that stdin instead of its arguments,
  # and wrote an empty clipboard.

  # Act
  run --separate-stderr run_snippet "copy 'agent text' </dev/null"

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == 'agent text' ]]
}

@test "copy with arguments returns while its stdin stays open" {
  local -r fifo_path="${BATS_TEST_TMPDIR}/stdin.fifo"
  local -i fifo_fd=0

  # Arrange:
  # the stdin of an agent's shell may never end, and copy once waited for it.
  # A FIFO open for reading and writing at once never ends a read,
  # and no process runs on that bats would wait for.
  mkfifo -- "${fifo_path}"
  exec {fifo_fd}<>"${fifo_path}"

  # Act: timeout ends a hang after 10 s.
  run --separate-stderr timeout 10 "${COPY_PAST_ROOT}/copy.sh" 'agent text' \
    <&"${fifo_fd}"

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == 'agent text' ]]
}

#######################################
# Check that copy takes its arguments over a piped stdin.
#
# Arguments:
#   1: The clipboard expected.
#   2...: The options of copy.
#######################################
function arguments_win_over_stdin() {
  local -r expected="$1"

  # Arrange: the clipboard holds old text, and stdin holds other text.
  set_clipboard 'old '

  # Act
  run --separate-stderr run_snippet 'printf piped | copy "$@" argument' "${@:2}"

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == "${expected}" ]]
}

bats_test_function --description "copy takes its arguments over a piped stdin" \
  -- arguments_win_over_stdin 'argument'
bats_test_function \
  --description "copy --no-auto takes its arguments over a piped stdin" \
  -- arguments_win_over_stdin 'argument' --no-auto
bats_test_function \
  --description "copy --raw takes its arguments over a piped stdin" \
  -- arguments_win_over_stdin 'argument' --raw
bats_test_function \
  --description "copy --append takes its arguments over a piped stdin" \
  -- arguments_win_over_stdin 'old argument' --append

# endregion copy takes its arguments over stdin

### End
