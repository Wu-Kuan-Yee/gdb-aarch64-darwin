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



_HOST_UTF8 = None


def _quote_text(text):
    global _HOST_UTF8
    if any(ord(c) > 127 for c in text):
        if _HOST_UTF8 is None:
            try:
                shown = gdb.execute("show host-charset", to_string=True)
            except gdb.error:
                shown = ""
            _HOST_UTF8 = "UTF-8" in shown.upper() or "UTF8" in shown.upper()
    parts = []
    for c in text:
        if c == "\\":
            parts.append("\\\\")
        elif c == '"':
            parts.append('\\"')
        elif ord(c) > 127 and not _HOST_UTF8:
            code = ord(c)
            parts.append("\\u%04x" % code if code <= 0xffff
                         else "\\U%08x" % code)
        else:
            parts.append(c)
    return '"%s"' % "".join(parts)


class StringPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        try:
            ptr, length = _vec_parts(self.val["vec"])
            text = _read_bytes(ptr, length).decode("utf-8", errors="replace")
            return _quote_text(text)
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



def _uninit(value):
    """Unwrap MaybeUninit<T> { value: ManuallyDrop<T> { value: T } }."""
    try:
        return value["value"]["value"]
    except gdb.error:
        return value


class BTreeMapPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return "BTreeMap with %d elements" % int(self.val["length"])

    def _types(self):
        key = self.val.type.template_argument(0)
        value = self.val.type.template_argument(1)
        leaf = gdb.lookup_type(
            "alloc::collections::btree::node::LeafNode<%s, %s>"
            % (key, value))
        internal = gdb.lookup_type(
            "alloc::collections::btree::node::InternalNode<%s, %s>"
            % (key, value))
        return leaf, internal

    def _walk(self, ptr, height, leaf_t, internal_t, depth=0):
        if depth > 32:
            return
        if height == 0:
            leaf = ptr.cast(leaf_t.pointer()).dereference()
            count = int(leaf["len"])
            for i in range(count):
                yield (_uninit(leaf["keys"][i]),
                        _uninit(leaf["vals"][i]))
            return

        node = ptr.cast(internal_t.pointer()).dereference()
        data = node["data"]
        count = int(data["len"])
        edges = node["edges"]
        for i in range(count):
            child = _uninit(edges[i])["pointer"]
            yield from self._walk(child, height - 1, leaf_t, internal_t,
                                  depth + 1)
            yield (_uninit(data["keys"][i]), _uninit(data["vals"][i]))
        child = _uninit(edges[count])["pointer"]
        yield from self._walk(child, height - 1, leaf_t, internal_t, depth + 1)

    def children(self):
        if int(self.val["length"]) == 0:
            return
        try:
            leaf_t, internal_t = self._types()
            root = _uninit(self.val["root"]["Some"]["__0"])
            ptr = root["node"]["pointer"]
            for key, value in self._walk(ptr, int(root["height"]),
                                         leaf_t, internal_t):
                yield str(key), value
        except (gdb.error, RuntimeError):
            return


class BTreeSetPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return "BTreeSet with %d elements" % int(self.val["map"]["length"])

    def _walk(self, ptr, height, leaf_t, internal_t, depth=0):
        if depth > 32:
            return
        if height == 0:
            leaf = ptr.cast(leaf_t.pointer()).dereference()
            for i in range(int(leaf["len"])):
                yield _uninit(leaf["keys"][i])
            return
        node = ptr.cast(internal_t.pointer()).dereference()
        data = node["data"]
        count = int(data["len"])
        edges = node["edges"]
        for i in range(count):
            yield from self._walk(_uninit(edges[i])["pointer"], height - 1,
                                  leaf_t, internal_t, depth + 1)
            yield _uninit(data["keys"][i])
        yield from self._walk(_uninit(edges[count])["pointer"], height - 1,
                              leaf_t, internal_t, depth + 1)

    def children(self):
        try:
            m = self.val["map"]
            key = m.type.template_argument(0)
            value = m.type.template_argument(1)
            leaf_t = gdb.lookup_type(
                "alloc::collections::btree::node::LeafNode<%s, %s>"
                % (key, value))
            internal_t = gdb.lookup_type(
                "alloc::collections::btree::node::InternalNode<%s, %s>"
                % (key, value))
            root = _uninit(m["root"]["Some"]["__0"])
            index = 0
            for key_value in self._walk(root["node"]["pointer"],
                                        int(root["height"]),
                                        leaf_t, internal_t):
                yield "[%d]" % index, key_value
                index += 1
        except (gdb.error, RuntimeError):
            return



