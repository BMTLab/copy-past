#!/usr/bin/env bats

# Tests the options of copy and past end to end: append, trim, MIME types, images.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
}

# region --append

@test "copy --append adds the new text after the clipboard" {
  # Arrange
  set_clipboard 'first '

  # Act
  run --separate-stderr run_snippet 'printf "%s" "second" | copy --append'

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == 'first second' ]]
}

@test "copy --append on an empty clipboard writes the new text alone" {
  # Arrange
  set_clipboard ''

  # Act
  run --separate-stderr run_snippet 'printf "%s" "fresh" | copy --append'

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == 'fresh' ]]
}

@test "copy --append works in argument mode" {
  # Arrange
  set_clipboard 'hello '

  # Act
  run --separate-stderr run_copy_in_terminal '--append world'

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == 'hello world' ]]
}

# endregion --append

# region --trim

@test "copy --trim removes the whitespace at both ends and keeps the inside" {
  # Arrange: whitespace around the text; tabs and newlines inside it.

  # Act
  run --separate-stderr run_snippet \
    'printf "  \t\nmiddle a b\tc\nd  \n" | copy --trim'

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == $'middle a b\tc\nd' ]]
}

@test "copy --trim removes ANSI escape sequences first, then the whitespace" {
  # Arrange: spaces around a colored word.

  # Act
  run --separate-stderr run_snippet \
    'printf "  \033[31mred\033[0m  " | copy --trim'

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == 'red' ]]
}

@test "copy --trim --raw keeps ANSI escape sequences and removes the whitespace" {
  # Arrange: spaces around a colored word.

  # Act
  run --separate-stderr run_snippet \
    'printf "  \033[31mred\033[0m  " | copy --trim --raw'

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == $'\033[31mred\033[0m' ]]
}

# endregion --trim

# region Explicit MIME types
#
# The debug log tells which MIME type copy and past chose:
# its format is a contract, while the argv of wl-copy is a detail.

@test "copy --type sets the MIME type and turns auto-detection off" {
  # Arrange: HTML, which auto-detection would call text/plain.

  # Act
  run --separate-stderr run_snippet \
    "printf '%s' '<html>hi</html>' | copy --debug --type text/html"

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == '<html>hi</html>' ]]
  assert_debug_event 'options-parsed' 'mime=text/html'
  assert_debug_event 'options-validated' 'auto=0'
}

@test "copy --json sets application/json and keeps ANSI escape sequences" {
  # Arrange:
  # the default filter would remove the escape sequences,
  # but --json implies --raw.

  # Act
  run --separate-stderr run_snippet \
    "printf '%b' '{\"key\":\"\\033[31mvalue\\033[0m\"}' | copy --debug --json"

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == $'{"key":"\033[31mvalue\033[0m"}' ]]
  assert_debug_event 'options-parsed' 'mime=application/json' 'raw=1'
}

@test "past --type asks the backend for that MIME type" {
  # Arrange
  set_clipboard 'binary-bytes'

  # Act
  run --separate-stderr past --debug --type image/png

  # Assert
  ((status == 0))
  [[ "${output}" == 'binary-bytes' ]]
  assert_debug_event 'options-parsed' 'mime=image/png'
  assert_debug_event 'mime-classified' 'is-binary=1'
}

# endregion Explicit MIME types

# region Auto-detection

@test "copy detects JSON by default when jq is there" {
  # Arrange
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq not installed; JSON detection needs it'
  fi

  # Act
  run --separate-stderr run_snippet \
    'printf "%s" "{\"hello\":\"world\"}" | copy --debug'

  # Assert: the payload takes the way of a binary one, with its type.
  ((status == 0))
  [[ "$(print_clipboard)" == '{"hello":"world"}' ]]
  assert_debug_event 'auto-detect' 'mime=application/json'
  assert_debug_event 'done' 'mode=auto-binary'
}

