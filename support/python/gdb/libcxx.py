# Pretty printers for libc++ (the C++ standard library used by clang on
# macOS).  libc++ does not embed a .debug_gdb_scripts section, so these
# printers are registered globally when GDB starts.

import re

import gdb
import gdb.printing


def _strip_typedefs(t):
    while t.code == gdb.TYPE_CODE_TYPEDEF:
        t = t.target()
    return t


def _string_units(data, size, elem_size):
    units = []
    for i in range(size):
        try:
            unit = data[i]
        except gdb.error:
            unit = (data + i).dereference()
        units.append(int(unit) & ((1 << (8 * elem_size)) - 1))
    return units


def _decode_units(units, elem_size):
    enc = {1: "utf-8", 2: "utf-16-le", 4: "utf-32-le"}.get(elem_size)
    if enc is None:
        return "?".join(str(u) for u in units)
    raw = b"".join(u.to_bytes(elem_size, "little") for u in units)
    return raw.decode(enc, errors="replace")


_HOST_UTF8 = None


def _quote(text):
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


def _string_body(val):
    rep = val["__rep_"]
    short = rep["__s"]
    if int(short["__is_long_"]) == 0:
        size = int(short["__size_"])
        data = short["__data_"]
    else:
        long_rep = rep["__l"]
        size = int(long_rep["__size_"])
        data = long_rep["__data_"]
    return data, size


class StringPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        data, size = _string_body(self.val)
        if size == 0:
            return '""'
        elem_size = self.val.type.template_argument(0).sizeof
        return _quote(_decode_units(_string_units(data, size, elem_size),
                                    elem_size))


class StringViewPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        size = int(self.val["__size_"])
        if size == 0:
            return '""'
        elem_size = self.val.type.template_argument(0).sizeof
        data = self.val["__data_"]
        return _quote(_decode_units(_string_units(data, size, elem_size),
                                    elem_size))


class VectorPrinter:
    def __init__(self, val):
        self.val = val

    def _bounds(self):
        val = self.val
        begin = val["__begin_"]
        end = val["__end_"]
        return begin, end

    def to_string(self):
        begin, end = self._bounds()
        n = int(end - begin)
        return "std::__1::vector of length %d" % n

    def children(self):
        begin, end = self._bounds()
        n = int(end - begin)
        for i in range(n):
            yield "[%d]" % i, (begin + i).dereference()


class UniquePtrPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        ptr = self.val["__ptr_"]
        # In current libc++ the compressed pair holding the pointer is
        # transparent to the debug info and __ptr_ is already the pointer.
        if ptr.type.code == gdb.TYPE_CODE_STRUCT:
            ptr = ptr["__value_"]
        if int(ptr) == 0:
            return "std::__1::unique_ptr = nullptr"
        return "std::__1::unique_ptr = %s" % ptr


class SharedPtrPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        p = self.val["__ptr_"]
        if int(p) == 0:
            return "std::__1::shared_ptr = nullptr"
        return "std::__1::shared_ptr = %s" % p


class OptionalPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        try:
            engaged = int(self.val["__engaged_"])
        except gdb.error:
            try:
                engaged = int(self.val["__base_"])
            except gdb.error:
                engaged = 1
        if not engaged:
            return "std::__1::optional = (empty)"
        try:
            inner = self.val["__val_"]
        except gdb.error:
            inner = self.val["__base_"]["__val_"]
        return "std::__1::optional = %s" % inner

    def children(self):
        try:
            engaged = int(self.val["__engaged_"])
        except gdb.error:
            return
        if engaged:
            yield "value", self.val["__val_"]


