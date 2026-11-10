# Smoke test for the AArch64 Darwin backend, driven by scripts/verify.sh.
#
# The sequence exercises the parts of the port that are easy to get wrong:
# Mach-O symbol loading, software breakpoints, frame unwinding, register
# access, and the ARM64 hardware watchpoint registers.

set pagination off
set confirm off

info files
break add
run
bt 2
info registers pc sp
next
next
print counter
delete 1
watch counter
continue
print counter
delete 2
continue
