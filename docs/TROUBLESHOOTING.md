# Troubleshooting

Start with the doctor; it catches most problems before they turn into a
confusing build error.

```sh
./scripts/doctor.sh
```

When a build fails, the phase that failed prints the last 40 lines of its
log.  The full logs live in `build/`:

```sh
tail -50 build/configure.log
tail -50 build/build.log
tail -50 build/install.log
```

When the build succeeds but debugging misbehaves, run the smoke test with
the full GDB output:

```sh
./scripts/verify.sh --verbose --keep
```

## Build problems

| Symptom | Cause | Fix |
| --- | --- | --- |
| `this project requires Apple Silicon (arm64), but x86_64 was detected` | The shell runs under Rosetta | Open a native terminal, or run `arch -arm64 /bin/zsh` |
| `xcode-select: error: invalid active developer path` | Command line tools missing or moved | `xcode-select --install`, then `sudo xcode-select -s /Applications/Xcode.app` if Xcode is installed |
| `cannot find the macOS SDK` | No SDK selected | Install Xcode or the command line tools |
| `GMP not found` / `MPFR not found` | Homebrew formulae missing | `brew install gmp mpfr` |
| `bison: command not found` | Toolchain not installed | `xcode-select --install` |
| `makeinfo: command not found` during the build | Documented manuals need texinfo | Handled automatically: the build passes `MAKEINFO=true`.  Install `texinfo` if the manuals are wanted |
| `configure: error: C compiler cannot create executables` | SDK or compiler mismatch | Check `xcrun --sdk macosx --show-sdk-path`; see `build/configure.log` |
| `patch does not apply` | The cached source is not at the pinned revision | `./build.sh --clean` (keeps the source) or delete `.cache/binutils-gdb` |
| `revision ... is not in the cache` | Shallow or partial cache | `./scripts/bootstrap.sh --refresh`, or remove `.cache/binutils-gdb` |
| `git clone` is extremely slow | Upstream repository is large | Let it finish once, or use `--source` with an existing checkout |
| `No space left on device` | Source, build and install trees need about 6 GiB | Free space or move `.cache`, `build` and the prefix to another volume |
| Build killed with no message | Out of memory with too many jobs | `./build.sh --jobs 4` |
| `error: unknown argument` | Typo in an option | `./build.sh --help` |
| `--latest` stops with `three-way merge failed` | Upstream changed the exact code a patch touches | Rebase the series (patches/README.md), or build the pinned revision
| `--latest and --source cannot be combined` | An external checkout has no upstream | Drop one of the two options |
| `Python scripting is not supported` | The interpreter on `PATH` has no development headers | `brew install python`, then `./build.sh --reconfigure` |
| `no usable python found at /usr/bin/python3` | The command line tools ship a stub Python | Point `GAD_PYTHON` at a real interpreter, or use `--no-python` |

## Debugging problems

### GDB starts, then hangs after `run`

The classic signature problem.  GDB is ad hoc signed or lacks the
debugger entitlement, so `taskgated` never grants the task port.

```sh
codesign -dvvv dist/bin/gdb | grep -E 'Authority|Signature'
./scripts/sign.sh --check
./scripts/sign.sh
```

A healthy signature shows an `Authority=Apple Development: ...` line.  If
it shows `Signature=adhoc`, re-sign.  See [SIGNING.md](SIGNING.md).

If the signature is healthy and GDB still hangs, check for a leftover
debugger from an earlier run; a suspended inferior can hold the task port:

```sh
pgrep -fl gdb
```

### `Undefined target command: "native"`

GDB was built without the patch series, or the build used a different
binary than the one being tested.  Confirm which GDB is running:

```sh
which -a gdb
gdb --version
./dist/bin/gdb --version
```

The version line must come from this project's build.  If it does not,
activate the installation with `eval "$(./scripts/env.sh)"` or call
`./dist/bin/gdb` directly.

### `Unable to find Mach task port for process-id ...`

