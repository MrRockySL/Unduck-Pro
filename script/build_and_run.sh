#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="duck-audio-phase0"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
APP_BINARY="$(swift build --show-bin-path)/$APP_NAME"

case "$MODE" in
  run)
    "$APP_BINARY" "${@:2}"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY" "${@:2}"
    ;;
  --logs|logs)
    "$APP_BINARY" "${@:2}" &
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    "$APP_BINARY" "${@:2}" &
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"dev.mrrockysl.duckaudio\""
    ;;
  --verify|verify)
    "$APP_BINARY" --duration 2 --interval 1 >/tmp/duck-audio-phase0-verify.log &
    wait $!
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify] [phase0 args]" >&2
    exit 2
    ;;
esac
