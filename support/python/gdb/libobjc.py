# Objective-C conveniences for the Darwin port.  LLDB's 'po' evaluates
# -description and prints the resulting string; these commands do the same
# with GDB's inferior-call support.

import gdb
import gdb.printing


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


class _ObjcDescription(gdb.Parameter):
    """Enable automatic -description summaries for Objective-C objects."""

    def __init__(self):
        super().__init__("print objc-description", gdb.COMMAND_DATA,
                         gdb.PARAM_BOOLEAN)
        self.value = True
        self.description = "Print Objective-C object descriptions"

    def get_set_string(self):
        return ""

    def get_show_string(self, value):
        return "Printing Objective-C object descriptions is %s." % value


_objc_description = _ObjcDescription()


def _is_objc_class(t):
    try:
        name = str(t).split("<")[0].strip()
        if name.endswith("objc_object") or name in ("NSObject", "NSProxy"):
            return True
        for field in t.fields():
            if field.is_base_class:
                if _is_objc_class(field.type):
                    return True
            elif field.name in ("NSObject", "NSProxy"):
                return True
    except (gdb.error, RuntimeError):
        pass
    return False


class _ObjcSummary:
    def __init__(self, value, class_type):
        self.value = value
        self.class_type = class_type

    def to_string(self):
        try:
            gdb.set_convenience_variable("__gdb_objc_obj", self.value)
            try:
                cls = gdb.parse_and_eval(
                    "(char *)object_getClassName((void *)$__gdb_objc_obj)")
                class_name = cls.string() if int(cls) else "id"
            except gdb.error:
                class_name = str(self.class_type)
            try:
                desc = gdb.parse_and_eval(
                    "(char *)[[$__gdb_objc_obj description] UTF8String]")
                text = desc.string() if int(desc) else "(nil)"
            except gdb.error:
                text = ""
            address = int(self.value)
            if text:
                if text.startswith("<") and text.endswith(">"):
                    return "(%s *) 0x%x %s" % (class_name, address, text)
                return "(%s *) 0x%x <%s>" % (class_name, address, text)
            return "(%s *) 0x%x" % (class_name, address)
        except (gdb.error, RuntimeError):
            return None


class _ObjcPrinter:
    name = "objc-summary"
    enabled = True

    def __call__(self, value):
        if not _objc_description.value:
            return None
        try:
            t = value.type
            if t.code != gdb.TYPE_CODE_PTR:
                return None
            target = t.target()
            if target.code != gdb.TYPE_CODE_STRUCT:
                return None
            if not _is_objc_class(target):
                return None
            return _ObjcSummary(value, target)
        except (gdb.error, RuntimeError):
            return None


gdb.printing.register_pretty_printer(None, _ObjcPrinter(), replace=True)
