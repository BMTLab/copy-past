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
  # Arrange:
  # in argument mode, copy once handed the buffered payload on with exec,
  # which took the stdin of the shell that sourced copy.sh:
  # an interactive shell then read EOF and ended right after copy.
  local -r report_path="${BATS_TEST_TMPDIR}/stdin-after-copy"

  # Act
  run_in_terminal "
    $(print_snippet_prelude copy.sh)
    copy hello
    if [[ -t 0 ]]; then
      printf 'terminal' >${report_path@Q}
    else
      printf 'no terminal' >${report_path@Q}
    fi
  " >/dev/null

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
#   2...: The command line of copy, as shell code.
#######################################
function argument_mode_writes_the_words_exactly() {
  # Arrange: the command line is the input.
  local -r expected_hex="$1"
  local -r command_line="${*:2}"

  # Act
  run --separate-stderr run_copy_in_terminal "${command_line}"

  # Assert
  ((status == 0))
  [[ "$(print_clipboard_hex)" == "${expected_hex}" ]]
}

# Samples: "command line|hex". Auto-detection once added a newline,
# --no-auto once dropped the newlines at the end of the words,
# and echo once took -n, -e and -E for its own options.
ARGUMENT_SAMPLES=(
  "'hello world'|68656c6c6f20776f726c64"
  "--no-auto 'hello world'|68656c6c6f20776f726c64"
  "\$'line\\n'|6c696e650a"
  "--no-auto \$'line\\n'|6c696e650a"
  '-- -n|2d6e'
  '-- -e|2d65'
  '-- -E|2d45'
  '--no-auto -- -n|2d6e'
)

for argument_sample in "${ARGUMENT_SAMPLES[@]}"; do
  bats_test_function \
    --description "copy ${argument_sample%%|*} writes exactly ${argument_sample#*|}" \
    -- argument_mode_writes_the_words_exactly "${argument_sample#*|}" \
    "${argument_sample%%|*}"
done

# endregion copy writes its arguments exactly

# region copy --append through the installed link

@test "copy run through the installed link appends with past beside it" {
  # Arrange:
  # make install links copy and past, without .sh, into one directory,
  # and copy once looked only for a past.sh next to the link.
  local -r link_directory="${BATS_TEST_TMPDIR}/bin"
  local -r payload_path="${BATS_TEST_TMPDIR}/payload.txt"
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

### End
