#!/usr/bin/env bats

# Tests the format of the debug log that copy.sh and past.sh print.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
}

@test "__cp_debug prints nothing when the log is off" {
  # Arrange: 0 turns the log off.

  # Act
  run --separate-stderr __cp_debug 0 'should-not-fire' 'key=value'

  # Assert
  ((status == 0))
  [[ -z "${stderr}" ]]
  [[ -z "${output}" ]]
}

@test "__cp_debug prints the event and its fields on one line" {
  # Arrange: 1 turns the log on.

  # Act
  run --separate-stderr __cp_debug 1 'sample' 'k1=v1' 'k2=v2'

  # Assert
  [[ "${stderr}" == '[copy debug] event=sample k1=v1 k2=v2' ]]
}

@test "__cp_debug quotes a value that holds whitespace" {
  # Arrange: one plain value, one with a space.

  # Act
  run --separate-stderr __cp_debug 1 'spacy' 'plain=ok' 'with-space=hello world'

  # Assert
  [[ "${stderr}" == "[copy debug] event=spacy plain=ok with-space='hello world'" ]]
}

@test "__cp_debug prints a bare event when no field follows" {
  # Arrange: the event alone.

  # Act
  run --separate-stderr __cp_debug 1 'lone-event'

  # Assert
  [[ "${stderr}" == '[copy debug] event=lone-event' ]]
}

@test "__ps_debug prints the prefix of past" {
  # Arrange: 1 turns the log on.

  # Act
  run --separate-stderr __ps_debug 1 'p-event' 'k=v'

  # Assert
  [[ "${stderr}" == '[past debug] event=p-event k=v' ]]
}

### End
