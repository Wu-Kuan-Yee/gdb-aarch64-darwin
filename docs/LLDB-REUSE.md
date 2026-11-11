# Reusing LLDB's Darwin machinery

The goal is for this GDB to do what LLDB does on macOS without requiring
LLDB at run time: write Mach-O core files, read them back, and understand
the dyld shared cache.  This note records what the LLDB sources actually
contain, what can be reused, and what has to be written from scratch.

LLDB lives at <https://github.com/llvm/llvm-project/tree/main/lldb> and is
licensed Apache-2.0 WITH LLVM-exception.  That licence is compatible with
GDB's GPLv3-or-later, so code can be ported as long as the LLVM notices and
licence text are kept in the derived files.

## Mach-O core writer

`lldb/source/Plugins/ObjectFile/Mach-O/ObjectFileMachO.cpp` contains
`ObjectFileMachO::SaveCore` (about 377 lines, starting around line 6271).
It is self-contained file-format code:

- build a `mach_header_64` with `filetype = MH_CORE`;
- one `LC_SEGMENT_64` per memory range, with `vmaddr`, `vmsize`, `fileoff`,
  `filesize`, `maxprot`/`initprot`;
- `LC_THREAD` commands carrying the register state (`ARM_THREAD_STATE64`
  for arm64);
- the memory payload appended page-aligned.

The ranges come from `Process::CalculateCoreFileSaveRanges`, which applies
the "dirty pages only" default.  On GDB's side the equivalents are the
thread list (`darwin_thread_t`), `gdbarch` register sets, and the same
`mach_vm_region` walk that already backs `info proc mappings`.

Effort: the writer itself is a few days.  It is not enough on its own,
because GDB cannot read a Mach-O core today:

```text
(gdb) file hello
(gdb) core-file /tmp/lldb.core
"/tmp/lldb.core": Core file format not supported
```

That message comes from BFD/GDB's generic core reader, which only knows
ELF and a few other formats.  LLDB reads these files with its own
`ProcessMachCore` plugin.  A complete `gcore` therefore needs:

1. a Mach-O core **writer** in the Darwin native target;
2. a Mach-O core **reader** integrated with GDB's core target (either a
   new target in `corelow`-style code or a BFD `mach-o` core backend),
   including `LC_SEGMENT_64` memory, `LC_THREAD` registers and thread
   lists.

Estimated total: two to four weeks for a solid implementation.

## dyld shared cache

LLDB does not contain a standalone parser that can simply be lifted.  Its
Darwin dynamic loader asks `HostInfo::GetSharedCacheImageInfo`
(`lldb/source/Host/macosx/objcxx/HostInfoMacOSX.mm`) which uses Apple's
shared-cache support and private dyld entry points, then loads images from
the cache with `ObjectFileMachO`.  The cache-format knowledge is spread
across those layers and is tied to LLDB's Host abstractions.

A GDB implementation is still possible, but it means writing the parser:
read `/System/Library/dyld/dyld_shared_cache_arm64e` (plus subcaches),
parse `dyld_cache_header`, mappings and images, resolve each image's Mach-O
header inside the cache, read its `__LINKEDIT`, and build symbols from the
local-symbols table and export trie.  This must cope with OS-version
changes and with the shared cache being the only copy of system libraries.
Estimated effort: several weeks.

## Early dlopen

This is independent of LLDB.  Current behaviour: at the exec stop
`dyld_all_image_infos` is still empty, so the solib notifier is installed
only at the next stop.  A constructor that calls `dlopen` therefore runs
before GDB has seen the library, and a pending breakpoint on one of its
functions is missed.

A real fix needs one of:

- an injected helper dylib that registers
  `_dyld_register_func_for_add_image` and traps when a non-system image is
  added, so GDB can stop inside `dlopen`, load the new solib and re-set
  breakpoints before the constructor calls into it; or
- enough shared-cache/export-trie support to put a breakpoint on `dlopen`
  before the program runs and inspect its arguments when it fires.

The first is days of work and does not depend on the cache parser; the
second is cleaner but inherits the shared-cache project above.

## Suggested order

1. Finish the libc++ printers (map, set, unordered_map, tuple, variant).
2. Early-dlopen fix through the add-image helper.
3. Mach-O core writer plus reader (this also makes `gcore` useful).
4. Shared cache parser, which also unlocks system-library symbols and the
   `dlopen`-breakpoint variant of the early-dlopen fix.
