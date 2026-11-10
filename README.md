# gdb-aarch64-darwin

A native AArch64 Darwin backend for GNU GDB, packaged so that Apple Silicon
Macs can build a working debugger in one command.

Upstream GDB builds on macOS, but the binary it produces on an M-series Mac
cannot debug anything: the AArch64 Darwin native target does not exist, so
`target native` is undefined and `run` fails with

```text
Undefined target command: "native".
Don't know how to run.  Try "help target".
```

Homebrew's `gdb` has the same problem.  This project carries the missing
backend as a small patch series on top of a pinned upstream revision, plus
the build and signing harness needed to make the result usable.

## What works

The smoke test in `tests/` exercises these on every build:

| Capability | Status |
| --- | --- |
| Mach-O ARM64 executables and symbols | works |
| Source breakpoints | works |
| `next`, `step`, `finish`, `continue` | works |
| Backtraces with symbols and line numbers | works |
| Register access (general purpose, `pc`, `sp`, NEON) | works |
| Hardware watchpoints (four ARM64 slots) | works |
| Thread listing and per-thread registers | works |
| Shared library (dyld) symbol loading | works |
| `gdb -p PID` attach | requires signing the target, see [docs/SIGNING.md](docs/SIGNING.md) |
| Core dumps | not tested |
| `gdbstub` / remote debugging | not implemented by the upstream Darwin layer |

## Requirements

- Apple Silicon Mac (arm64), macOS 13 or newer
- Xcode or the Xcode command line tools
- Homebrew `gmp` and `mpfr`
- A code signing identity with a private key (an Apple Development
  certificate from a free Apple ID is enough)

The build refuses to start without a signing identity, because a GDB that
is only ad hoc signed blocks in `taskgated` the moment it starts an inferior.
`./scripts/doctor.sh` checks all of the above and explains what is missing.

## Quick start

```sh
git clone <repository-url> gdb-aarch64-darwin
cd gdb-aarch64-darwin

./scripts/doctor.sh     # check the machine
./build.sh              # build, install, sign and test
eval "$(./scripts/env.sh)"
gdb --version
```

`./build.sh` installs into `./dist` by default.  The first run also clones
the upstream binutils-gdb repository into `.cache` (about 600 MB); later
runs reuse it.

To install somewhere else, for example next to other tools:

```sh
./build.sh --prefix "$HOME/Packages/gdb/aarch64-darwin"
```

## Using it

```sh
gdb ./a.out                 # debug a program built with -g
gdb --args ./a.out arg1     # pass arguments
gdb -p 1234                 # attach to a running process
```

Programs compiled normally with `cc -g` work without any extra steps: GDB
launches them itself, so the inferior does not need a special signature.
Only attaching to a process that is already running needs the target to be
signed with `get-task-allow`:

```sh
./scripts/sign.sh --target ./a.out
```

## How the build works

```text
patches/             the AArch64 Darwin backend, six ordered diffs
scripts/bootstrap.sh clone upstream once, check out the pinned revision,
                     apply the patch series
build.sh             bootstrap, configure, make, install, sign, verify
scripts/sign.sh      apply the debugger entitlement with a real identity
scripts/verify.sh    debug tests/probe.c and check the result
```

The build is out of tree: sources stay in `.cache`, objects in `build/`,
the installed tree in `dist/`.  Nothing outside those directories is
modified.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for what the patches
change and why, [docs/BUILDING.md](docs/BUILDING.md) for the build options,
[docs/SIGNING.md](docs/SIGNING.md) for the macOS authorisation model, and
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) when something fails.

## Verifying an installation

```sh
./scripts/verify.sh
```

This compiles `tests/probe.c`, runs it under the installed GDB, and checks
that the breakpoint was hit, the backtrace is symbolic, `pc` and `sp` can be
read, the hardware watchpoint fired with the right old and new value, and
the inferior exited normally.  The build runs the same test automatically,
so a successful `./build.sh` already means the debugger works.

## Rebuilding and cleaning

```sh
./build.sh --reconfigure     # re-run configure
./build.sh --clean           # remove build/, keep the cached source
./build.sh --distclean       # remove build/, dist/ and .cache/
make verify                  # same as ./scripts/verify.sh
```

## Keeping the port current

The series targets the revision in `scripts/lib/common.sh`
(`UPSTREAM_REV`).  To move it forward, rebase the patches onto the new
upstream revision and rebuild; `patches/README.md` describes the procedure.

## Limitations

- The backend talks to the kernel through the Mach exception and thread
  APIs.  It does not use `ptrace`, so anything that needs single-stepping
  through the kernel, such as stepping over a `syscall` instruction, is
  not available.
- Hardware watchpoints are limited to the four ARM64 debug registers.
  GDB reports an error when a fifth is requested.
- Attaching to hardened processes owned by other users is refused by macOS
  regardless of entitlements.
- The port is a patch series, not an upstream submission; behaviour may
  change when the pinned revision is updated.

## Licence

GPL-3.0-or-later, the same licence as GDB and binutils.  See [LICENSE](LICENSE).
