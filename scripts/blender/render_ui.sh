#!/bin/bash
# Re-renders the static UI plates into Resources/UI (Blender 4.2+ headless). Not part of build.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}" -b --factory-startup -P "$ROOT/scripts/blender/render_ui.py" -- "$ROOT/Resources/UI"
