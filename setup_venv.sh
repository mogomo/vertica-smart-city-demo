#!/usr/bin/env bash
#
# setup_venv.sh - one-time setup of the Python environment for the Smart Fleet VerticaPy notebook.
#
# Creates the virtual environment  ~/.venvs/smart-fleet-demo,
# which gives you the usual        ~/.venvs/smart-fleet-demo/bin/activate
# then installs VerticaPy + JupyterLab into it. Nothing is written outside that directory.
#
#   ./setup_venv.sh                         # default location
#   VENV_DIR=/some/other/path ./setup_venv.sh
#   PYTHON=python3.11 ./setup_venv.sh       # force a specific interpreter
#
# Works on the Vertica Linux host (as dbadmin) and on macOS. Needs Python 3.9+ and access to PyPI.
# Safe to re-run: an existing environment is kept and only updated.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${VENV_DIR:-$HOME/.venvs/smart-fleet-demo}"
REQ="$HERE/requirements.txt"
[ -f "$REQ" ] || { echo "ERROR: $REQ not found - keep setup_venv.sh next to requirements.txt"; exit 1; }

# ---- 1. find a suitable Python (3.9 or newer; 3.10 - 3.13 preferred) --------------------------------
ok_python() { "$1" -c 'import sys; sys.exit(0 if (3, 9) <= sys.version_info[:2] else 1)' 2>/dev/null; }
PY=""
for cand in ${PYTHON:-} python3.12 python3.11 python3.13 python3.10 python3.9 python3; do
    if command -v "$cand" >/dev/null 2>&1 && ok_python "$cand"; then PY="$(command -v "$cand")"; break; fi
done

# ---- 2. create the environment (this is what writes bin/activate) -----------------------------------
if [ -x "$VENV_DIR/bin/python" ]; then
    echo ">>> Re-using existing environment: $VENV_DIR"
elif [ -n "$PY" ]; then
    echo ">>> Creating $VENV_DIR with $PY ($("$PY" --version 2>&1))"
    mkdir -p "$(dirname "$VENV_DIR")"
    "$PY" -m venv "$VENV_DIR"                 # prompt = directory name: (smart-fleet-demo)
elif command -v uv >/dev/null 2>&1; then
    echo ">>> No Python 3.9+ on the PATH - letting uv provide Python 3.12"
    mkdir -p "$(dirname "$VENV_DIR")"
    uv venv --python 3.12 --seed "$VENV_DIR"
else
    echo "ERROR: no Python 3.9+ found. Install one (RHEL/Rocky: sudo dnf install python3.11 ; Ubuntu: sudo apt install python3-venv)"
    echo "       or point to it:  PYTHON=/path/to/python3.x ./setup_venv.sh"
    exit 1
fi

# ---- 3. install the packages ------------------------------------------------------------------------
echo ">>> Installing packages from requirements.txt (a few minutes on the first run) ..."
"$VENV_DIR/bin/python" -m pip install --quiet --upgrade pip
"$VENV_DIR/bin/python" -m pip install --quiet -r "$REQ"

# ---- 4. report --------------------------------------------------------------------------------------
"$VENV_DIR/bin/python" - <<'EOF'
from importlib.metadata import version
import sys
print(">>> Ready: Python %d.%d.%d" % sys.version_info[:3], "|",
      " | ".join("%s %s" % (p, version(p)) for p in ("verticapy", "vertica-python", "plotly", "jupyterlab")))
EOF
cat <<EOF

Environment : $VENV_DIR
Activate    : source $VENV_DIR/bin/activate        (leave with: deactivate)
Start       : $HERE/start_jupyter.sh
EOF
