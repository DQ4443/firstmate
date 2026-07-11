#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /absolute/path/to/source.txt" >&2
  exit 64
fi

case "$1" in
  /*) ;;
  *)
    echo "source path must be absolute" >&2
    exit 64
    ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
state_dir="$repo_root/state/rig"

mkdir -p "$state_dir"
python3 "$script_dir/source-audit.py" "$1" --setup "$state_dir"
python3 "$script_dir/generate-atlas.py" --repo-root "$repo_root" --state-dir "$state_dir"

echo "full_atlas=$state_dir/rig-atlas.md"
echo "portable_twin=BLOCKED"
