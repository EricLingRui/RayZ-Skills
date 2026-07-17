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

- If the crash log (`~/.cursor-server/data/logs/*/remoteagent.log`, `ptyhost.log`) shows `code 127` + `SIGABRT` + `No ptyHost heartbeat`, OR `No ptyHost response to createProcess after N seconds` → native-module glibc problem.
- `pty.node` needing only `fcntl64` → the standard case below.
- Confirm the exact missing symbol: `objdump -T pty.node | grep GLIBC_2.28`.

### arm64: two server variants — check which one Cursor installed

On aarch64, Cursor ships BOTH `~/.cursor-server/bin/linux-legacy-arm64/<hash>/` (bundled node ~v20, built for old glibc — runs NATIVELY, its `pty.node` needs no new glibc) and `~/.cursor-server/bin/linux-arm64/<hash>/` (standard — bundled node needs GLIBC_2.27, `pty.node` needs GLIBC_2.28). Cursor auto-picks legacy on glibc <2.28, so it often "just works" with no patch. But once a runnable node is on `PATH`, a client update may install and run the **standard** server instead (node starts via that PATH node, but its `pty.node` still aborts on spawn) — that's when the terminal drops. Check `ps -ef | grep cursor-server` to see which `<hash>`/variant is actually running, then patch that variant's `pty.node`.

## Fix path A — node runs, native module needs fcntl64 (most common)

`fcntl64` is ABI-identical to `fcntl` on Linux; old glibc only exports `fcntl`. Three steps, **all required together** (any alone fails):

1. **Relax the ELF version requirement** — `tools/deglibc.py <module.node> [LOWER]` rewrites `.gnu.version_r` GLIBC_2.28→LOWER (name offset AND vna_hash). Passes the loader's version-node check. `LOWER` **must be a version string already present in the module's `.dynstr` AND provided by the system libc.** It defaults to `GLIBC_2.14` (works for x64/CentOS7 modules), but **aarch64 modules only carry `GLIBC_2.17` + `GLIBC_2.28`** (2.14 is absent) — pass `GLIBC_2.17` as the 2nd arg there, or deglibc aborts with "lower version string not found in dynstr". Verify targets first: `objdump -T <module.node> | grep -oE 'GLIBC_2\.[0-9]+' | sort -Vu`.
2. **Clear the symbol's version binding** — `patchelf --clear-symbol-version fcntl64 <module.node>`.
3. **Provide an unversioned `fcntl64`** — build `tools/fcntl64-shim.c` → `libfcntl64.so`, then `patchelf --add-needed libfcntl64.so <module.node>` and `--force-rpath --set-rpath <shim-dir>`. Makes the runtime relocation succeed.

Scripts do all three across every matching `~/.cursor-server` version, back up each `pty.node` to `.orig`, and self-verify with a real spawn. Requires `patchelf`, `gcc`, `python3` (install patchelf via `conda install -c conda-forge patchelf`, or borrow an existing arch-matching one — e.g. a micromamba env's `bin/patchelf` — root can exec it directly). Re-run after Cursor updates.
- **x86_64 / CentOS7**: `tools/fix-cursor-pty.sh` (globs `linux-x64`, patchelf on PATH, LOWER=2.14, node auto-detected).
- **aarch64 / Kylin etc.**: `tools/fix-cursor-pty-arm64.sh` (globs `linux-arm64`, LOWER=`GLIBC_2.17`, uses `/usr/local/bin/node`, and a `PE=` var for a borrowed patchelf path). Edit the `PE`/`RN`/`SHIM` vars at the top to match the box. The x64 script's hardcoded paths (`/root/glibc-compat-shim`, `linux-x64` glob) do NOT work on arm64 — use this variant.

Note: `better-sqlite3.node` (non-N-API, "link time reference" on fcntl64) and `tree-chunk-napi.node` (needs GLIBC_2.34 pthread symbols — a real ABI change) can't be fixed this way. They only affect the `cursor-agent-exec` extension, NOT the terminal.

## Fix path B — bundled node won't run at all

Symptom: "The bundled NodeJS failed to run, and no system NodeJS executable was found. Please manually install NodeJS 20 or higher". Get a node ≥20 built for old glibc, then point every server `node` at it:
- **Simplest on arm64**: the `linux-legacy-arm64` server already ships a native node ~v20. Copy it to a PATH dir so the installer finds a "system node": `cp ~/.cursor-server/bin/linux-legacy-arm64/*/node /usr/local/bin/node` (copy, not symlink, so it survives Cursor pruning the legacy dir; confirm `/usr/local/bin` is on the non-interactive ssh PATH). This unblocks the install — but note it may then run the STANDARD server whose `pty.node` still needs patching (fix path A).
- Install via conda/micromamba: `nodejs` from conda-forge (needs `CONDA_OVERRIDE_GLIBC=2.28` for node ≥24). It targets glibc 2.17.
- If that node still needs a newer glibc than the system has, `patchelf --set-interpreter <newer-ld.so>` + `--set-rpath "<newer-glibc-lib>:<conda-lib>"` (newer glibc libs FIRST for ABI consistency). **Do NOT** wrap it as a shell script that does `exec ld.so ... node` — that pollutes `process.execPath` to the ld.so path and breaks Cursor's `execPath -p ...` fork (code 127). Patch the binary or symlink to it instead.
- Symlink each `~/.cursor-server/bin/*/node` to the working node.

## Common Mistakes

- **Verifying with `require()` instead of real `pty.spawn()`** — the lazy-bound crash is invisible until spawn. #1 time-waster.
- **Testing with the wrong node** — always `readlink -f` the symlink chain; the real binary is often under `/opt/...` or `/usr/local/nodejs/`.
- **Only doing deglibc verneed patch** — makes `require` pass but spawn still aborts with `relocation error: fcntl64`. Need all three steps.
- **Using the default deglibc LOWER (2.14) on aarch64** — arm64 modules lack the `GLIBC_2.14` string, so deglibc aborts "lower version string not found in dynstr". Pass `GLIBC_2.17`.
- **Running the x64 `fix-cursor-pty.sh` on arm64** — its `linux-x64` glob matches nothing and its hardcoded node/patchelf paths are wrong. Use `fix-cursor-pty-arm64.sh`.
- **Shell-wrapper node using `exec ld.so`** — breaks `execPath`; patch the ELF or symlink instead.
- **Killing VS Code's ptyHost when the user uses Cursor** (or vice versa) — this host may run both; act on the right server dir.
- **Not clearing stale processes** — kill old `cursor-server`/`ptyHost` procs before reconnecting so the new patch takes effect.

## Reconnect

After patching + real-spawn verification, kill stale server processes, then reconnect in Cursor and open a terminal.
