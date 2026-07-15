#!/bin/bash
# Repairs Cursor Server terminal (pty host) on CentOS 7 / glibc 2.17.
# Cursor's node-pty (pty.node) is built for glibc 2.28+ and references
# fcntl64, which glibc 2.17 lacks entirely (it only has fcntl). Loading
# the module lazily succeeds, but the FIRST real pty spawn triggers a
# relocation of fcntl64 -> abort (SIGABRT) -> "ptyHost code 127".
#
# Fix = three steps together (any one alone is insufficient):
#   1. deglibc.py     : relax .gnu.version_r  GLIBC_2.28 -> 2.14 (loader check)
#   2. clear-version  : drop the fcntl64 symbol's GLIBC version binding
#   3. add-needed shim: provide an UNVERSIONED fcntl64 (forwards to fcntl)
# Verified by actually spawning a pty, not just require().
# Idempotent; re-run after Cursor updates pull a new server version.
set -e
# python: prefer system, fall back to conda
for pcand in /usr/bin/python3 /root/miniconda3/bin/python python3; do
  command -v "$pcand" >/dev/null 2>&1 && PY=$pcand && break
done
SHIM=/root/glibc-compat-shim
PATCHER=$SHIM/deglibc.py
# Prefer the real node (not any wrapper).
for cand in /opt/node-v20.20.2-linux-x64-glibc-217/bin/node.real \
            /usr/local/nodejs/bin/node /usr/local/bin/node; do
  [ -x "$cand" ] && RN=$cand && break
done

for PTY in /root/.cursor-server/bin/linux-x64/*/node_modules/node-pty/build/Release/pty.node; do
  [ -f "$PTY" ] || continue
  V=$(echo "$PTY" | cut -d/ -f6)
  [ -f "$PTY.orig" ] || cp -a "$PTY" "$PTY.orig"
  # Always re-derive from the pristine original for idempotency.
  cp -a "$PTY.orig" "$PTY"
  "$PY" "$PATCHER" "$PTY" >/dev/null 2>&1
  patchelf --clear-symbol-version fcntl64 "$PTY" 2>/dev/null || true
  patchelf --add-needed libfcntl64.so "$PTY" 2>/dev/null || true
  patchelf --force-rpath --set-rpath "$SHIM" "$PTY" 2>/dev/null || true
  # version dir = strip "/node_modules/node-pty/build/Release/pty.node"
  A=${PTY%/node_modules/node-pty/build/Release/pty.node}
  R=$(cd "$A" && "$RN" -e '
    const pty=require("./node_modules/node-pty");
    const p=pty.spawn("/bin/bash",["-lc","echo OK; exit 0"],{name:"xterm",cols:80,rows:24});
    let o=""; p.onData(d=>o+=d);
    p.onExit(e=>{console.log((e.exitCode===0&&/OK/.test(o))?"SPAWN_OK":"SPAWN_BAD")});
    setTimeout(()=>process.exit(0),1500);
  ' 2>&1 | grep -oE "SPAWN_OK|SPAWN_BAD|relocation error" | head -1)
  if [ "$R" = "SPAWN_OK" ]; then
    echo "patched + verified: $V"
  else
    echo "FAILED ($R), restoring: $V"
    cp -a "$PTY.orig" "$PTY"
  fi
done
