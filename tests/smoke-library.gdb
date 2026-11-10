# Shared library part of the smoke test, driven by scripts/verify.sh.
#
# after_load stops before the library exists, so the breakpoint on
# library_add starts out pending and has to be resolved when dlopen loads
# the library later.

set pagination off
set confirm off
set breakpoint pending on

break after_load
run
break library_add
continue
bt 3
print a
print b
continue
