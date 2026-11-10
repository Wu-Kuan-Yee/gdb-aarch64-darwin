# Embedded Python and Guile

The default build links Python and Guile the way Homebrew provides them,
which means the installed GDB stops working when those dylibs disappear.
This document describes a build where both runtimes are linked statically
and their data directories are shipped inside the installation prefix, so
the debugger needs nothing outside `/usr/lib` and `/System` at run time.

`./build.sh --embedded` drives the whole pipeline.  This document explains
what it does and what to expect.

## What the result looks like

```text
<prefix>/bin/gdb          the signed debugger, only system libraries
<prefix>/lib/python3.12/  Python 3.12.7 standard library (pruned)
<prefix>/share/guile/3.0/ Guile 3.0 Scheme sources
<prefix>/lib/guile/3.0/ccache/  their compiled cache (the compiler needs it)
<prefix>/share/gdb/       GDB's own data directory
```

`otool -L <prefix>/bin/gdb` lists libSystem, libc++, libncurses,
libexpat, libiconv, libffi and CoreFoundation only.

## Building the runtimes

Python needs a static `libpython3.12.a`; Homebrew does not ship one, so
build CPython from source. The optional extension modules must not link
Homebrew libraries, so OpenSSL, xz and libb2 are staged as archives:

```sh
# static OpenSSL, xz and libb2 prefixes, archives only
make -C /path/to/openssl install_sw DESTDIR=/tmp/openssl-static  # or copy .a
# then build CPython against them
CPPFLAGS="-I/tmp/openssl-static/include -I/tmp/xz-static/include" \
LDFLAGS="-L/tmp/openssl-static/lib -L/tmp/xz-static/lib" \
./configure --prefix=/tmp/pystatic --disable-shared --without-ensurepip \
            --with-openssl=/tmp/openssl-static
make -j 12 && make install
```

Guile ships `libguile-3.0.a` and its dependencies (bdw-gc, libunistring,
libltdl, libgmp) also have archives. Stage them with a pkg-config file
that points at the archives and adds the system `-framework CoreFoundation`
and `-lffi` that the static libunistring and Guile need. GDB's configure
also wants the `guild` variable, so put a working `guild` path in the
`.pc`; it is only used while compiling GDB's Scheme files.

`scripts/build-embedded.sh` performs these steps; the sections below are
the implementation notes.

## Building GDB

Run the normal driver with the staged prefixes and isolated pkg-config:

```sh
GAD_PYTHON=/tmp/pystatic/bin/python3.12 \
GAD_GMP_PREFIX=$PWD/.cache/deps/gmp \
GAD_MPFR_PREFIX=$PWD/.cache/deps/mpfr \
PKG_CONFIG_LIBDIR=/tmp/guile-static/lib/pkgconfig:/tmp/zstd-static/lib/pkgconfig:/usr/lib/pkgconfig \
PKG_CONFIG_PATH=/tmp/guile-static/lib/pkgconfig:/tmp/zstd-static/lib/pkgconfig \
CPPFLAGS="-DGDB_EMBEDDED_ROOT=\"$PREFIX\" -I/tmp/xz-static/include -I/tmp/zstd-static/include" \
LDFLAGS="-Wl,-export_dynamic -L/tmp/xz-static/lib -L/tmp/zstd-static/lib" \
./build.sh --latest --prefix "$PREFIX" --no-verify
```

`GDB_EMBEDDED_ROOT` is what removes the launcher: patch 0012 makes the
Python initialisation set `config.home` to it and makes Guile load both
`<root>/share/guile/3.0` (sources) and `<root>/lib/guile/3.0/ccache`
(compiled modules) from the prefix only.

`-Wl,-export_dynamic` matters: the Python extension modules are still
`.so` files and have to resolve `Py*` symbols from the executable.

## Packaging

```sh
cp -a /tmp/pystatic/lib/python3.12 "$PREFIX/lib/python3.12"   # prune test/ etc.
cp -a /opt/homebrew/share/guile/3.0 "$PREFIX/share/guile/3.0"
```

No launcher is needed: `bin/gdb` is the debugger, and it locates both data
directories from `GDB_EMBEDDED_ROOT`.

## Caveats

- `bin/gdb` is the signed binary; there is no `gdb-bin` or wrapper.
- Python is 3.12.7, not the Homebrew 3.15. The standard library is pruned
  (no test suite, idlelib, tkinter, lib2to3); `ssl`, `zlib`, `sqlite3`,
  `hashlib` and `lzma` work and are self-contained.
- Guile's ports are not flushed when GDB exits; a Scheme script that
  prints should end with `(force-output)`.
- GDB needs `SHELL` in the environment to start an inferior through the
  shell. This is pre-existing behaviour, not specific to this build.
- Rebuilding requires the staged `/tmp` prefixes above; they are build
  inputs, not runtime dependencies.
- The installed tree is about 137 MB: 23 MB debugger, 57 MB Python
  standard library, 6 MB Guile sources and 48 MB Guile's compiled cache.
