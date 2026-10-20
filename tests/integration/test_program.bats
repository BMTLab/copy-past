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
  local -r payload_path="${BATS_TEST_TMPDIR}/payload.txt"

  # Arrange
  printf 'line1\nline2\n' >"${payload_path}"

  # Act
  run --separate-stderr "${COPY_PAST_ROOT}/copy.sh" <"${payload_path}"

  # Assert
  ((status == 0))
  [[ "$(print_clipboard_hex)" == '6c696e65310a6c696e65320a' ]]
}

@test "copy run as a program appends with the past.sh beside it" {
  local -r payload_path="${BATS_TEST_TMPDIR}/payload.txt"

  # Arrange:
  # no function past exists in a program,
  # so copy runs the past.sh next to copy.sh.
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
  local -r payload_path="${BATS_TEST_TMPDIR}/payload.txt"

  # Arrange
  install_failing_wl_copy 7
  printf '%s' 'data' >"${payload_path}"

  # Act
  run --separate-stderr "${COPY_PAST_ROOT}/copy.sh" <"${payload_path}"

  # Assert
  ((status == COPY_ERR_BACKEND_FAILED))
  [[ "${stderr}" == *'clipboard backend failed'* ]]
}

@test "copy run as a program exits with the no-backend code without a backend" {
  local -r empty_bin="${BATS_TEST_TMPDIR}/empty-bin"
  local bash_path

  # Arrange:
  # PATH holds one empty directory, so no backend is found,
  # and bash runs the file, since env cannot find bash on that PATH.
  bash_path="$(command -v bash)"
  mkdir -p -- "${empty_bin}"

  # Act
  run --separate-stderr env -i HOME="${HOME}" PATH="${empty_bin}" \
    "${bash_path}" "${COPY_PAST_ROOT}/copy.sh" <<<'data'

  # Assert
  ((status == COPY_ERR_NO_BACKEND))
  [[ "${stderr}" == *'no clipboard backend found'* ]]
}

@test "copy run as a program exits with the internal code when its cleanup fails" {
  local -r payload_path="${BATS_TEST_TMPDIR}/payload.txt"
  local -r broken_bin="${BATS_TEST_TMPDIR}/broken-bin"

  # Arrange:
  # copy removes its buffer itself, in its own body,
  # so an rm that fails there is a failure that no code plans for;
  # a check for the name copy once let its status 1 pass in silence.
  mkdir -p -- "${broken_bin}"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${broken_bin}/rm"
  chmod +x "${broken_bin}/rm"
  printf '%s' 'data' >"${payload_path}"

  # Act
  run --separate-stderr env PATH="${broken_bin}:${PATH}" \
    "${COPY_PAST_ROOT}/copy.sh" <"${payload_path}"

  # Assert
  ((status == COPY_ERR_INTERNAL))
  [[ "${stderr}" == *'copy: internal error at line '*'(status 1): command rm'* ]]
}

# endregion copy

# region past

@test "past run as a program prints the clipboard byte for byte" {
  local -r output_path="${BATS_TEST_TMPDIR}/past.out"

  # Arrange:
  # the output goes to a file,
  # since a capture by run would drop the trailing newline.
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
  local -r empty_bin="${BATS_TEST_TMPDIR}/empty-bin"
  local bash_path

  # Arrange
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
