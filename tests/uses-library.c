/* Exercise dlopen, a pending breakpoint and a breakpoint inside the
   library that is loaded after the first stop.  */

#include <dlfcn.h>
#include <stdio.h>

__attribute__ ((noinline)) static void
after_load (void)
{
}

int
main (void)
{
  void *handle;
  int (*add) (int, int);

  after_load ();
  handle = dlopen ("./libsample.dylib", RTLD_NOW);
  if (handle == NULL)
    {
      puts (dlerror ());
      return 1;
    }
  add = (int (*) (int, int)) dlsym (handle, "library_add");
  printf ("result=%d\n", add (2, 3));
  dlclose (handle);
  return 0;
}
