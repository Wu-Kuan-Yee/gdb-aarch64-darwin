# Architecture

This document describes what the patch series changes, why each change is
needed, and how the pieces fit into GDB's existing Darwin support.

## Why GDB cannot debug on Apple Silicon

Two independent problems have to be solved before GDB can debug a program on
an arm64 Mac.

**There is no native target.**  GDB's top-level `configure.ac` lists
`gdb` in `noconfigdirs` for `aarch64-*-darwin*`, so the debugger is not even
built.  Inside `gdb/`, `configure.nat` has no `aarch64` case for the Darwin
host, and `configure.tgt` has no `aarch64-*-darwin*` target.  A build that
is forced through ends up without a `native` target:

```text
(gdb) target native
Undefined target command: "native".
```

**The debugger is not authorised.**  Even with a native target, macOS only
hands out task ports to a debugger signed with a trusted identity and the
`com.apple.security.cs.debugger` entitlement.  Signing is covered in
[SIGNING.md](SIGNING.md); this document is about the code.

## How GDB's Darwin layer is organised

GDB already has a Mach-based Darwin layer for x86-64 and i386:

- `gdb/darwin-nat.c` implements the target-independent part: launching the
  inferior, receiving Mach exception messages, tracking `darwin_inferior`
  and `darwin_thread` objects, and mapping Mach ports to ptids.
- `gdb/*-darwin-nat.c` implements the architecture-specific part: reading
  and writing registers with `thread_get_state` / `thread_set_state`,
  translating hardware breakpoint and watchpoint requests into the ARM
  debug registers, and recognising the architecture's exception state.

The AArch64 port adds the second file and teaches the first one about arm64.
That is why the series is small: the exception loop, the inferior
bookkeeping and the dyld symbol reader are reused as they are.

## The patch series

### 0001 — build and register the target

- `configure.ac` removes `gdb` from `noconfigdirs` for
  `aarch64-*-darwin*`; the generated `configure` is updated to match.
- `gdb/configure.nat` adds `aarch64-darwin-nat.o` for an arm64 Darwin host.
- `gdb/configure.tgt` adds an `aarch64-*-darwin*` target built from
  `aarch64-darwin-tdep.o` and `solib-darwin.o`.
- `gdb/Makefile.in` lists the new source files.

Without this patch nothing else is compiled.

### 0002 — read DWARF 5 from Mach-O

Apple's toolchain emits DWARF 5 sections with Apple-specific names and
flags.  `bfd/mach-o.c` learns the section names, and `gdb/dwarf2/read.c`
accepts the resulting section layout.  Debug information from a normal
`cc -g` build then loads with line numbers instead of producing a file
without symbols.

### 0003 — the native backend

`gdb/aarch64-darwin-nat.c` is the core of the port.  It provides:

- **Register access.**  `arm_thread_state64_t` is read and written with
  `thread_get_state` / `thread_set_state`.  The SDK accessors
  (`arm_thread_state64_get_pc`, `get_sp`, `get_fp`, `get_lr`, …) are used
  rather than the raw fields, so arm64e pointer authentication metadata is
  handled by the SDK.
- **NEON and floating point registers.**  `arm_neon_state64_t` supplies the
  vector registers, `fpsr` and `fpcr`.
- **Exception state.**  `arm_exception_state64_t` provides `far`, the fault
  address, which the generic Mach exception message cannot represent at
  full width.
- **Debug state.**  `arm_debug_state64_t` holds the hardware breakpoint and
  watchpoint registers; the backend converts GDB's breakpoint and watchpoint
  requests into `bvr`/`bcr` and `wvr`/`wcr` values.
- **Stepping.**  Single stepping is implemented with the hardware
  single-step bit in `mdscr_el1`, not with `ptrace`.
- **Thread lifecycle.**  Thread creation and termination messages from the
  Mach exception port are turned into GDB thread objects, and registers are
  read per thread.

`gdb/aarch64-darwin-tdep.c` adds the target-dependent half:

- a frame unwinder for signal trampolines, so `bt` works inside a signal
  handler;
- Darwin shared library operations, so dyld symbols are loaded;
- a Mach-O OSABI sniffer so an arm64 Mach-O file is associated with this
  target rather than the generic one.

### 0004 — signal frames

When a signal is delivered, the kernel saves the interrupted state in the
Darwin ARM64 signal context.  The PC has to be read from there rather than
from the thread state, otherwise the frame unwinder reports the address of
the trampoline instead of the interrupted instruction.  This is what makes
`bt` correct after a `SIGSEGV`.

### 0005 — signing at build time

`gdb/Makefile.in` gains a `CODESIGN_ENTITLEMENTS` variable and passes
`--options runtime --entitlements` to `codesign`, so the link step produces
a binary that already carries `com.apple.security.cs.debugger`.
`gdb/gdb-debugger.entitlements` holds the plist.  The installed binary is
re-signed with a real identity afterwards by `scripts/sign.sh`.

Signing at link time is not sufficient in practice, but it keeps the
built binary from being completely unusable if someone runs it before
signing, and it documents the entitlement requirement next to the code that
needs it.

### 0007 — thread port notifications

`MACH_NOTIFY_DEAD_NAME` is sent for thread ports as well as for the task
port.  The Darwin layer treated every such notification as a process exit and
called `wait4` without `WNOHANG`, so when a thread died while the inferior was
still running, GDB blocked in the kernel forever: no output, no error, and a
debugger that never reached the first breakpoint.

The fix polls with `WNOHANG | WUNTRACED` and ignores a notification that does
not correspond to a reaped or stopped child.  The task port notification is
still delivered when the process really exits, so exit status reporting is
unchanged.

### 0006 — hardware watchpoints

The ARM64 debug registers provide four watchpoint slots.  This patch:

- installs the watchpoint values and control registers, and clears the
  slots that are no longer in use;
- reads the fault address from the exception state, because the legacy
  exception message truncates it to 32 bits;
- reports whether the stop was caused by a watchpoint, a hardware
  breakpoint, or something else, so GDB prints the right stop reason.

## Capability matrix

| Feature | Mechanism | Notes |
| --- | --- | --- |
| Breakpoints | Mach exception on `EXC_BREAKPOINT` | software breakpoints are written into the text segment |
| Stepping | `mdscr_el1` single-step bit | no `ptrace` single step |
| Watchpoints | `wvr`/`wcr`, four slots | fifth request fails with a GDB error |
| Registers | `thread_get_state` | GPR, `pc`, `sp`, NEON, `fpsr`, `fpcr` |
| Backtraces | DWARF CFI plus signal trampoline unwinder | |
| Shared libraries | `solib-darwin.c` | dyld notifications |
| Threads | Mach thread ports | `info threads`, per-thread registers |
| Attach | `task_for_pid` | target must allow it |

## Design constraints

- **No new dependency on private frameworks.**  The backend uses the public
  Mach and `mach/arm` headers that ship with the SDK.
- **Reuse the existing Darwin layer.**  The x86-64 path already solves
  inferior and thread bookkeeping; duplicating it for arm64 would double
  the maintenance cost and diverge over time.
- **Keep the diff reviewable.**  The series is split so that each commit
  can be read on its own: build plumbing, object file support, backend,
  signal frames, signing, watchpoints.
- **Do not modify the user's system.**  The build is out of tree and the
  install goes to a prefix; nothing is written to `/usr/local` and no
  system binary is replaced.
