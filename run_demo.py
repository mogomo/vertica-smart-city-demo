#!/usr/bin/env python3
"""
run_demo.py - a tiny "vsql -f" look-alike for machines that have no vsql client.

The demo scripts are written for vsql.  On the Vertica host simply run:
      /opt/vertica/bin/vsql -f 01_smart_fleet_setup.sql
From a laptop that only has Python + vertica-python (e.g. through an ssh tunnel):
      python run_demo.py 01_smart_fleet_setup.sql 02_smart_fleet_analytics.sql

Supported vsql meta-commands: \\set  \\echo [-n]  \\qecho  \\!  \\timing  \\x  \\t  \\o  \\i
"""
import argparse
import datetime
import decimal
import os
import re
import subprocess
import sys
import time
import warnings

import vertica_python

try:
    from wcwidth import wcswidth
except ImportError:                                     # pragma: no cover
    def wcswidth(s):
        return len(s)

warnings.filterwarnings("ignore", category=UserWarning)


def width(s):
    w = wcswidth(s)
    return len(s) if w < 0 else w


def pad(s, w, right=False):
    gap = " " * max(0, w - width(s))
    return gap + s if right else s + gap


def fmt(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "t" if v else "f"
    if isinstance(v, float):
        return "%.15g" % v
    if isinstance(v, (bytes, bytearray)):
        return "\\x" + v[:24].hex() + ("..." if len(v) > 24 else "")
    if isinstance(v, datetime.datetime):
        return v.isoformat(sep=" ")
    return str(v)


class VsqlLite:
    def __init__(self, conn, variables):
        self.conn = conn
        self.cur = conn.cursor()
        self.vars = dict(variables)
        self.timing = False
        self.expanded = False
        self.tuples_only = False
        self.errors = []

    # ---------------------------------------------------------------- helpers
    def substitute(self, text):
        """Replace :VAR (outside quotes, not part of ::cast) with its value."""
        out, i, n = [], 0, len(text)
        while i < n:
            ch = text[i]
            if ch == "'":
                j = i + 1
                while j < n:
                    if text[j] == "'" and j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    if text[j] == "'":
                        break
                    j += 1
                out.append(text[i:j + 1])
                i = j + 1
                continue
            if ch == ":" and (i == 0 or text[i - 1] != ":") and i + 1 < n and text[i + 1] != ":":
                m = re.match(r"[A-Za-z_][A-Za-z_0-9]*", text[i + 1:])
                if m and m.group(0) in self.vars:
                    out.append(self.vars[m.group(0)])
                    i += 1 + len(m.group(0))
                    continue
            out.append(ch)
            i += 1
        return "".join(out)

    @staticmethod
    def meta_args(rest):
        """Split meta-command arguments the way vsql does (quotes group, are removed)."""
        return [m.group(1) if m.group(1) is not None else m.group(2)
                for m in re.finditer(r"'((?:[^']|'')*)'|(\S+)", rest)]

    # ---------------------------------------------------------------- output
    def print_result(self, cols, rows, numeric):
        cells = [[fmt(v) for v in r] for r in rows]
        if self.expanded:
            cw = max([width(c) for c in cols] + [1])
            vw = max([width(v) for r in cells for v in r] + [1])
            for n, r in enumerate(cells, 1):
                if not self.tuples_only:
                    head = "-[ RECORD %d ]" % n
                    print(head + "-" * max(0, cw + 1 - len(head)) + "+" + "-" * (vw + 1))
                elif n > 1:
                    print()
                for c, v in zip(cols, r):
                    print(pad(c, cw) + " | " + v)
            print()
            return
        widths = [width(c) for c in cols]
        for r in cells:
            for i, v in enumerate(r):
                widths[i] = max(widths[i], max((width(x) for x in v.split("\n")), default=0))
        if not self.tuples_only:
            print(" " + " | ".join(c.center(w) for c, w in zip(cols, widths)))
            print("-" + "-+-".join("-" * w for w in widths) + "-")
        for r in cells:
            print((" " + " | ".join(pad(v, w, right=num) for v, w, num in zip(r, widths, numeric))).rstrip())
        if not self.tuples_only:
            print("(%d row%s)" % (len(cells), "" if len(cells) == 1 else "s"))
        print()

    # ---------------------------------------------------------------- execution
    def run_sql(self, sql, where):
        sql = self.substitute(sql).strip()
        if not sql.rstrip(";").strip():
            return
        t0 = time.time()
        try:
            self.cur.description = None                 # vertica-python keeps a stale description for DDL
            self.cur.execute(sql)
            while True:
                if self.cur.description:
                    rows = self.cur.fetchall()
                    cols = [d[0] for d in self.cur.description]
                    numeric = [all(isinstance(r[i], (int, float, decimal.Decimal)) and not isinstance(r[i], bool)
                                   for r in rows if r[i] is not None) and any(r[i] is not None for r in rows)
                               for i in range(len(cols))]
                    self.print_result(cols, rows, numeric)
                else:
                    words = re.sub(r"/\*.*?\*/", " ", re.sub(r"--[^\n]*", " ", sql), flags=re.S).split()
                    print(" ".join(words[:2]).upper().rstrip(";"))
                if not self.cur.nextset():
                    break
        except Exception as exc:                        # keep going, like vsql does
            msg = str(exc).split(", Sqlstate")[0].replace("Severity: ERROR, Message: ", "")
            detail = re.search(r"Detail: (.*?), Routine:", str(exc))
            if detail:
                msg += "  DETAIL: " + detail.group(1)
            print("%s: ERROR: %s" % (where, msg))
            self.errors.append((where, msg, sql[:160].replace("\n", " ")))
        if self.timing:
            print("Time: All rows formatted: %.3f ms" % ((time.time() - t0) * 1000))
        sys.stdout.flush()

    def run_meta(self, line, where, basedir):
        parts = line.split(None, 1)
        cmd, rest = parts[0], (parts[1] if len(parts) > 1 else "")
        if cmd == "\\!":
            sys.stdout.flush()
            subprocess.call(rest, shell=True)
        elif cmd in ("\\echo", "\\qecho"):
            args = self.meta_args(rest)
            newline = True
            if args and args[0] == "-n":
                newline, args = False, args[1:]
            quoted = [m.group(0).startswith("'") for m in re.finditer(r"'(?:[^']|'')*'|\S+", rest)]
            if len(quoted) > len(args):
                quoted = quoted[1:]
            text = " ".join(a.replace("''", "'") if q else self.substitute(a) for a, q in zip(args, quoted))
            print(text, end="\n" if newline else "")
        elif cmd == "\\set":
            args = self.meta_args(rest)
            if args:
                self.vars[args[0]] = "".join(args[1:])
        elif cmd == "\\timing":
            self.timing = (rest.strip().lower() == "on") if rest.strip() else not self.timing
            print("Timing is %s." % ("on" if self.timing else "off"))
        elif cmd == "\\x":
            self.expanded = not self.expanded
            print("Expanded display is %s." % ("on" if self.expanded else "off"))
        elif cmd == "\\t":
            self.tuples_only = not self.tuples_only
            print("Showing only tuples." if self.tuples_only else "Tuples only is off.")
        elif cmd == "\\o":                              # \o file = send query output to a file, \o = back to stdout
            if sys.stdout is not sys.__stdout__:
                sys.stdout.close()
            sys.stdout = open(rest.strip(), "w", encoding="utf-8") if rest.strip() else sys.__stdout__
        elif cmd == "\\i":
            self.run_file(os.path.join(basedir, rest.strip()))
        else:
            print("%s: unsupported meta-command %s (ignored)" % (where, cmd))
        sys.stdout.flush()

    def run_file(self, path):
        basedir = os.path.dirname(os.path.abspath(path))
        buf, start = [], 0
        with open(path, encoding="utf-8") as fh:
            for lineno, raw in enumerate(fh, 1):
                line = raw.rstrip("\n")
                where = "%s:%d" % (os.path.basename(path), lineno)
                if not buf and line.lstrip().startswith("\\"):
                    self.run_meta(line.strip(), where, basedir)
                    continue
                if not buf and (not line.strip() or line.strip().startswith("--")):
                    continue
                if not buf:
                    start = lineno
                buf.append(line)
                code = re.sub(r"--.*$", "", line).rstrip()
                if code.endswith(";"):
                    self.run_sql("\n".join(buf), "%s:%d" % (os.path.basename(path), start))
                    buf = []
        if buf:
            self.run_sql("\n".join(buf), "%s:%d" % (os.path.basename(path), start))


def main():
    ap = argparse.ArgumentParser(description="Run vsql demo scripts through vertica-python")
    ap.add_argument("files", nargs="+")
    ap.add_argument("--host", default=os.environ.get("VSQL_HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("VSQL_PORT", 5433)))
    ap.add_argument("--user", default=os.environ.get("VSQL_USER", "dbadmin"))
    ap.add_argument("--password", default=os.environ.get("VSQL_PASSWORD", ""))
    ap.add_argument("--database", default=os.environ.get("VSQL_DATABASE", "VDB"))
    ap.add_argument("-v", "--variable", action="append", default=[], metavar="NAME=VALUE",
                    help="preset a vsql variable; a \\set of the same name inside the script is then ignored")
    a = ap.parse_args()

    conn = vertica_python.connect(host=a.host, port=a.port, user=a.user, password=a.password,
                                  database=a.database, tlsmode="prefer", autocommit=True)
    preset = dict(v.split("=", 1) for v in a.variable)
    shell = VsqlLite(conn, preset)
    if preset:                                          # command-line values win over \set in the script
        original = shell.run_meta

        def guarded(line, where, basedir):
            if line.startswith("\\set"):
                args = shell.meta_args(line.split(None, 1)[1] if " " in line else "")
                if args and args[0] in preset:
                    return
            original(line, where, basedir)
        shell.run_meta = guarded
    for f in a.files:
        shell.run_file(f)
    conn.close()
    if shell.errors:
        print("\n%d statement(s) failed:" % len(shell.errors), file=sys.stderr)
        for where, msg, sql in shell.errors:
            print("  %s  %s\n      %s" % (where, msg, sql), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
