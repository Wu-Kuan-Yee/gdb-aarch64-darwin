# Upstream patches

These files carry the AArch64 Darwin support that upstream GDB does not
provide.  They are plain unified diffs against a single pinned upstream
revision and are applied in the order listed in `series` with
`git apply -p1`.

| Patch | Upstream area | Purpose |
| --- | --- | --- |
| `0001` | `configure`, `gdb/configure.tgt`, `gdb/configure.nat` | Build GDB for `aarch64-*-darwin*` and register a native target |
| `0002` | `bfd/mach-o.c`, `gdb/dwarf2/read.c` | Read DWARF 5 sections from Apple Mach-O objects |
| `0003` | `gdb/aarch64-darwin-nat.c`, `gdb/aarch64-darwin-tdep.c` | Complete the native backend: registers, threads, stepping, solibs |
| `0004` | `gdb/aarch64-darwin-tdep.c` | Take the PC from the Darwin ARM64 signal context on frame unwinding |
| `0005` | `gdb/Makefile.in`, `gdb/darwin-nat.c` | Sign the debugger with `com.apple.security.cs.debugger` at build time |
| `0006` | `gdb/aarch64-darwin-nat.c`, `gdb/aarch64-nat.c` | Program the four ARM64 hardware watchpoint slots and report the faulting address |
| `0007` | `gdb/darwin-nat.c` | Do not block reaping a child when a thread port dies while the inferior is still running |

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
