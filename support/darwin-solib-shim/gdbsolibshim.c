/* Early-solib helper for Darwin.
 *
 * dyld only publishes its image list after the exec stop, which means a
 * library loaded from a constructor is already in use before GDB can see
 * it.  This dylib is injected only into the inferior.  It registers a
 * callback for newly added images and executes a breakpoint instruction
 * when a non-system image appears, so GDB stops inside dlopen, refreshes
 * its solib list and re-sets pending breakpoints before the constructor
 * calls into the new library.
 *
 * Prototype status: with the helper injected through
 * DYLD_INSERT_LIBRARIES, a pending breakpoint on a function called from a
 * constructor is hit after one continue.  The remaining work is to let
 * GDB inject the dylib itself and to consume the trap silently.
 */

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <string.h>

static volatile int enabled;

static int
is_system_image (const char *path)
{
  if (path == NULL)
    return 1;
  return strncmp (path, "/usr/lib/", 9) == 0
	 || strncmp (path, "/System/", 8) == 0;
}

static void
image_added (const struct mach_header *mh, intptr_t slide)
{
  Dl_info info;

  if (!enabled)
    return;
  if (dladdr ((const void *) mh, &info) == 0 || is_system_image (info.dli_fname))
    return;

  /* Trap at a known instruction inside this dylib: GDB can recognize the
     stop by its PC instead of guessing from the signal alone.  */
  __asm__ volatile ("brk #0");
}

__attribute__((constructor)) static void
shim_init (void)
{
  _dyld_register_func_for_add_image (image_added);
  enabled = 1;
}
