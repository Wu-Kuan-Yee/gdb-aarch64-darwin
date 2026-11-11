/* Early-solib helper for Darwin.
 *
 * dyld only publishes its image list after the exec stop, which means a
 * library loaded from a constructor is already in use before GDB can see
 * it.  This dylib is injected only into the inferior.  It registers a
 * callback for newly added images and executes a breakpoint instruction
 * when a non-system image appears, so GDB stops inside dlopen, refreshes
 * its solib list and re-sets pending breakpoints before the constructor
 * calls into the new library.  GDB injects this dylib itself and discards
 * the SIGUSR2 report, so the refresh happens without a visible stop.
 */

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <signal.h>
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

  /* One report is enough: after this stop GDB has installed dyld's own
     notifier, which covers all later additions.  */
  enabled = 0;

  /* GDB sets SIGUSR2 to nostop/noprint/nopass, so this stop is consumed
     and the inferior continues after the solib refresh.  */
  raise (SIGUSR2);
}

__attribute__((constructor)) static void
shim_init (void)
{
  _dyld_register_func_for_add_image (image_added);
  enabled = 1;
}
