# Pretty printers for a few Rust standard-library types.  GDB understands
# Rust enums/tuples/slices; these cover the containers whose internal
# layout is otherwise exposed.

import gdb
import gdb.printing


def _read_bytes(ptr, length):
    if length == 0:
        return b""
    inferior = gdb.selected_inferior()
    return inferior.read_memory(int(ptr), length).tobytes()


def _vec_parts(val):
    """Return (data pointer, length) of alloc::vec::Vec."""
    buf = val["buf"]
    inner = buf["inner"]
    ptr = inner["ptr"]["pointer"]
    return ptr, int(val["len"])


class VecPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        ptr, length = _vec_parts(self.val)
        try:
            elem = self.val.type.template_argument(0)
            return "Vec<%s> of length %d" % (elem, length)
        except (gdb.error, RuntimeError):
            return "Vec of length %d" % length

    def children(self):
        ptr, length = _vec_parts(self.val)
        try:
            elem = self.val.type.template_argument(0)
        except (gdb.error, RuntimeError):
            return
        data = ptr.cast(elem.pointer())
        for i in range(length):
            yield "[%d]" % i, (data + i).dereference()


class StringPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        try:
            ptr, length = _vec_parts(self.val["vec"])
            text = _read_bytes(ptr, length).decode("utf-8", errors="replace")
            return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')
        except (gdb.error, RuntimeError):
            return None


class RcPrinter:
    def __init__(self, val, kind):
        self.val = val
        self.kind = kind

    def to_string(self):
        return self.kind

    def children(self):
        try:
            inner = self.val["ptr"]["pointer"].dereference()
            try:
                yield "strong", inner["strong"]["value"]["value"]
            except gdb.error:
                yield "strong", inner["strong"]
            try:
                yield "value", inner["value"]
            except gdb.error:
                yield "value", inner["data"]
        except gdb.error:
            return


def _make_printers():
    pp = gdb.printing.RegexpCollectionPrettyPrinter("librust")
    pp.add_printer("vec", r"^alloc::vec::Vec<.*>$", VecPrinter)
    pp.add_printer("string", r"^alloc::string::String$", StringPrinter)
    pp.add_printer("rc", r"^alloc::(?:rcs::rc::Rc|rc::Rc)<.*>$",
                   lambda val: RcPrinter(val, "Rc"))
    pp.add_printer("arc", r"^alloc::(?:rcs::arc::Arc|sync::Arc)<.*>$",
                   lambda val: RcPrinter(val, "Arc"))
    return pp


gdb.printing.register_pretty_printer(None, _make_printers(), replace=True)