class _TreeIterator:
    """Walk a libc++ __tree in order."""

    def __init__(self, val, kind):
        self.val = val
        self.kind = kind
        self.node_type = _tree_node_type(val, kind)

    def _root(self):
        tree = self.val["__tree_"]
        try:
            root = tree["__end_node_"]["__left_"]
        except gdb.error:
            # Older layouts keep the end node at offset sizeof(void*).
            addr = int(tree.address) + gdb.lookup_type("void").pointer().sizeof
            base_ptr = gdb.lookup_type(
                "std::__1::__tree_node_base<void*>").pointer()
            root = gdb.Value(addr).cast(base_ptr).dereference()["__left_"]
        return root.cast(self.node_type)

    def __iter__(self):
        node = self._root()
        stack = []
        while int(node) != 0 or stack:
            while int(node) != 0:
                stack.append(node)
                node = node.dereference()["__left_"].cast(self.node_type)
            node = stack.pop()
            yield node.dereference()["__value_"]
            node = node.dereference()["__right_"].cast(self.node_type)


def _template_args(t):
    args = []
    i = 0
    while True:
        try:
            args.append(t.template_argument(i).strip_typedefs())
        except (gdb.error, RuntimeError):
            break
        i += 1
    return args


def _tree_node_type(val, kind):
    args = [str(t) for t in _template_args(val.type)]
    if kind in ("map", "multimap"):
        value_type = "std::__1::__value_type<%s, %s>" % (args[0], args[1])
    else:
        value_type = args[0]
    name = "std::__1::__tree_node<%s, void*>" % value_type
    return gdb.lookup_type(name).pointer()


class TreePrinter:
    def __init__(self, val, kind):
        self.val = val
        self.kind = kind

    def to_string(self):
        size = int(self.val["__tree_"]["__size_"])
        return "std::__1::%s with %d elements" % (self.kind, size)

    def children(self):
        index = 0
        for value in _TreeIterator(self.val, self.kind):
            if self.kind in ("map", "multimap"):
                yield str(value["first"]), value["second"]
            else:
                yield "[%d]" % index, value
                index += 1


def _kind_of(type_name):
    for kind in ("multimap", "map", "multiset", "set"):
        if type_name.startswith("std::__1::%s<" % kind):
            return kind
    return None


def _tree_printer(kind):
    return lambda val: TreePrinter(val, kind)


class HashPrinter:
    def __init__(self, val, kind):
        self.val = val
        self.kind = kind
        self.node_type = _hash_node_type(val, kind)

    def _head(self):
        table = self.val["__table_"]
        return table["__first_node_"]["__next_"].cast(self.node_type)

    def to_string(self):
        return "std::__1::%s" % self.kind

    def children(self):
        index = 0
        node = self._head()
        while int(node) != 0:
            value = node.dereference()["__value_"]
            if self.kind in ("unordered_map", "unordered_multimap"):
                yield str(value["first"]), value["second"]
            else:
                yield "[%d]" % index, value
            index += 1
            node = node.dereference()["__next_"].cast(self.node_type)


def _hash_node_type(val, kind):
    args = [str(t) for t in _template_args(val.type)]
    if kind in ("unordered_map", "unordered_multimap"):
        value_type = "std::__1::__hash_value_type<%s, %s>" % (args[0], args[1])
    else:
        value_type = args[0]
    name = "std::__1::__hash_node<%s, void*>" % value_type
    return gdb.lookup_type(name).pointer()


def _hash_printer(kind):
    return lambda val: HashPrinter(val, kind)


class TuplePrinter:
    def __init__(self, val):
        self.val = val

    def _leaves(self, impl):
        for field in impl.type.fields():
            name = str(field.type)
            if "__tuple_leaf<" in name:
                yield impl[field]["__value_"]
            elif "__tuple_impl<" in name:
                yield from self._leaves(impl[field])

    def to_string(self):
        return "std::__1::tuple"

    def children(self):
        for i, value in enumerate(self._leaves(self.val["__base_"])):
            yield "[%d]" % i, value


def _variant_base(val):
    for field in val.type.fields():
        if field.name == "__data":
            return val
    for field in val.type.fields():
        if field.is_base_class:
            found = _variant_base(val[field])
            if found is not None:
                return found
    return None


