#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# Mac and Linux: the board is the app (there is no tray note). Opens in the browser.
exec node start-background.mjs
