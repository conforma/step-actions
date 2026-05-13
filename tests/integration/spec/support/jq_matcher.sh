#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

shellspec_syntax 'shellspec_matcher_jq'

shellspec_matcher_jq() {
  shellspec_matcher__match() {
    SHELLSPEC_EXPECT="$1"
    [ "${SHELLSPEC_SUBJECT+x}" ] || return 1
    printf '%s\n' "${SHELLSPEC_SUBJECT}" | jq --exit-status "${SHELLSPEC_EXPECT}" > /dev/null || return 1
    return 0
  }

  shellspec_matcher__failure_message() {
    shellspec_putsn "expected: JSON $1 should evaluate with success against jq expression: $2"
  }

  shellspec_matcher__failure_message_when_negated() {
    shellspec_putsn "expected: JSON $1 should not evaluate with success against jq expression: $2"
  }

  shellspec_syntax_param count [ $# -eq 1 ] || return 0
  shellspec_matcher_do_match "$@"
}
