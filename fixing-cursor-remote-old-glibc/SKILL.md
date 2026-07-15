---
name: fixing-cursor-remote-old-glibc
description: Use when Cursor or VS Code remote-SSH fails to connect or the integrated terminal keeps dropping ("pty host connection dropped", "到 shell 进程的连接丢失", "ptyHost terminated unexpectedly with code 127", "Couldn't install Cursor Server ... system node is too old") on an old Linux server (CentOS 7, Kylin V10, or any glibc < 2.28), including arm64/aarch64 and x86_64.
---

# Fixing Cursor/VS Code Remote Server on Old glibc

## Overview

Cursor/VS Code ship a remote "server" (node + native `.node` modules) built for **glibc ≥ 2.28**. On old distros (CentOS 7 = glibc 2.17, Kylin V10 = glibc 2.23) the bundled node and/or its native modules can't load, so the server install fails or the **pty host crashes** and the terminal endlessly "reconnects".

Two distinct failure layers — diagnose which one(s) you have:

1. **node itself won't run** → "system node is too old" / "bundled NodeJS failed to run". Fix: get a working node ≥20 the server can use.
2. **node runs, but native modules need glibc 2.28+** → terminal drops, `ptyHost terminated ... code 127`. The culprit is usually `node-pty`'s `pty.node` needing symbol **`fcntl64` (GLIBC_2.28)**. Fix: relax that module.

## CRITICAL: How to verify (avoid the #1 trap)

`require("pty.node")` succeeding is **NOT** proof of a fix. `fcntl64` is lazily bound — the crash only fires on the **first real `pty.spawn()`**. Always verify by spawning a pty:

```bash
cd <cursor-server-version-dir>
<the-real-node> -e '
  const pty=require("./node_modules/node-pty");
  const p=pty.spawn("/bin/bash",["-lc","echo OK; exit 0"],{name:"xterm",cols:80,rows:24});
  let o=""; p.onData(d=>o+=d);
  p.onExit(e=>console.log((e.exitCode===0&&/OK/.test(o))?"TERMINAL WORKS":"BROKEN"));
  setTimeout(()=>process.exit(0),1500)'
```

## Diagnose

```bash
uname -m; ldd --version | head -1          # arch + glibc version
readlink -f /usr/local/bin/node; node -v   # the REAL node cursor uses (follow symlinks!)
# find the server dirs
ls -d ~/.cursor-server/bin/*/*/ ~/.vscode-server/bin/*/ 2>/dev/null
# which native modules need too-new glibc:
A=~/.cursor-server/bin/linux-*/<hash>
for f in $(find "$A" -name '*.node'); do
  m=$(objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_2\.(2[89]|3[0-9])' | sort -V | tail -1)
  [ -n "$m" ] && echo "$m  $f"
done
```

- If the crash log (`~/.cursor-server/data/logs/*/remoteagent.log`, `ptyhost.log`) shows `code 127` + `SIGABRT` + `No ptyHost heartbeat` → native-module glibc problem.
- `pty.node` needing only `fcntl64` → the standard case below.
- Confirm the exact missing symbol: `objdump -T pty.node | grep GLIBC_2.28`.

## Fix path A — node runs, native module needs fcntl64 (most common)

`fcntl64` is ABI-identical to `fcntl` on Linux; old glibc only exports `fcntl`. Three steps, **all required together** (any alone fails):

1. **Relax the ELF version requirement** — `tools/deglibc.py <module.node>` rewrites `.gnu.version_r` GLIBC_2.28→2.14 (name offset AND vna_hash). Passes the loader's version-node check.
2. **Clear the symbol's version binding** — `patchelf --clear-symbol-version fcntl64 <module.node>`.
3. **Provide an unversioned `fcntl64`** — build `tools/fcntl64-shim.c` → `libfcntl64.so`, then `patchelf --add-needed libfcntl64.so <module.node>` and `--force-rpath --set-rpath <shim-dir>`. Makes the runtime relocation succeed.

`tools/fix-cursor-pty.sh` does all three across every `~/.cursor-server` version, backs up each `pty.node` to `.orig`, and self-verifies with a real spawn. It auto-detects the real node. Requires: `patchelf`, `gcc`, `python3` (install patchelf via `conda install -c conda-forge patchelf` if absent). Re-run after Cursor updates.

Note: `better-sqlite3.node` (non-N-API, "link time reference" on fcntl64) and `tree-chunk-napi.node` (needs GLIBC_2.34 pthread symbols — a real ABI change) can't be fixed this way. They only affect the `cursor-agent-exec` extension, NOT the terminal.

## Fix path B — bundled node won't run at all

Get a node ≥20 built for old glibc, then point every server `node` at it:
- Install via conda/micromamba: `nodejs` from conda-forge (needs `CONDA_OVERRIDE_GLIBC=2.28` for node ≥24). It targets glibc 2.17.
- If that node still needs a newer glibc than the system has, `patchelf --set-interpreter <newer-ld.so>` + `--set-rpath "<newer-glibc-lib>:<conda-lib>"` (newer glibc libs FIRST for ABI consistency). **Do NOT** wrap it as a shell script that does `exec ld.so ... node` — that pollutes `process.execPath` to the ld.so path and breaks Cursor's `execPath -p ...` fork (code 127). Patch the binary or symlink to it instead.
- Symlink each `~/.cursor-server/bin/*/node` to the working node.

## Common Mistakes

- **Verifying with `require()` instead of real `pty.spawn()`** — the lazy-bound crash is invisible until spawn. #1 time-waster.
- **Testing with the wrong node** — always `readlink -f` the symlink chain; the real binary is often under `/opt/...` or `/usr/local/nodejs/`.
- **Only doing deglibc verneed patch** — makes `require` pass but spawn still aborts with `relocation error: fcntl64`. Need all three steps.
- **Shell-wrapper node using `exec ld.so`** — breaks `execPath`; patch the ELF or symlink instead.
- **Killing VS Code's ptyHost when the user uses Cursor** (or vice versa) — this host may run both; act on the right server dir.
- **Not clearing stale processes** — kill old `cursor-server`/`ptyHost` procs before reconnecting so the new patch takes effect.

## Reconnect

After patching + real-spawn verification, kill stale server processes, then reconnect in Cursor and open a terminal.
