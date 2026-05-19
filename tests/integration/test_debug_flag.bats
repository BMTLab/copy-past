#!/usr/bin/env bats

# Name: tests/integration/test_debug_flag.bats
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   End-to-end coverage for the --debug / -d / --verbose flag
#   on `copy` and `past`.
#   These tests rely on the structured log format
#   ('[copy debug] event=NAME key=value ...')
#   to assert internal decisions
#   without resorting to argv-recording shims.
#
#   Each test follows the Arrange-Act-Assert (AAA) pattern.
#
#   Coverage:
#     - silence by default
#       (no debug flag -> zero stderr noise from internals)
#     - flag synonyms (-d, --debug, --verbose)
#     - phase coverage on `copy`
#       (options-parsed, options-validated, backend-resolved,
#        auto-detect, prelude-captured, pipeline-start, done)
#     - phase coverage on `past`
#       (options-parsed, mime-classified, backend-resolved,
#        read-strategy)
#
# Disclaimer:
#   This script is provided 'as is', without any warranty.

bats_require_minimum_version 1.5.0

load '../support/test_helper.bash'

setup() {
  __cp_setup_fake_backend
  __cp_load_scripts
}


# region Silence by default

@test "copy emits no '[copy debug]' lines without --debug" {
  # Arrange / Act
  run --separate-stderr __cp_run 'printf "%s" "hello" | copy'

  # Assert
  [ "$status" -eq 0 ]
  ! grep -q '\[copy debug\]' <<< "$stderr"
}

@test "past emits no '[past debug]' lines without --debug" {
  # Arrange
  __cp_clipboard_set 'hello'

  # Act
  run --separate-stderr past

  # Assert
  [ "$status" -eq 0 ]
  ! grep -q '\[past debug\]' <<< "$stderr"
}

