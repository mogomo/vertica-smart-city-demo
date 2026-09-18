#!/usr/bin/env bash
#
# start_jupyter.sh - open the Smart Fleet VerticaPy notebook in JupyterLab.
#
#   ./start_jupyter.sh                 # port 8888
#   PORT=8890 ./start_jupyter.sh
#
# Run ./setup_venv.sh once before the first start. Stop Jupyter with Ctrl-C (twice).
#
# Database connection used by the notebook - override any of these before starting:
#   VERTICA_HOST (127.0.0.1)  VERTICA_PORT (5433)  VERTICA_DB (VDB)  VERTICA_USER (dbadmin)  VERTICA_PASSWORD (empty)
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTEBOOK="03_smart_fleet_verticapy.ipynb"
PORT="${PORT:-8888}"

# ---- 1. locate and activate the environment ---------------------------------------------------------
for dir in "${VENV_DIR:-}" "$HOME/.venvs/smart-fleet-demo" "$HERE/.venv"; do
    if [ -n "$dir" ] && [ -f "$dir/bin/activate" ] && [ -x "$dir/bin/jupyter" ]; then VENV="$dir"; break; fi
done
if [ -z "${VENV:-}" ]; then
    echo "No Python environment with Jupyter found. Run this once first:   $HERE/setup_venv.sh"; exit 1
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
echo ">>> Environment : $VENV"

# ---- 2. connection settings + a quick health check --------------------------------------------------
export VERTICA_HOST="${VERTICA_HOST:-127.0.0.1}" VERTICA_PORT="${VERTICA_PORT:-5433}" VERTICA_DB="${VERTICA_DB:-VDB}"
export VERTICA_USER="${VERTICA_USER:-dbadmin}" VERTICA_PASSWORD="${VERTICA_PASSWORD:-}"
echo ">>> Database    : $VERTICA_USER@$VERTICA_HOST:$VERTICA_PORT/$VERTICA_DB"
python - <<'EOF' || true
import os, warnings
warnings.filterwarnings("ignore")
import vertica_python
try:
    with vertica_python.connect(host=os.environ["VERTICA_HOST"], port=int(os.environ["VERTICA_PORT"]), database=os.environ["VERTICA_DB"],
                                user=os.environ["VERTICA_USER"], password=os.environ["VERTICA_PASSWORD"], tlsmode="prefer",
                                connection_timeout=5) as c:
        cur = c.cursor()
        cur.execute("select lower(table_name) from tables where lower(table_schema) = 'fleet' and lower(table_name) in ('telemetry', 'exec_kpi')")
        found = {r[0] for r in cur.fetchall()}
    if "telemetry" not in found:
        print("!!! Connected, but schema FLEET is missing  -> run 01_smart_fleet_setup.sql, then 02_smart_fleet_analytics.sql")
    elif "exec_kpi" not in found:
        print("!!! Connected, but the KPI marts are missing -> run 02_smart_fleet_analytics.sql before the notebook")
    else:
        print(">>> Connection OK, demo data and KPI marts are in place")
except Exception as exc:
    print("!!! Cannot reach Vertica (%s)" % str(exc).splitlines()[0][:120])
    print("    On a laptop, open the tunnel first:  ssh -L 5433:127.0.0.1:5433 dbadmin@<VM IP>")
EOF

# ---- 3. start JupyterLab ----------------------------------------------------------------------------
cd "$HERE"
if [ -n "${SSH_CONNECTION:-}" ] || { [ "$(uname)" = "Linux" ] && [ -z "${DISPLAY:-}" ]; }; then
    cat <<EOF

>>> Remote session: Jupyter starts WITHOUT a browser and listens on 127.0.0.1:$PORT of this host only.
    1) On your laptop, open a second terminal:     ssh -L $PORT:127.0.0.1:$PORT dbadmin@<VM IP>
    2) Copy the  http://127.0.0.1:$PORT/lab?token=...  link printed below into the laptop browser
    3) Open $NOTEBOOK  ->  menu Run  ->  Run All Cells

EOF
    exec jupyter lab --no-browser --ip=127.0.0.1 --port="$PORT" --notebook-dir="$HERE"
else
    echo ">>> Opening $NOTEBOOK in your browser  ->  menu Run  ->  Run All Cells"
    exec jupyter lab --port="$PORT" --notebook-dir="$HERE" "$NOTEBOOK"
fi
