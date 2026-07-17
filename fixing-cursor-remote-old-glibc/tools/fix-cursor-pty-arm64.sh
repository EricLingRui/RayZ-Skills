#!/bin/bash
# aarch64 / Kylin glibc 2.23 adaptation of fix-cursor-pty.sh.
# Patches Cursor standard linux-arm64 server's pty.node (needs fcntl64/GLIBC_2.28).
set -e
SHIM=/root/glibc-compat-shim
PE=/home/trs/micromamba/envs/node/bin/patchelf     # borrowed aarch64 patchelf
PY=/usr/bin/python3
RN=/usr/local/bin/node                              # the node cursor actually runs
GLOB="/root/.cursor-server/bin/linux-arm64/*/node_modules/node-pty/build/Release/pty.node"

# 1. build the unversioned fcntl64 shim
gcc -shared -fPIC -O2 -o "$SHIM/libfcntl64.so" "$SHIM/fcntl64-shim.c"
echo "built libfcntl64.so"

for PTY in $GLOB; do
  [ -f "$PTY" ] || continue
  V=$(echo "$PTY" | sed -E 's#.*/linux-arm64/([a-f0-9]+)/.*#\1#')
  [ -f "$PTY.orig" ] || cp -a "$PTY" "$PTY.orig"
  cp -a "$PTY.orig" "$PTY"                          # always re-derive from pristine
  "$PY" "$SHIM/deglibc.py" "$PTY" GLIBC_2.17        # step 1: relax verneed 2.28->2.17 (aarch64 baseline)
  "$PE" --clear-symbol-version fcntl64 "$PTY"       # step 2: drop version binding
  "$PE" --add-needed libfcntl64.so "$PTY"           # step 3a: provide fcntl64
  "$PE" --force-rpath --set-rpath "$SHIM" "$PTY"    # step 3b: find the shim
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
