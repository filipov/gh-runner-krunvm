#!/bin/sh

# Shell sanity. Stop on errors and undefined variables.
set -eu

# This is a readlink -f implementation so this script can (perhaps) run on MacOS
abspath() {
  is_abspath() {
    case "$1" in
      /* | ~*) true;;
      *) false;;
    esac
  }

  if [ -d "$1" ]; then
    ( cd -P -- "$1" && pwd -P )
  elif [ -L "$1" ]; then
    if is_abspath "$(readlink "$1")"; then
      abspath "$(readlink "$1")"
    else
      abspath "$(dirname "$1")/$(readlink "$1")"
    fi
  else
    printf %s\\n "$(abspath "$(dirname "$1")")/$(basename "$1")"
  fi
}

# Resolve the root directory hosting this script to an absolute path, symbolic
# links resolved.
RUNNER_ROOTDIR=$( cd -P -- "$(dirname -- "$(command -v -- "$(abspath "$0")")")" && pwd -P )

# Level of verbosity, the higher the more verbose. All messages are sent to the
# stderr.
RUNNER_VERBOSE=${RUNNER_VERBOSE:-0}

# Where to send logs
RUNNER_LOG=${RUNNER_LOG:-2}

# GitHub host, e.g. github.com or github.example.com
RUNNER_GITHUB=${RUNNER_GITHUB:-"github.com"}

# Group to attach the runner to
RUNNER_GROUP=${RUNNER_GROUP:-"Default"}

# Comma separated list of labels to attach to the runner (good defaults will be used if empty)
RUNNER_LABELS=${RUNNER_LABELS:-""}

# Name of the user to run the runner as, defaults to root. User must exist.
RUNNER_USER=${RUNNER_USER:-"runner"}

# Scope of the runner, one of: repo, org or enterprise
RUNNER_SCOPE=${RUNNER_SCOPE:-"repo"}

# Name of organisation, enterprise or repo to attach the runner to, when
# relevant scope.
RUNNER_PRINCIPAL=${RUNNER_PRINCIPAL:-""}

# PAT to acquire runner token with
RUNNER_PAT=${RUNNER_PAT:-""}

# Should the runner auto-update
RUNNER_UPDATE=${RUNNER_UPDATE:-"0"}

# Name of the microVM to run from
RUNNER_NAME=${RUNNER_NAME:-"runner"}

# Name of top directory in VM where to host a copy of the root directory of this
# script. When this is set, the runner starter script from that directory will
# be used -- instead of the one already in the OCI image. This option is mainly
# usefull for development and testing.
RUNNER_DIR=${RUNNER_DIR:-""}

RUNNER_MOUNT=${RUNNER_MOUNT:-""}

# Location (at host) where to place environment files for each run.
RUNNER_ENVIRONMENT=${RUNNER_ENVIRONMENT:-""}

# Should the runner be ephemeral, i.e. only run once. There is no CLI option for
# this, since the much preferred behaviour is to run ephemeral runners.
RUNNER_EPHEMERAL=${RUNNER_EPHEMERAL:-"1"}

# shellcheck source=lib/common.sh
. "$RUNNER_ROOTDIR/lib/common.sh"

# shellcheck disable=SC2034 # Used in sourced scripts
KRUNVM_RUNNER_DESCR="Create runners forever using krunvm"


while getopts "D:E:g:G:l:L:M:n:p:s:T:u:Uvh-" opt; do
  case "$opt" in
    D) # Local top VM directory where to host a copy of the root directory of this script (for dev and testing).
      RUNNER_DIR=$OPTARG;;
    E) # Location (at host) where to place environment files for each run.
      RUNNER_ENVIRONMENT="$OPTARG";;
    g) # GitHub host, e.g. github.com or github.example.com
      RUNNER_GITHUB="$OPTARG";;
    G) # Group to attach the runner to
      RUNNER_GROUP="$OPTARG";;
    l) # Where to send logs
      RUNNER_LOG="$OPTARG";;
    L) # Comma separated list of labels to attach to the runner
      RUNNER_LABELS="$OPTARG";;
    M) # Mount passed to the microVM
      RUNNER_MOUNT="$OPTARG";;
    n) # Name of the microVM to run from
      RUNNER_NAME="$OPTARG";;
    p) # Principal to authorise the runner for, name of repo, org or enterprise
      RUNNER_PRINCIPAL="$OPTARG";;
    s) # Scope of the runner, one of repo, org or enterprise
      RUNNER_SCOPE="$OPTARG";;
    T) # Authorization token at the GitHub API to acquire runner token with
      RUNNER_PAT="$OPTARG";;
    u) # User to run the runner as
      RUNNER_USER="$OPTARG";;
    U) # Turn on auto-updating of the runner
      RUNNER_UPDATE=1;;
    v) # Increase verbosity, will otherwise log on errors/warnings only
      RUNNER_VERBOSE=$((RUNNER_VERBOSE+1));;
    h) # Print help and exit
      usage;;
    -) # End of options, follows the identifier of the runner, if any
      break;;
    ?)
      usage 1;;
  esac
done
shift $((OPTIND-1))

# Pass logging configuration and level to imported scripts
KRUNVM_RUNNER_LOG=$RUNNER_LOG
KRUNVM_RUNNER_VERBOSE=$RUNNER_VERBOSE
loop=${1:-}
if [ -n "${loop:-}" ]; then
  KRUNVM_RUNNER_BIN=$(basename "$0")
  KRUNVM_RUNNER_BIN="${KRUNVM_RUNNER_BIN%.sh}-$loop"
fi

# Decide which runner.sh implementation (this is the "entrypoint" of the
# microVM) to use: the one from the mount point, or the built-in one.
if [ -z "$RUNNER_DIR" ]; then
  runner=/opt/gh-runner-krunvm/bin/runner.sh
else
  check_command "${RUNNER_ROOTDIR}/runner/runner.sh"
  runner=${RUNNER_DIR%/}/runner/runner.sh
fi

while true; do
  id=$(random_string)
  RUNNER_ID=${loop}-${id}
  verbose "Starting microVM $RUNNER_NAME to run ephemeral GitHub runner $RUNNER_ID"
  if [ -n "$RUNNER_ENVIRONMENT" ]; then
    # Create an env file with most of the RUNNER_ variables. This works because
    # the `runner.sh` script that will be called uses the same set of variables.
    verbose "Creating isolation environment ${RUNNER_ENVIRONMENT}/${RUNNER_ID}.env"
    while IFS= read -r varset; do
      # shellcheck disable=SC2163 # We want to expand the variable
      printf '%s\n' "$varset" >> "${RUNNER_ENVIRONMENT}/${RUNNER_ID}.env"
    done <<EOF
$(set | grep '^RUNNER_' | grep -vE '(ROOTDIR|ENVIRONMENT|NAME|MOUNT)')
EOF

    set -- -E "/_environment/${RUNNER_ID}.env"
  else
    set -- \
        -e \
        -g "$RUNNER_GITHUB" \
        -G "$RUNNER_GROUP" \
        -i "$RUNNER_ID" \
        -l "$RUNNER_LOG" \
        -L "$RUNNER_LABELS" \
        -p "$RUNNER_PRINCIPAL" \
        -s "$RUNNER_SCOPE" \
        -T "$RUNNER_PAT" \
        -u "$RUNNER_USER"
    for _ in $(seq 1 "$RUNNER_VERBOSE"); do
      set -- -v "$@"
    done
  fi
  run_krunvm start "$RUNNER_NAME" "$runner" -- "$@"
done