class SliceIterPrinter:
    def __init__(self, val):
        self.val = val

    def _parts(self):
        elem = self.val.type.template_argument(0)
        ptr = _field(self.val, "ptr")
        if ptr.type.code == gdb.TYPE_CODE_STRUCT:
            ptr = _field(ptr, "pointer")
        end = _field(self.val, "end_or_len")
        if elem.sizeof == 0:
            return elem, ptr, int(end), True
        return elem, ptr, (int(end) - int(ptr)) // elem.sizeof, False

    def to_string(self):
        try:
            elem, _, count, zst = self._parts()
            return "Iter<%s> of length %d" % (elem, count)
        except (gdb.error, RuntimeError):
            return "Iter"

    def children(self):
        try:
            elem, ptr, count, zst = self._parts()
            if zst:
                return
            data = ptr.cast(elem.pointer())
            for i in range(count):
                yield "[%d]" % i, (data + i).dereference()
        except (gdb.error, RuntimeError):
            return


class VecIntoIterPrinter:
    def __init__(self, val):
        self.val = val

    def _parts(self):
        elem = self.val.type.template_argument(0)
        ptr = _field(self.val, "ptr")
        if ptr.type.code == gdb.TYPE_CODE_STRUCT:
            ptr = _field(ptr, "pointer")
        end = _field(self.val, "end")
        return elem, ptr, (int(end) - int(ptr)) // elem.sizeof

    def to_string(self):
        try:
            elem, _, count = self._parts()
            return "IntoIter<%s> of length %d" % (elem, count)
        except (gdb.error, RuntimeError):
            return "IntoIter"

    def children(self):
        try:
            elem, ptr, count = self._parts()
            data = ptr.cast(elem.pointer())
            for i in range(count):
                yield "[%d]" % i, (data + i).dereference()
        except (gdb.error, RuntimeError):
            return


class RangePrinter:
    def __init__(self, val, kind):
        self.val = val
        self.kind = kind

    def to_string(self):
        try:
            if self.kind == "range":
                return "%s..%s" % (self.val["start"], self.val["end"])
            if self.kind == "range_inclusive":
                return "%s..=%s" % (self.val["start"], self.val["end"])
            if self.kind == "range_from":
                return "%s.." % self.val["start"]
            if self.kind == "range_to":
                return "..%s" % self.val["end"]
        except gdb.error:
            pass
        return self.kind


class CharsPrinter:
    def __init__(self, val):
        self.val = val

    def _bytes(self):
        it = _field(self.val, "iter")
        ptr = _field(it, "ptr")
        if ptr.type.code == gdb.TYPE_CODE_STRUCT:
            ptr = _field(ptr, "pointer")
        end = int(_field(it, "end_or_len"))
        start = int(ptr)
        if end <= start:
            return b""
        return gdb.selected_inferior().read_memory(start, end - start).tobytes()

    def to_string(self):
        try:
            text = self._bytes().decode("utf-8", errors="replace")
            return 'Chars(%s)' % _quote_text(text)
        except (gdb.error, RuntimeError):
            return "Chars"




def _range_printer(kind):
    return lambda val: RangePrinter(val, kind)


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
    pp.add_printer("btreemap",
                   r"^alloc::collections::btree::map::BTreeMap<.*>$",
                   BTreeMapPrinter)
    pp.add_printer("btreeset",
                   r"^alloc::collections::btree::set::BTreeSet<.*>$",
                   BTreeSetPrinter)
    pp.add_printer("slice_iter", r"^core::slice::iter::Iter<.*>$",
                   SliceIterPrinter)
    pp.add_printer("vec_into_iter",
                   r"^alloc::vec::into_iter::IntoIter<.*>$",
                   VecIntoIterPrinter)
    pp.add_printer("range", r"^core::ops::range::Range<.*>$",
                   _range_printer("range"))
    pp.add_printer("range_inclusive",
                   r"^core::ops::range::RangeInclusive<.*>$",
                   _range_printer("range_inclusive"))
    pp.add_printer("range_from", r"^core::ops::range::RangeFrom<.*>$",
                   _range_printer("range_from"))
    pp.add_printer("range_to", r"^core::ops::range::RangeTo<.*>$",
                   _range_printer("range_to"))
    pp.add_printer("chars", r"^core::str::iter::Chars$", CharsPrinter)
    return pp


gdb.printing.register_pretty_printer(None, _make_printers(), replace=True)