@test "auto-detected JSON does NOT print anything on stderr without --debug" {
  # Arrange:
  # this is a regression guard for the old `::notice title=copy::`
  # line that used to fire unconditionally on auto-detection
  # and broke shell pipelines that captured stderr.
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq not installed; auto-detect path requires jq'
  fi

  # Act
  run --separate-stderr __cp_run 'printf "%s" "{\"k\":1}" | copy'

  # Assert
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# endregion


# region Synonyms

@test "copy --debug, -d, --verbose all activate logging" {
  # Arrange
  local form
  for form in --debug -d --verbose; do
    # Act
    run --separate-stderr __cp_run "printf '%s' 'x' | copy ${form}"

    # Assert
    [ "$status" -eq 0 ] || {
      printf 'form=%s status=%d\n' "$form" "$status" >&2
      false
    }
    grep -q '^\[copy debug\] event=options-parsed' <<< "$stderr" \
      || {
        printf 'form=%s missed options-parsed line\n' "$form" >&2
        printf '%s\n' "$stderr" >&2
        false
      }
  done
}

@test "past --debug, -d, --verbose all activate logging" {
  # Arrange
  __cp_clipboard_set 'data'
  local form

  for form in --debug -d --verbose; do
    # Act
    run --separate-stderr past "$form"

    # Assert
    [ "$status" -eq 0 ]
    grep -q '^\[past debug\] event=options-parsed' <<< "$stderr" \
      || {
        printf 'form=%s missed options-parsed line\n' "$form" >&2
        printf '%s\n' "$stderr" >&2
        false
      }
  done
}

# endregion


# region copy phase coverage

@test "copy --debug logs every phase event for a plain text payload" {
  # Arrange / Act
  run --separate-stderr __cp_run \
    'printf "%s" "hi" | copy --debug --no-auto'

  # Assert
  [ "$status" -eq 0 ]
  __cp_assert_debug_event 'options-parsed' 'auto=0' 'mime=<none>'
  __cp_assert_debug_event 'options-validated' 'auto=0'
  __cp_assert_debug_event 'backend-resolved' 'backend=wl-copy'
  __cp_assert_debug_event 'pipeline-start' 'mode=pipe'
  __cp_assert_debug_event 'done' 'mode=pipeline'
}

@test "copy --debug reports auto-detected MIME for JSON" {
  # Arrange
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq not installed; auto-detect path requires jq'
  fi

  # Act
  run --separate-stderr __cp_run \
    'printf "%s" "{\"k\":1}" | copy --debug'

  # Assert:
  # the auto-detect helper should fire and classify the payload
  # as application/json, then drive the binary fast-path
  # (bypass-the-pipeline branch).
  [ "$status" -eq 0 ]
  __cp_assert_debug_event 'auto-detect-start'
  __cp_assert_debug_event 'auto-detect' 'mime=application/json'
  __cp_assert_debug_event 'auto-detect-binary' \
    'mime=application/json' 'action=stream-buffer'
  __cp_assert_debug_event 'done' 'mode=auto-binary'
}

@test "copy --debug reports auto-detected MIME for PNG bytes" {
  # Arrange / Act
  run --separate-stderr __cp_run \
    'printf "\x89PNG\r\n\x1a\nrest" | copy --debug'

  # Assert
  [ "$status" -eq 0 ]
  __cp_assert_debug_event 'auto-detect' 'mime=image/png'
  __cp_assert_debug_event 'auto-detect-binary' 'mime=image/png'
}

@test "copy --debug logs the text fall-through when payload is plain" {
  # Arrange / Act
  run --separate-stderr __cp_run \
    'printf "%s" "plain text" | copy --debug'

  # Assert:
  # plain text means the auto-detect helper picks text/plain,
  # falls through to the normal pipeline,
  # and the orchestrator finishes with mode=pipeline.
  [ "$status" -eq 0 ]
  __cp_assert_debug_event 'auto-detect' 'mime=text/plain'
  __cp_assert_debug_event 'auto-detect-text' \
    'action=fall-through-to-pipeline'
  __cp_assert_debug_event 'done' 'mode=pipeline'
}

@test "copy --debug --append surfaces the prelude-captured event" {
  # Arrange
  __cp_clipboard_set 'first '

  # Act
  run --separate-stderr __cp_run \
    'printf "%s" "second" | copy --append --debug'

  # Assert:
  # validate phase must flip auto=0 because of --append (text-only),
  # and we must see a prelude-captured event with a real path.
  [ "$status" -eq 0 ]
  __cp_assert_debug_event 'options-parsed' 'append=1'
  __cp_assert_debug_event 'options-validated' 'auto=0'
  __cp_assert_debug_event 'prelude-captured'
  [ "$(__cp_clipboard_dump)" = 'first second' ]
}

@test "copy --debug pipeline-start uses mode=argument when stdin is a tty" {
  # Arrange:
  # write the captured stderr into a sideband file
  # because the pty wrapper rewrites LFs to CRLFs.
  local -r stderr_file="${BATS_TEST_TMPDIR}/argv.stderr"

  # Act
  __cp_run_with_tty "
    source '${COPY_PAST_ROOT}/copy.sh'
    copy --debug --no-auto hello world 2> '${stderr_file}'
  " >/dev/null

  # Assert
  grep -q '^\[copy debug\] event=pipeline-start mode=argument' \
    "$stderr_file"
  [ "$(__cp_clipboard_dump)" = 'hello world' ]
}

# endregion


# region past phase coverage

@test "past --debug logs every phase event for a plain text payload" {
  # Arrange
  __cp_clipboard_set 'data'

  # Act
  run --separate-stderr past --debug

  # Assert
  [ "$status" -eq 0 ]
  __cp_assert_debug_event 'options-parsed' 'mime=<none>'
  __cp_assert_debug_event 'mime-classified' 'is-binary=0'
  __cp_assert_debug_event 'backend-resolved' 'backend=wl-paste'
  __cp_assert_debug_event 'read-strategy' \
    'mode=wl-paste-newline-strip'
}

@test "past --debug --image picks the direct-exec read strategy" {
  # Arrange
  __cp_clipboard_set 'binary-bytes'

  # Act
  run --separate-stderr past --image --debug

  # Assert:
  # binary MIME must bypass the trailing-newline workaround,
  # because that path goes through $() and corrupts NULs.
  [ "$status" -eq 0 ]
  __cp_assert_debug_event 'mime-classified' 'is-binary=1'
  __cp_assert_debug_event 'read-strategy' 'mode=direct-exec'
}

# endregion


# region Stable line format

@test "debug lines start with '[copy debug] event=' and use space-separated kv" {
  # Arrange / Act
  run --separate-stderr __cp_run \
    'printf "%s" "x" | copy --debug --no-auto'

  # Assert:
  # every emitted line must follow the format contract,
  # so external tooling can rely on it.
  local line
  while IFS= read -r line; do
    [[ "$line" =~ ^\[copy\ debug\]\ event=[a-zA-Z0-9_-]+(\ |$) ]] \
      || {
        printf 'Malformed line: %s\n' "$line" >&2
        false
      }
  done < <(grep '^\[copy debug\]' <<< "$stderr")
}

# endregion

### End of file