Same authorisation problem as the hang above, reported by an older GDB or
when attaching.  Verify the signature, and sign the target when attaching:

```sh
./scripts/sign.sh --target ./a.out
```

### `not permitted to attach to process`

The target is hardened, is owned by another user, or is protected by SIP.
Signing the target helps only in the first case; system binaries cannot be
attached to without disabling SIP, which this project does not recommend.

### A breakpoint in a dlopen'ed library never triggers

GDB loads the shared library symbols at the first stop after `run`.  If the
program calls `dlopen` before that, a breakpoint set on a function in the
new library is not resolved in time.  Stop once before continuing:

```text
(gdb) start
(gdb) break function_in_library
(gdb) continue
```

The notifier installed at the first stop resolves the breakpoint as soon as
the library is loaded.

### Watchpoints

ARM64 provides four hardware watchpoint slots.  A fifth request fails:

```text
Could not insert hardware watchpoint ...
```

Delete unused watchpoints (`info watchpoints`, `delete N`).  Watchpoints
also require the watched variable to live in memory; a value optimised into
a register cannot be watched, so compile the program with `-O0` while
debugging.

### Backtraces stop inside libsystem

`bt` shows a frame in `libsystem_kernel.dylib` and then `?? ()` or a
truncated stack.  macOS keeps most system libraries in the dyld shared
cache with no file on disk, so GDB has no unwind information for them.
Backtraces that start in your own code are complete; a stopped-in-system
frame cannot always be unwound.  This is a platform limitation, not a
problem with the port.

### `catch throw` or `catch syscall` never fires

Catchpoints are implemented by planting a breakpoint on a system function
(`__cxa_throw`, the syscall entry).  Those functions live in the shared
cache, so the breakpoint cannot be resolved.  Use a breakpoint in your own
code instead, or catch the exception at the point where it is thrown.

### `gcore` is not supported

GDB has no Mach-O core writer, so `gcore` fails on macOS.  `lldb` can save a
core file:

```sh
lldb -o "process save-core /tmp/core" -p PID
```

`info proc mappings` is implemented by this port and works normally.

### `warning: unhandled dyld version (N)`

GDB does not recognise the dyld version reported by a newer macOS.  It is
informational: shared library symbols are still loaded.  The warning is
printed by the upstream dyld reader, not by the AArch64 backend.

### `warning: .debug_names not created by gdb; ignoring`

Apple's toolchain emits a `.debug_names` accelerator table that GDB ignores.
Symbols and line numbers still work.  The warning can be silenced by
compiling with `-g` only.

### Backtrace shows `?? ()`

Either the binary was built without debug information (`-g`), or the
unwinder could not read the frame.  Rebuild with `-g -O0`, and check
`info frame`.  For a crash inside a signal handler, the signal trampoline
unwinder from patch 0004 must be active; rebuild from this project rather
than using a distribution GDB.

### GDB crashes immediately on startup

Most often a damaged or contradictory signature, for example a binary that
was edited after signing.  Rebuild and re-sign:

```sh
./build.sh --no-verify
./scripts/sign.sh
./scripts/verify.sh
```

## Diagnosing a hung debugger

When GDB is stuck and the reason is not obvious, sample it:

```sh
pgrep -fl gdb
sample <pid> 2 -file /tmp/gdb-sample.txt
```

A stack ending in `__wait4` means GDB is waiting for a child that never
reported an event; a stack in `mach_msg_trap` means it is waiting for a
Mach exception message.  Either way, check the signature first, then look
for a stale process holding the task port.

`./scripts/verify.sh --verbose --keep` prints the complete GDB transcript
and keeps the temporary directory, which is usually enough to see where the
sequence stopped.

## Reporting a problem

Include:

- `./scripts/doctor.sh` output
- the failing phase and the relevant log tail
- `gdb --version` and `sw_vers`
- the last lines of `./scripts/verify.sh --verbose`

That is enough to tell a toolchain problem from a backend problem.
