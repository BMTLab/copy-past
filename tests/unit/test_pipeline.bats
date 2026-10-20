#!/usr/bin/env bats

# Tests the helpers that move the payload of copy.sh to the pipeline.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
}

# region __cp_buffer_input

@test "__cp_buffer_input copies a piped stdin to the buffer" {
  local buffer_path=''

  # Arrange: stdin is a here-string, so no terminal.

  # Act
  __cp_buffer_input buffer_path <<<'piped content'

  # Assert: a here-string ends with a newline.
  [[ "$(print_hex <"${buffer_path}")" == "$(printf 'piped content\n' | print_hex)" ]]
}

@test "__cp_buffer_input joins the words of the text with spaces" {
  local -r path_file="${BATS_TEST_TMPDIR}/buffer-path"
  local buffer_path

  # Arrange:
  # argument mode needs a terminal as stdin, so the call runs in one.
  # The terminal turns LF into CRLF,
  # so the path of the buffer comes back through a file.

  # Act
  run_in_terminal '
    buffer_path=""
    __cp_buffer_input buffer_path first second third
    printf "%s" "${buffer_path}" >"$1"
  ' "${path_file}" >/dev/null

  # Assert: the words, with no newline after them.
  buffer_path="$(<"${path_file}")"
  [[ "$(print_hex <"${buffer_path}")" == "$(printf '%s' 'first second third' | print_hex)" ]]
}

@test "__cp_buffer_input refuses no input at all with the usage code" {
  # Arrange: a terminal as stdin, and no words.

  # Act
  run --separate-stderr run_in_terminal '
    buffer_path=""
    code=0
    __cp_buffer_input buffer_path || code=$?
    printf "code=%s\n" "${code}"
  '

  # Assert
  [[ "${output}" == *"code=${COPY_ERR_USAGE}"* ]]
}

# endregion __cp_buffer_input

# region __cp_capture_prelude

@test "__cp_capture_prelude saves nothing without --append" {
  local prelude_path='dirty'

  # Arrange: a path from before must be cleared.

  # Act
  __cp_capture_prelude prelude_path 0

  # Assert
  [[ -z "${prelude_path}" ]]
}

@test "__cp_capture_prelude saves the clipboard in a file" {
  local prelude_path=''

  # Arrange
  set_clipboard 'existing buffer'

  # Act
  __cp_capture_prelude prelude_path 1

  # Assert
  [[ "$(<"${prelude_path}")" == 'existing buffer' ]]
}

# endregion __cp_capture_prelude

# region __cp_stream_with_prelude

@test "__cp_stream_with_prelude prints stdin alone without a saved clipboard" {
  local streamed

  # Arrange: no saved clipboard.

  # Act
  streamed="$(printf '%s' 'just stdin' | __cp_stream_with_prelude '')"

  # Assert
  [[ "${streamed}" == 'just stdin' ]]
}

@test "__cp_stream_with_prelude prints the saved clipboard before stdin" {
  local -r prelude_path="${BATS_TEST_TMPDIR}/prelude"
  local streamed

  # Arrange
  printf '%s' 'OLD-' >"${prelude_path}"

  # Act
  streamed="$(printf '%s' 'NEW' | __cp_stream_with_prelude "${prelude_path}")"

  # Assert
  [[ "${streamed}" == 'OLD-NEW' ]]
}

# endregion __cp_stream_with_prelude

### End
