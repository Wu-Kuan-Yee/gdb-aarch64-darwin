# Building

`./build.sh` is the only command needed for a normal build.  It checks the
environment, prepares the source, compiles GDB, installs it, signs it and
runs the smoke test.  This document explains what happens in each phase and
which options exist for less common situations.

## Requirements

| Component | Why | How to get it |
| --- | --- | --- |
| Apple Silicon Mac | The backend is AArch64 Mach specific | — |
| macOS 13+ | Mach APIs used by the backend | — |
| Xcode command line tools | clang, make, bison, flex, SDK | `xcode-select --install` |
| GMP | GDB's expression evaluator | `brew install gmp` |
| MPFR | GDB's floating point support | `brew install mpfr` |
| Code signing identity | macOS authorises debuggers by signature | Xcode > Settings > Accounts |
| Python with headers (optional) | Python scripting in GDB | `brew install python` |

`./scripts/doctor.sh` reports the state of every item and exits non-zero
when something required is missing.

## Quick start

```sh
./scripts/doctor.sh
./build.sh
eval "$(./scripts/env.sh)"
```

The build installs into `./dist`.  Use `--prefix` to install elsewhere:

```sh
./build.sh --prefix "$HOME/Packages/gdb/aarch64-darwin"
```

The first build downloads the upstream repository (about 600 MB).  Expect
5 to 15 minutes in total on a recent Mac; subsequent builds are incremental.

## Build phases

1. **Environment checks.**  Architecture, toolchain, SDK, GMP/MPFR and the
   signing identity are validated before anything expensive happens.
2. **Source preparation.**  `scripts/bootstrap.sh` clones the upstream
   repository into `.cache/binutils-gdb`, checks out the pinned revision,
   and applies `patches/series`.  A stamp file records the revision and a
   digest of the series so a prepared tree is recognised on the next run.
3. **Configure.**  An out-of-tree build is configured in `build/`.  The
   existing `config.status` is reused when it matches the prefix and source
   directory.
4. **Compile.**  `make all-gdb` builds GDB and the libraries it needs.
   Output goes to `build/build.log`.
5. **Install.**  `make install-gdb` installs `bin/gdb` and `share/gdb` into
   the prefix.  Output goes to `build/install.log`.
6. **Sign.**  `scripts/sign.sh` replaces the ad hoc signature that the
   linker produced with a real identity and the
   `com.apple.security.cs.debugger` entitlement.  Skipped with `--no-sign`.
7. **Verify.**  `scripts/verify.sh` compiles `tests/probe.c` and runs the
   smoke test.  Skipped with `--no-verify`.

## Options

| Option | Effect |
| --- | --- |
| `--prefix DIR` | Installation prefix, default `./dist` |
| `--jobs N` | Parallel make jobs, default number of CPUs |
| `--source DIR` | Use an existing binutils-gdb checkout instead of the cache |
| `--identity NAME` | Codesigning identity to use |
| `--no-python` | Configure without Python scripting support |
| `--portable` | Static GMP/MPFR, no Python: only macOS system libraries |
| `--build-dir DIR` | Build directory, default `./build` |
| `--clean` | Remove `build/` before configuring |
| `--distclean` | Also remove `dist/` and `.cache/` |
| `--reconfigure` | Force configure even if `config.status` matches |
| `--offline` | Never access the network |
| `--no-sign` | Skip signing (the result cannot debug) |
| `--no-verify` | Skip the smoke test |
| `--timeout SECS` | Smoke test timeout, default 180 |
| `--dry-run` | Print commands without running them |
| `--verbose` | Show more diagnostics |

Environment variables with the same meaning: `GAD_PREFIX`,
`GAD_BUILD_DIR`, `GAD_CACHE_DIR`, `GAD_JOBS`, `CODESIGN_IDENTITY`,
`GAD_GMP_PREFIX`, `GAD_MPFR_PREFIX`, `GAD_PYTHON`, `CC`, `CXX`, `NO_COLOR`.

## Portable builds

`./build.sh --portable` produces a `gdb` that depends only on the libraries
macOS ships.  Two things change:

- GMP and MPFR are taken as static archives.  `scripts/build-deps.sh` copies
  them from Homebrew when available and otherwise downloads the pinned
  upstream tarballs and builds them with `--disable-shared`.  Everything is
  staged under `.cache/deps`, outside the installation prefix.
