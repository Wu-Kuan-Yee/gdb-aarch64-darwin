# Objective-C conveniences for the Darwin port.  LLDB's 'po' evaluates
# -description and prints the resulting string; these commands do the same
# with GDB's inferior-call support.

import gdb


class PoCommand(gdb.Command):
    """Print the -description of an Objective-C object."""

    def __init__(self):
        super().__init__("po", gdb.COMMAND_DATA)

    def invoke(self, arg, from_tty):
        expr = arg.strip()
        if not expr:
            gdb.execute("print")
            return
        try:
            text = gdb.parse_and_eval(
                "(char *)[[%s description] UTF8String]" % expr)
            if int(text) == 0:
                gdb.write("$ = nil\n")
            else:
                gdb.write("$ = %s\n" % text.string())
        except gdb.error:
            gdb.execute("print %s" % expr)


class PclassCommand(gdb.Command):
    """Print the runtime class name of an Objective-C object."""

    def __init__(self):
        super().__init__("pclass", gdb.COMMAND_DATA)

    def invoke(self, arg, from_tty):
        expr = arg.strip()
        if not expr:
            gdb.execute("print")
            return
        try:
            name = gdb.parse_and_eval(
                "(char *)object_getClassName((void *)(%s))" % expr)
            if int(name) == 0:
                gdb.write("$ = nil\n")
            else:
                gdb.write("$ = %s\n" % name.string())
        except gdb.error:
            gdb.execute("print %s" % expr)


PoCommand()
PclassCommand()