class VariantPrinter:
    def __init__(self, val):
        self.val = val

    def _active(self):
        base = _variant_base(self.val["__impl_"])
        index = int(base["__index"])
        count = len(_template_args(self.val.type))
        if index >= count:
            return None
        node = base["__data"]
        for _ in range(index):
            node = node["__tail"]
        return index, node["__head"]["__value"]

    def to_string(self):
        active = self._active()
        if active is None:
            return "std::__1::variant = (valueless)"
        index, value = active
        return "std::__1::variant (index %d) = %s" % (index, value)

    def children(self):
        active = self._active()
        if active is None:
            return
        index, value = active
        yield "index", index
        yield "value", value

class ArrayPrinter:
    def __init__(self, val):
        self.val = val

    def _count(self):
        try:
            return int(self.val.type.template_argument(1))
        except (gdb.error, RuntimeError):
            return int(self.val["__elems_"].type.sizeof /
                       self.val["__elems_"].type.target().sizeof)

    def to_string(self):
        return "std::__1::array of length %d" % self._count()

    def children(self):
        elems = self.val["__elems_"]
        for i in range(self._count()):
            yield "[%d]" % i, elems[i]


class SpanPrinter:
    def __init__(self, val):
        self.val = val

    def _size(self):
        try:
            return int(self.val["__size_"])
        except gdb.error:
            try:
                return int(self.val.type.template_argument(1))
            except (gdb.error, RuntimeError):
                return 0

    def to_string(self):
        return "std::__1::span of length %d" % self._size()

    def children(self):
        data = self.val["__data_"]
        for i in range(self._size()):
            yield "[%d]" % i, (data + i).dereference()