@test "copy detects PNG bytes by default" {
  # Arrange: the PNG signature, then more bytes.

  # Act
  run --separate-stderr run_snippet \
    'printf "\x89PNG\r\n\x1a\nrest" | copy --debug'

  # Assert
  ((status == 0))
  assert_debug_event 'auto-detect' 'mime=image/png'
  assert_debug_event 'done' 'mode=auto-binary'
}

@test "copy --no-auto writes valid JSON as text/plain" {
  # Arrange
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq not installed; without it nothing is detected anyway'
  fi

  # Act
  run --separate-stderr run_snippet \
    'printf "%s" "{\"a\":1}" | copy --debug --no-auto'

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == '{"a":1}' ]]
  assert_debug_event 'options-parsed' 'auto=0'
  refute_debug_event 'auto-detect-start'
}

@test "copy --type wins over auto-detection" {
  # Arrange
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq not installed'
  fi

  # Act: the payload looks like JSON, but the user says text/html.
  run --separate-stderr run_snippet \
    'printf "%s" "{\"a\":1}" | copy --debug --type text/html'

  # Assert
  ((status == 0))
  assert_debug_event 'options-parsed' 'mime=text/html'
  refute_debug_event 'auto-detect'
}

@test "copy --append turns auto-detection off" {
  # Arrange:
  # the clipboard holds text, and the new payload looks like JSON;
  # the old text and the new one together are no JSON document.
  set_clipboard 'prefix '

  # Act
  run --separate-stderr run_snippet \
    'printf "%s" "{\"a\":1}" | copy --debug --append'

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == 'prefix {"a":1}' ]]
  assert_debug_event 'options-validated' 'auto=0'
  refute_debug_event 'auto-detect-start'
}

@test "copy writes a text payload larger than a pipe buffer byte for byte" {
  # Arrange:
  # auto-detection reads only the start of the payload,
  # and a pipe holds 64 KiB, so the payload is far larger.
  local -r payload_path="${BATS_TEST_TMPDIR}/large.txt"
  printf 'line %06d of a large payload\n' {1..10000} >"${payload_path}"

  # Act
  run --separate-stderr run_snippet "copy <${payload_path@Q}"

  # Assert
  ((status == 0))
  cmp -- "${payload_path}" "${FAKE_CLIPBOARD_FILE}"
}

# endregion Auto-detection

# region Images

@test "copy --image writes binary bytes as they are, as image/png" {
  # Arrange: the 8 bytes of the PNG signature.

  # Act
  run --separate-stderr run_snippet \
    'printf "\x89PNG\r\n\x1a\n" | copy --debug --image'

  # Assert
  ((status == 0))
  assert_debug_event 'options-parsed' 'mime=image/png' 'raw=1'
  [[ "$(print_clipboard_hex)" == '89504e470d0a1a0a' ]]
}

@test "past --image prints binary bytes as they are, NUL bytes too" {
  # Arrange:
  # the newline fix of wl-paste goes through $(...), which loses NUL bytes,
  # so an image must skip it.
  local -r output_path="${BATS_TEST_TMPDIR}/past-image.bin"
  printf 'a\x00b' >"${FAKE_CLIPBOARD_FILE}"

  # Act:
  # the output goes to a file, since a variable cannot hold NUL bytes.
  past --image >"${output_path}"

  # Assert: a, NUL, b.
  [[ "$(print_hex <"${output_path}")" == '610062' ]]
}

# endregion Images

# region Options that do not fit together

#######################################
# Check that an option for text refuses --image, with its message.
#
# Arguments:
#   1: The option: --append or --trim.
#######################################
function text_option_refuses_image() {
  # Arrange
  local -r option="$1"

  # Act
  run --separate-stderr run_snippet "printf 'x' | copy ${option} --image"

  # Assert
  ((status == COPY_ERR_TYPE_MISMATCH))
  [[ "${stderr}" == *"${option} is only valid for text payloads"* ]]
}

for option_name in --append --trim; do
  bats_test_function \
    --description "copy ${option_name} --image fails with the type-mismatch code" \
    -- text_option_refuses_image "${option_name}"
done

# endregion Options that do not fit together

### End