- Python is disabled, because linking a Homebrew Python framework would put
  a third-party dylib back into the binary.

After installation the build inspects `otool -L` and fails if anything
outside `/usr/lib`, `/System` or `/Library/Apple` is referenced.  Use this
mode when copying the binary to another Mac; a normal build is not
relocatable because it points at `/opt/homebrew` paths.

## Python scripting

GDB's Python support needs the Python development headers.  The build looks
for a usable interpreter, in this order: `GAD_PYTHON`, `python3` on `PATH`,
`/opt/homebrew/bin/python3`, `/usr/local/bin/python3`.  An interpreter is
only accepted when `Python.h` exists in its include directory, which rules
out the stub that the command line tools provide.  Install a full Python
(`brew install python`) to get scripting; otherwise the build configures
`--without-python` and GDB works normally without it.

Force the decision with `--no-python`, or point at a specific interpreter:

```sh
GAD_PYTHON=/opt/homebrew/bin/python3 ./build.sh --reconfigure
```

Check the result with:

```sh
./dist/bin/gdb --batch -ex 'python print(gdb.VERSION)'
```

## Configure flags

```sh
"${SOURCE_DIR}/configure" \
    --srcdir="${SOURCE_DIR}" \
    --prefix="${PREFIX}" \
    --disable-sim \
    --disable-werror \
    --enable-codesign=- \
    --with-gmp="${GMP_PREFIX}" \
    --with-mpfr="${MPFR_PREFIX}"
```

- `--disable-sim` skips the instruction simulator; the project only needs
  the native debugger.
- `--disable-werror` keeps a newer clang from failing the build on a
  warning that upstream has not fixed yet.
- `--enable-codesign=-` makes the link step apply an ad hoc signature with
  the debugger entitlement, so the binary always carries
  `com.apple.security.cs.debugger`.  The real identity is applied afterwards
  by `scripts/sign.sh`.
- `--with-gmp` and `--with-mpfr` point at Homebrew; `GMPINC` and `GMPLIBS`
  are also exported because the GDB subdirectory links those libraries
  directly.

## Reusing a source tree

If a checkout already exists, skip the download:

```sh
./build.sh --source "$HOME/Git/binutils-gdb/binutils-gdb"
```

The patches are applied in place.  A tree that already contains the backend
is left untouched, which makes this mode safe to re-run.  `--offline`
guarantees that no network access happens.

To iterate on the patches themselves, pass `--source` and use
`--reconfigure` only when the configuration needs to change; `make` in the
build directory then behaves as usual.

## Logs and artefacts

| Path | Content |
| --- | --- |
| `build/configure.log` | configure output |
| `build/build.log` | compiler output |
| `build/install.log` | installation output |
| `dist/bin/gdb` | the debugger |
| `dist/share/gdb` | GDB's runtime data directory |
| `.cache/binutils-gdb` | upstream checkout with the patches applied |

A failed phase prints the last 40 lines of its log.  The full log is kept
for inspection.

## Clean rebuilds

```sh
./build.sh --clean          # new build directory, cached source kept
./build.sh --distclean      # remove build, install and cached source
./scripts/uninstall.sh --yes
```

`--distclean` re-downloads the source on the next run; `--clean` does not.

## Custom GMP, MPFR or toolchain

```sh
GAD_GMP_PREFIX=/opt/gmp GAD_MPFR_PREFIX=/opt/mpfr ./build.sh --reconfigure
CC=/opt/llvm/bin/clang CXX=/opt/llvm/bin/clang++ ./build.sh --reconfigure
```

The script still uses the SDK reported by `xcrun`; override `SDKROOT` in the
environment if a specific SDK is required.

## Continuous integration

```sh
./build.sh --no-verify --prefix "$PWD/dist"
./scripts/verify.sh
```

Signing needs a certificate and a private key in the login keychain.  On a
CI machine, import a development certificate into a temporary keychain
first; see [SIGNING.md](SIGNING.md).

`--no-sign` exists so the build can be exercised without a certificate, but
such a GDB cannot start an inferior.

## Updating the pinned revision

`UPSTREAM_REV` in `scripts/lib/common.sh` selects the upstream commit.
`patches/README.md` explains how to rebase the series onto a newer revision
and regenerate the patches.
