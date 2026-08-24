#!/bin/sh
# Overlay Johnson Electric assets onto Open WebUI 0.9.5 static files: the icon
# goes onto favicons and avatars, the logo onto the splash screens.
# `logo.png` is listed in both sets and the icon deliberately wins.
# Idempotent. Safe to re-run after pip install.
set -eu

OPEN_WEBUI_ROOT=/sandbox/open-webui
ICON="$OPEN_WEBUI_ROOT/company-icon.png"
LOGO="$OPEN_WEBUI_ROOT/company-logo.png"
PY="$OPEN_WEBUI_ROOT/.venv/bin/python"

if [ ! -x "$PY" ]; then
  echo "Open WebUI venv missing; skip branding" >&2
  exit 0
fi
if [ ! -f "$ICON" ] && [ ! -f "$LOGO" ]; then
  echo "No company-icon.png / company-logo.png; skip branding"
  exit 0
fi

"$PY" - "$ICON" "$LOGO" <<'PY'
import pathlib
import shutil
import sys

icon = pathlib.Path(sys.argv[1]) if sys.argv[1] else None
logo = pathlib.Path(sys.argv[2]) if sys.argv[2] else None
if icon and not icon.is_file():
    icon = None
if logo and not logo.is_file():
    logo = None

import open_webui
root = pathlib.Path(open_webui.__file__).resolve().parent

icon_names = {
    "favicon.png",
    "favicon-96x96.png",
    "apple-touch-icon.png",
    "logo.png",
    "user.png",
    "user-import.png",
}
logo_names = {
    "splash.png",
    "splash-dark.png",
    "logo.png",
}

replaced = 0
for path in root.rglob("*"):
    if not path.is_file():
        continue
    name = path.name.lower()
    src = None
    if icon and name in icon_names:
        src = icon
    elif logo and name in logo_names:
        src = logo
    if src is None:
        continue
    shutil.copyfile(src, path)
    replaced += 1
    print(f"branded {path.relative_to(root)}")

print(f"branding done ({replaced} files)")
PY