class BitsetPrinter:
    def __init__(self, val):
        self.val = val

    def _words(self):
        n_words = (self._size() + 63) // 64
        words = []
        first = self.val["__first_"]
        try:
            elem_type = first.type.target()
        except gdb.error:
            elem_type = first.type
        ptr = first
        if first.type.code != gdb.TYPE_CODE_PTR:
            ptr = first.address.cast(elem_type.pointer())
        for i in range(n_words):
            words.append(int((ptr + i).dereference()))
        return words

    def _size(self):
        try:
            return int(self.val.type.template_argument(0))
        except (gdb.error, RuntimeError):
            return 64

    def to_string(self):
        n = self._size()
        words = self._words()
        bits = "".join(
            "1" if (words[i // 64] >> (i % 64)) & 1 else "0"
            for i in range(n))
        return "std::__1::bitset<%d> = 0b%s" % (n, bits)

    def children(self):
        n = self._size()
        words = self._words()
        for i in range(n):
            if (words[i // 64] >> (i % 64)) & 1:
                yield "[%d]" % i, 1


class ValarrayPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return "std::__1::valarray of length %d" % int(
            self.val["__end_"] - self.val["__begin_"])

    def children(self):
        begin = self.val["__begin_"]
        end = self.val["__end_"]
        for i in range(int(end - begin)):
            yield "[%d]" % i, (begin + i).dereference()


class VectorBoolPrinter:
    def __init__(self, val):
        self.val = val

    def _word(self, i):
        ptr = self.val["__begin_"]
        return int((ptr + (i // 64)).dereference())

    def to_string(self):
        return "std::__1::vector<bool> of length %d" % int(
            self.val["__size_"])

    def children(self):
        n = int(self.val["__size_"])
        for i in range(n):
            yield "[%d]" % i, bool((self._word(i) >> (i % 64)) & 1)


class DequePrinter:
    def __init__(self, val):
        self.val = val

    def _block_size(self):
        elem = self.val.type.template_argument(0)
        return 4096 // elem.sizeof if elem.sizeof < 256 else 16

    def to_string(self):
        return "std::__1::deque of length %d" % int(self.val["__size_"])

    def children(self):
        n = int(self.val["__size_"])
        start = int(self.val["__start_"])
        block = self._block_size()
        map_begin = self.val["__map_"]["__begin_"]
        for k in range(n):
            pos = start + k
            block_ptr = (map_begin + (pos // block)).dereference()
            value = (block_ptr + (pos % block)).dereference()
            yield "[%d]" % k, value


class ListPrinter:
    def __init__(self, val):
        self.val = val

    def _node_type(self):
        elem = str(self.val.type.template_argument(0).strip_typedefs())
        return gdb.lookup_type(
            "std::__1::__list_node<%s, void*>" % elem).pointer()

    def to_string(self):
        try:
            size = int(self.val["__size_"])
        except gdb.error:
            size = -1
        return "std::__1::list with %d elements" % size

    def children(self):
        node_type = self._node_type()
        end = self.val["__end_"]
        end_addr = int(end.address)
        node = end["__next_"].cast(node_type)
        index = 0
        while int(node) != end_addr:
            yield "[%d]" % index, node.dereference()["__value_"]
            index += 1
            node = node.dereference()["__next_"].cast(node_type)


class ForwardListPrinter:
    def __init__(self, val):
        self.val = val

    def _node_type(self):
        elem = str(self.val.type.template_argument(0).strip_typedefs())
        return gdb.lookup_type(
            "std::__1::__forward_list_node<%s, void*>" % elem).pointer()

    def to_string(self):
        return "std::__1::forward_list"

    def children(self):
        node_type = self._node_type()
        node = self.val["__before_begin_"]["__next_"].cast(node_type)
        index = 0
        while int(node) != 0:
            yield "[%d]" % index, node.dereference()["__value_"]
            index += 1
            node = node.dereference()["__next_"].cast(node_type)


class AdaptorPrinter:
    def __init__(self, val, kind):
        self.val = val
        self.kind = kind

    def to_string(self):
        return "std::__1::%s" % self.kind

    def children(self):
        yield "c", self.val["c"]


def _adaptor_printer(kind):
    return lambda val: AdaptorPrinter(val, kind)


class PairPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return "std::__1::pair"

    def children(self):
        yield "first", self.val["first"]
        yield "second", self.val["second"]


class WeakPtrPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return "std::__1::weak_ptr = %s" % self.val["__ptr_"]


class ComplexPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return "std::__1::complex(%s, %s)" % (self.val["__re_"],
                                             self.val["__im_"])


class DurationPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return "std::__1::chrono::duration(%s)" % self.val["__rep_"]


class TimePointPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return "std::__1::chrono::time_point(%s)" % \
            self.val["__d_"]["__rep_"]


class InitializerListPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return "std::__1::initializer_list of length %d" % int(
            self.val["__size_"])

    def children(self):
        data = self.val["__begin_"]
        for i in range(int(self.val["__size_"])):
            yield "[%d]" % i, (data + i).dereference()


class PathPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return StringPrinter(self.val["__pn_"]).to_string()


class ReferenceWrapperPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return "std::__1::reference_wrapper = %s" % self.val["__f_"]



def _find_member(val, name):
    for field in val.type.fields():
        if field.name == name:
            return val[field]
    for field in val.type.fields():
        if not (field.is_base_class
                or field.type.code in (gdb.TYPE_CODE_STRUCT,
                                       gdb.TYPE_CODE_UNION)):
            continue
        try:
            child = val[field]
        except gdb.error:
            continue
        found = _find_member(child, name)
        if found is not None:
            return found
    return None


class AtomicPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        value = _find_member(self.val, "__a_value")
        if value is None:
            return "std::__1::atomic"
        return "std::__1::atomic = %s" % value




def _make_printers():
    pp = gdb.printing.RegexpCollectionPrettyPrinter("libcxx")
    pp.add_printer("string", r"^std::__1::basic_string<.*>$", StringPrinter)
    pp.add_printer("string_view",
                   r"^std::__1::basic_string_view<.*>$", StringViewPrinter)
    pp.add_printer("vector_bool",
                   r"^std::__1::vector<bool,.*>$", VectorBoolPrinter)
    pp.add_printer("vector", r"^std::__1::vector<.*>$", VectorPrinter)
    pp.add_printer("array", r"^std::__1::array<.*>$", ArrayPrinter)
    pp.add_printer("span", r"^std::__1::span<.*>$", SpanPrinter)
    pp.add_printer("bitset", r"^std::__1::bitset<.*>$", BitsetPrinter)
    pp.add_printer("valarray", r"^std::__1::valarray<.*>$", ValarrayPrinter)
    pp.add_printer("deque", r"^std::__1::deque<.*>$", DequePrinter)
    pp.add_printer("list", r"^std::__1::list<.*>$", ListPrinter)
    pp.add_printer("forward_list",
                   r"^std::__1::forward_list<.*>$", ForwardListPrinter)
    pp.add_printer("stack", r"^std::__1::stack<.*>$",
                   _adaptor_printer("stack"))
    pp.add_printer("queue", r"^std::__1::queue<.*>$",
                   _adaptor_printer("queue"))
    pp.add_printer("priority_queue", r"^std::__1::priority_queue<.*>$",
                   _adaptor_printer("priority_queue"))
    pp.add_printer("pair", r"^std::__1::pair<.*>$", PairPrinter)
    pp.add_printer("weak_ptr", r"^std::__1::weak_ptr<.*>$", WeakPtrPrinter)
    pp.add_printer("complex", r"^std::__1::complex<.*>$", ComplexPrinter)
    pp.add_printer("duration", r"^std::__1::chrono::duration<.*>$",
                   DurationPrinter)
    pp.add_printer("time_point", r"^std::__1::chrono::time_point<.*>$",
                   TimePointPrinter)
    pp.add_printer("initializer_list",
                   r"^std::(?:__1::)?initializer_list<.*>$",
                   InitializerListPrinter)
    pp.add_printer("path", r"^std::__1::(__fs::)?filesystem::path$",
                   PathPrinter)
    pp.add_printer("reference_wrapper",
                   r"^std::__1::reference_wrapper<.*>$",
                   ReferenceWrapperPrinter)
    pp.add_printer("unique_ptr", r"^std::__1::unique_ptr<.*>$",
                   UniquePtrPrinter)
    pp.add_printer("shared_ptr", r"^std::__1::shared_ptr<.*>$",
                   SharedPtrPrinter)
    pp.add_printer("optional", r"^std::__1::optional<.*>$", OptionalPrinter)
    pp.add_printer("map", r"^std::__1::map<.*>$", _tree_printer("map"))
    pp.add_printer("multimap", r"^std::__1::multimap<.*>$",
                   _tree_printer("multimap"))
    pp.add_printer("set", r"^std::__1::set<.*>$", _tree_printer("set"))
    pp.add_printer("multiset", r"^std::__1::multiset<.*>$",
                   _tree_printer("multiset"))
    pp.add_printer("unordered_map",
                   r"^std::__1::unordered_map<.*>$",
                   _hash_printer("unordered_map"))
    pp.add_printer("unordered_multimap",
                   r"^std::__1::unordered_multimap<.*>$",
                   _hash_printer("unordered_multimap"))
    pp.add_printer("unordered_set",
                   r"^std::__1::unordered_set<.*>$",
                   _hash_printer("unordered_set"))
    pp.add_printer("unordered_multiset",
                   r"^std::__1::unordered_multiset<.*>$",
                   _hash_printer("unordered_multiset"))
    pp.add_printer("atomic", r"^std::__1::atomic<.*>$", AtomicPrinter)
    pp.add_printer("tuple", r"^std::__1::tuple<.*>$", TuplePrinter)
    pp.add_printer("variant", r"^std::__1::variant<.*>$", VariantPrinter)
    return pp


gdb.printing.register_pretty_printer(None, _make_printers(), replace=True)
