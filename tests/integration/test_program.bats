#!/usr/bin/env bats

# Tests copy.sh and past.sh run as programs, as their installed links run them.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
}

# region copy

@test "copy run as a program prints its help and exits 0" {
  # Arrange: the program is the file itself.

  # Act
  run --separate-stderr "${COPY_PAST_ROOT}/copy.sh" --help

  # Assert
  ((status == 0))
  [[ "${output}" == *'copy - write'*'system clipboard'* ]]
}

@test "copy run as a program writes piped bytes to the clipboard" {
  # Arrange
  local -r payload_path="${BATS_TEST_TMPDIR}/payload.txt"
  printf 'line1\nline2\n' >"${payload_path}"

  # Act
  run --separate-stderr "${COPY_PAST_ROOT}/copy.sh" <"${payload_path}"

  # Assert
  ((status == 0))
  [[ "$(print_clipboard_hex)" == '6c696e65310a6c696e65320a' ]]
}

@test "copy run as a program appends with the past.sh beside it" {
  # Arrange:
  # no function past exists in a program,
  # so copy runs the past.sh next to copy.sh.
  local -r payload_path="${BATS_TEST_TMPDIR}/payload.txt"
  set_clipboard 'old '
  printf '%s' 'new' >"${payload_path}"

  # Act
  run --separate-stderr "${COPY_PAST_ROOT}/copy.sh" --append <"${payload_path}"

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == 'old new' ]]
}

@test "copy run as a program exits with the usage code on an unknown option" {
  # Arrange: --bogus is no option of copy.

  # Act
  run --separate-stderr "${COPY_PAST_ROOT}/copy.sh" --bogus

  # Assert
  ((status == COPY_ERR_USAGE))
  [[ "${stderr}" == *'unknown option'* ]]
}

@test "copy run as a program exits with the backend code when the backend fails" {
  # Arrange
  local -r payload_path="${BATS_TEST_TMPDIR}/payload.txt"
  install_failing_wl_copy 7
  printf '%s' 'data' >"${payload_path}"

  # Act
  run --separate-stderr "${COPY_PAST_ROOT}/copy.sh" <"${payload_path}"

  # Assert
  ((status == COPY_ERR_BACKEND_FAILED))
  [[ "${stderr}" == *'clipboard backend failed'* ]]
}

@test "copy run as a program exits with the no-backend code without a backend" {
  # Arrange:
  # PATH holds one empty directory, so no backend is found,
  # and bash runs the file, since env cannot find bash on that PATH.
  local -r empty_bin="${BATS_TEST_TMPDIR}/empty-bin"
  local bash_path
  bash_path="$(command -v bash)"
  mkdir -p -- "${empty_bin}"

  # Act
  run --separate-stderr env -i HOME="${HOME}" PATH="${empty_bin}" \
    "${bash_path}" "${COPY_PAST_ROOT}/copy.sh" <<<'data'

  # Assert
  ((status == COPY_ERR_NO_BACKEND))
  [[ "${stderr}" == *'no clipboard backend found'* ]]
}

# endregion copy

# region past

@test "past run as a program prints the clipboard byte for byte" {
  # Arrange:
  # the output goes to a file,
  # since a capture by run would drop the trailing newline.
  local -r output_path="${BATS_TEST_TMPDIR}/past.out"
  set_clipboard $'line1\nline2\n'

  # Act
  "${COPY_PAST_ROOT}/past.sh" >"${output_path}"

  # Assert
  [[ "$(print_hex <"${output_path}")" == '6c696e65310a6c696e65320a' ]]
}

@test "past run as a program exits with the usage code on an argument" {
  # Arrange: past takes no positional argument.

  # Act
  run --separate-stderr "${COPY_PAST_ROOT}/past.sh" stray

  # Assert
  ((status == PAST_ERR_USAGE))
  [[ "${stderr}" == *'unknown argument'* ]]
}

@test "past run as a program exits with the backend code when the backend fails" {
  # Arrange
  set_clipboard 'data'
  export FAKE_WL_PASTE_CODE=42

  # Act
  run --separate-stderr "${COPY_PAST_ROOT}/past.sh"

  # Assert
  ((status == PAST_ERR_BACKEND_FAILED))
  [[ "${stderr}" == *'clipboard backend failed to read'* ]]
}

@test "past run as a program exits with the no-backend code without a backend" {
  # Arrange
  local -r empty_bin="${BATS_TEST_TMPDIR}/empty-bin"
  local bash_path
  bash_path="$(command -v bash)"
  mkdir -p -- "${empty_bin}"

  # Act
  run --separate-stderr env -i HOME="${HOME}" PATH="${empty_bin}" \
    "${bash_path}" "${COPY_PAST_ROOT}/past.sh"

  # Assert
  ((status == PAST_ERR_NO_BACKEND))
  [[ "${stderr}" == *'no clipboard backend found'* ]]
}

# endregion past

### End
