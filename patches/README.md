# Upstream patches

These files carry the AArch64 Darwin support that upstream GDB does not
provide.  They are plain unified diffs against a single pinned upstream
revision and are applied in the order listed in `series` with
`git apply -p1`.

| Patch | Upstream area | Purpose |
| --- | --- | --- |
| `0001` | `configure`, `gdb/configure.tgt`, `gdb/configure.nat` | Build GDB for `aarch64-*-darwin*` and register a native target |
| `0002` | `gdb/dwarf2/read.c` | Report the missing string-offsets section instead of the string section |
| `0003` | `gdb/aarch64-darwin-nat.c`, `gdb/aarch64-darwin-tdep.c` | Complete the native backend: registers, threads, stepping, solibs |
| `0004` | `gdb/aarch64-darwin-tdep.c` | Take the PC from the Darwin ARM64 signal context on frame unwinding |
| `0005` | `gdb/Makefile.in`, `gdb/darwin-nat.c` | Sign the debugger with `com.apple.security.cs.debugger` at build time |
| `0006` | `gdb/aarch64-darwin-nat.c`, `gdb/aarch64-nat.c` | Program the four ARM64 hardware watchpoint slots and report the faulting address |
| `0007` | `gdb/darwin-nat.c` | Do not block reaping a child when a thread port dies while the inferior is still running |
| `0008` | `gdb/solib-darwin.c`, `gdb/darwin-nat.c` | Load the dyld image list once dyld publishes it, accept current dyld versions, and skip libraries that only exist in the shared cache |
| `0009` | `gdb/dwarf2/read.c` | Handle `DW_AT_object_pointer` with `DW_FORM_implicit_const`, as emitted by current Clang |
| `0010` | `gdb/aarch64-darwin-tdep.c` | Recognise Darwin signal frames through the ucontext pointer when the system libraries have no symbols |
| `0011` | `gdb/darwin-nat.c` | Implement `info proc mappings` with `mach_vm_region` and `proc_pidinfo` |
| `0012` | `gdb/python/python.c`, `gdb/guile/guile.c` | Find bundled Python and Guile data through `GDB_EMBEDDED_ROOT` (no launcher script) |
| `0013` | `gdb/darwin-nat.c` | Use `/bin/bash` when caching a shell: the arm64e-only `/bin/sh` copy dies with SIGTRAP under the debugger |
| `0014` | `gdb/python/lib/gdb/libcxx.py`, `gdb/python/lib/gdb/__init__.py`, `gdb/data-directory/Makefile.in` | libc++ pretty-printers (string, vector, map, set, smart pointers, optional, string_view), loaded at startup because libc++ ships no `.debug_gdb_scripts` |
| `0015` | `gdb/darwin-nat.c` | Inject the early-image helper, swallow its trap and refresh solibs before a startup constructor calls into a dlopen'ed library |
| `0016` | `gdb/darwin-nat.c`, `gdb/darwin-nat.h`, `gdb/gcore.c` | Write Mach-O core files (`MH_CORE` + `LC_SEGMENT_64` + thread commands) from `gcore` |
| `0017` | `gdb/darwin-nat.c`, `gdb/darwin-nat.h`, `gdb/corelow.c` | Read Mach-O cores back: a `darwin-core` target for memory, registers and threads |
| `0018` | `gdb/darwin-nat.c` | Fetch thread registers before writing a core; serve text from the exec target |
| `0019` | `gdb/darwin-nat.c` | Visit each thread while collecting registers for a core |
| `0020` | `gdb/darwin-nat.c` | Use cooked register reads when writing cores |
| `0021` | `gdb/darwin-nat.c` | Read thread state with `thread_get_state` instead of the thread regcaches |
| `0022` | `gdb/darwin-nat.c` | Parse the dyld shared cache (header, mappings, images, subcache suffixes) and add `darwin-shared-cache` |
| `0023` | `gdb/darwin-nat.c` | Walk each cached image's export trie (from the linkedit subcache) for symbol names and addresses |
| `0024` | `gdb/darwin-nat.c` | `darwin-shared-symbol NAME [PATH-FILTER]`, a symbol lookup across the cache |

## Applying with a three-way merge

The files carry `index` lines, so `git apply --3way` can merge a patch into
a tree that has moved.  `./build.sh --latest` relies on this to follow
upstream master: ordinary drift is absorbed, and a genuine conflict is
reported instead of applied with fuzz.  Fuzz is never used by the project's
own scripts for exactly that reason.

## Keeping the series current

The series targets the revision recorded as `UPSTREAM_REV` in
`scripts/lib/common.sh`.  To move it to a newer upstream commit:

```sh
# Fetch upstream, then rebase the work branch onto the new revision.
git clone https://sourceware.org/git/binutils-gdb.git /tmp/binutils-gdb
cd /tmp/binutils-gdb
git checkout -b aarch64-darwin <new-revision>
git am /path/to/gdb-aarch64-darwin/patches/*.patch
# Resolve conflicts, then regenerate the series:
git format-patch --no-numbered --no-signature -o out <new-revision>
```

Regenerate the patches with `git diff`, not `git format-patch`, so the files
stay free of mail headers.  Then rebuild and run `./scripts/verify.sh`; a
patch that applies but silently breaks the backend is worse than a conflict.
