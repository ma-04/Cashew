#!/usr/bin/env bash
# Runs the Firefly tests on the build server. Local Flutter cannot resolve the
# dependencies, and the live Firefly III test instance is reachable only from
# that server.
#
# Usage, from any directory:
#   tool/firefly_remote_test.sh [flutter test arguments]
#   tool/firefly_remote_test.sh test/firefly/
#   tool/firefly_remote_test.sh test/firefly/live/ --tags live
#   tool/firefly_remote_test.sh --analyze
#
# With no arguments it runs `flutter test` on the full suite. The exit code is
# the exit code of `flutter test` or `flutter analyze`.
#
# Environment:
#   FIREFLY_REMOTE_HOST  default fly@167.235.51.86
#   FIREFLY_REMOTE_SRC   the repository root to send, default the root of this
#                        checkout. Set it to an export of a commit to test that
#                        commit while the working tree does not compile.
set -euo pipefail

HOST="${FIREFLY_REMOTE_HOST:-fly@167.235.51.86}"
# The server holds other checkouts. Use these two directories only.
REMOTE_APP="firefly-review"
REMOTE_TEST="firefly-test"

REPO_ROOT="${FIREFLY_REMOTE_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

MODE="test"
if [ "${1:-}" = "--analyze" ]; then
  MODE="analyze"
  shift
fi

# The .env file holds the token of the production server. It must not leave
# this machine.
rsync -az --delete \
  --exclude '.git' \
  --exclude 'build' \
  --exclude '.dart_tool' \
  --exclude 'budget/.dart_tool' \
  --exclude '.env' \
  --exclude '*_out.txt' \
  --exclude '.flutter-plugins*' \
  "$REPO_ROOT/" "$HOST:$REMOTE_APP/"

# ssh joins its arguments into one command line for the remote shell. printf
# %q quotes each argument, so that shell splits them as they were given.
ARGS=""
if [ "$#" -gt 0 ]; then
  ARGS="$(printf '%q ' "$@")"
fi

# ssh returns the exit code of the remote script.
# shellcheck disable=SC2086
ssh "$HOST" bash -s -- "$MODE" "$REMOTE_APP" "$REMOTE_TEST" $ARGS <<'REMOTE'
set -euo pipefail
MODE="$1"
APP="$HOME/$2"
TESTENV="$HOME/$3"
shift 3
cd "$APP/budget"

# rsync keeps the modification times, thus a pubspec that is newer than the
# package config is a pubspec that changed.
CONFIG=".dart_tool/package_config.json"
if [ ! -f "$CONFIG" ] || [ pubspec.yaml -nt "$CONFIG" ] ||
   { [ -f pubspec.lock ] && [ pubspec.lock -nt "$CONFIG" ]; }; then
  flutter pub get >/dev/null
  touch "$CONFIG"
fi

if [ "$MODE" = "analyze" ]; then
  exec flutter analyze --no-fatal-infos --no-fatal-warnings \
    lib/struct/firefly test/firefly "$@"
fi

# The live tests skip when FIREFLY_LIVE_URL is not set. The reset script
# needs an absolute path, because Process.run does not expand "~".
if [ -f "$TESTENV/env.sh" ]; then
  . "$TESTENV/env.sh"
  export FIREFLY_LIVE_URL FIREFLY_LIVE_TOKEN
  export FIREFLY_LIVE_RESET="$TESTENV/reset.sh"
fi

# The live tests share one server, and each test resets it. Two test files
# that run at the same time reset it under each other. Thus one file at a
# time whenever the live tests can be part of the run.
concurrency=()
case " $* " in
  *" --exclude-tags live "*|*" -x live "*) ;;
  *) if [ $# -eq 0 ] || printf '%s\n' "$@" | grep -q 'test/firefly/live\|^test/\?$\|^test/firefly/\?$\|live'; then
       concurrency=(--concurrency=1)
     fi ;;
esac
exec flutter test "${concurrency[@]}" "$@"
REMOTE
