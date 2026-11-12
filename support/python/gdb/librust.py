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



def _field(value, name):
    for field in value.type.fields():
        if field.name == name:
            return value[field]
    raise gdb.error("no field %s" % name)


def _hash_parts(val, via_map=False):
    """Return (ctrl bytes, bucket_mask, items, element type)."""
    base = _field(val, "base")
    if via_map:
        base = _field(base, "map")
    table = _field(base, "table")
    inner = _field(table, "table")
    marker = _field(table, "marker")
    elem = marker.type.template_argument(0)
    bucket_mask = int(_field(inner, "bucket_mask"))
    items = int(_field(inner, "items"))
    ctrl = _field(inner, "ctrl")
    if ctrl.type.code == gdb.TYPE_CODE_STRUCT:
        ctrl = _field(ctrl, "pointer")
    return ctrl, bucket_mask, items, elem


def _hash_buckets(val, via_map=False):
    ctrl, bucket_mask, items, elem = _hash_parts(val, via_map)
    if items == 0:
        return
    data = gdb.selected_inferior().read_memory(int(ctrl),
                                               bucket_mask + 1).tobytes()
    size = elem.sizeof
    end = int(ctrl)
    for i, byte in enumerate(data):
        if byte & 0x80:
            continue
        slot = gdb.Value(end - (i + 1) * size).cast(elem.pointer())
        yield slot.dereference()


class HashMapPrinter:
    def __init__(self, val):
        self.val = val

    def _items(self):
        return int(_field(_field(_field(_field(self.val, "base"), "table"),
                                 "table"), "items"))

    def to_string(self):
        return "HashMap with %d elements" % self._items()

    def children(self):
        try:
            for item in _hash_buckets(self.val):
                yield str(item["__0"]), item["__1"]
        except (gdb.error, RuntimeError):
            return


class HashSetPrinter:
    def __init__(self, val):
        self.val = val

    def _items(self):
        return int(_field(_field(_field(_field(_field(self.val, "base"),
                                                "map"), "table"), "table"),
                          "items"))

    def to_string(self):
        return "HashSet with %d elements" % self._items()

    def children(self):
        try:
            index = 0
            for item in _hash_buckets(self.val, via_map=True):
                yield "[%d]" % index, item["__0"]
                index += 1
        except (gdb.error, RuntimeError):
            return


def _make_printers():
    pp = gdb.printing.RegexpCollectionPrettyPrinter("librust")
    pp.add_printer("vec", r"^alloc::vec::Vec<.*>$", VecPrinter)
    pp.add_printer("string", r"^alloc::string::String$", StringPrinter)
    pp.add_printer("rc", r"^alloc::(?:rcs::rc::Rc|rc::Rc)<.*>$",
                   lambda val: RcPrinter(val, "Rc"))
    pp.add_printer("arc", r"^alloc::(?:rcs::arc::Arc|sync::Arc)<.*>$",
                   lambda val: RcPrinter(val, "Arc"))
    pp.add_printer("hashmap",
                   r"^std::collections::hash::map::HashMap<.*>$",
                   HashMapPrinter)
    pp.add_printer("hashset",
                   r"^std::collections::hash::set::HashSet<.*>$",
                   HashSetPrinter)
    return pp


gdb.printing.register_pretty_printer(None, _make_printers(), replace=True)
