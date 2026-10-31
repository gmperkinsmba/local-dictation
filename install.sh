#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$ROOT/dist/Local Dictation.app"
DEST="$HOME/Applications/Local Dictation.app"

if [ ! -x "$SOURCE/Contents/MacOS/LocalDictation" ]; then
  echo "Build the app first with ./build.sh." >&2
  exit 2
fi

exec python3 "$ROOT/install_security.py" \
  --source "$SOURCE" \
  --destination "$DEST" \
  --bundle-id "com.gmperkinsmba.fisprwlow"
