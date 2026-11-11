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

The writer is implemented (`darwin_write_core_file` in `darwin-nat.c`,
patch 0016).  `gcore` on a Darwin inferior now produces a Mach-O core
with `LC_UNIXTHREAD` register blocks, `LC_SEGMENT_64` memory and an
`LC_NOTE "process metadata"` thread list.  Apple's lldb can load it and
reports the stopped thread and PC:

```text
* thread #1: tid = 0x0000, 0x0000000100000538
      pc = 0x0000000100000538
```

GDB can now read these cores back.  BFD's generic core reader is ELF
only (and on macOS its `prstatus_t` code is compiled out), so patch 0017
adds a small `darwin-core` target: it parses `LC_SEGMENT_64` and the
thread commands, serves memory from the core, supplies registers from
the thread state blocks, and lets the exec target serve text pages that
are not stored in the core.

```text
(gdb) file hello
(gdb) core-file /tmp/macho.core
Core file '/tmp/macho.core' loaded (Mach-O, 1 threads).
(gdb) bt
#0  main () at hello.c:4
(gdb) info registers sp pc
sp   0x16fdff590
pc   0x100000538 <main+16>
```

The reader lives in `darwin-nat.c` alongside the writer and is selected
from `core_file_command` by the Mach-O core magic.

## dyld shared cache

LLDB does not contain a standalone parser that can simply be lifted.  Its
Darwin dynamic loader asks `HostInfo::GetSharedCacheImageInfo`
(`lldb/source/Host/macosx/objcxx/HostInfoMacOSX.mm`) which uses Apple's
shared-cache support and private dyld entry points, then loads images from
the cache with `ObjectFileMachO`.  The cache-format knowledge is spread
across those layers and is tied to LLDB's Host abstractions.

A GDB parser now exists (patch 0022, `darwin-shared-cache`).  It finds
the cache under `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld`
or `/System/Library/dyld`, parses the header, follows the 32-byte
subcache suffixes (`.25.dylddata`, `.81.dyldlinkedit`, ...), and reports
mappings and images:

```text
Shared cache: .../dyld_shared_cache_arm64e
  uuid: b411828b445038e3973aafe7b7b5bef5
  files: 82, mappings: 103, images: 4115, local symbols: 0
  0x1805a5000  /usr/lib/system/libsystem_c.dylib
```

The release cache on this macOS has `localSymbolsOffset == 0` for every
file: local symbols are stripped.  Symbol names therefore have to come
from each image's export trie (`LC_DYLD_EXPORTS_TRIE` in its `__LINKEDIT`).
That parser now exists too (patch 0023): it locates the image header
through the mappings, reads the trie offset from the load commands, and
walks the trie in the `.dyldlinkedit` subcache:

```text
0x1805a5000  /usr/lib/system/libsystem_c.dylib
    0x180611264  __Exit
    0x1805ab7cc  __NSGetArgc
    0x1805ab7c0  __NSGetArgv
```

The remaining step is to feed these names into GDB's minimal symbol
tables and solib list so that breakpoints, `info functions` and frames
in system libraries get names.

## Early dlopen

This is independent of LLDB and is now implemented.

At the exec stop `dyld_all_image_infos` is still empty, so the solib
notifier is installed only at the next stop; a constructor that calls
`dlopen` therefore used to run before GDB had seen the library, and a
pending breakpoint on one of its functions was missed.

GDB now injects a small helper dylib (`support/darwin-solib-shim`)
through `DYLD_INSERT_LIBRARIES` when starting an inferior.  The helper
registers `_dyld_register_func_for_add_image`; when the first non-system
image is added it raises `SIGUSR2` once.  GDB sets that signal to
`nostop noprint nopass`, so infrun discards it and continues
automatically; before that, the Darwin wait hook has refreshed the solib
list and re-set pending breakpoints, which are therefore in place before
the constructor calls into the new library.

`set darwin-early-solib off` disables both the injection and the
behaviour, falling back to the old semantics.  The trade-off is that
while the feature is on, an inferior's own `SIGUSR2` is also discarded;
that is why the setting exists.

## Suggested order

1. Improve the core format: store the executable's text and the image
   list so cores are self-describing and symbolication works without the
   original executable.
2. Shared cache parser, which also unlocks system-library symbols.
