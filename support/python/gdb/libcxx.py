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


class StringPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        val = self.val
        rep = val["__rep_"]
        short = rep["__s"]
        if int(short["__is_long_"]) == 0:
            size = int(short["__size_"])
            if size == 0:
                return '""'
            data = short["__data_"].string(length=size)
            return '"%s"' % data
        long_rep = rep["__l"]
        size = int(long_rep["__size_"])
        if size == 0:
            return '""'
        data = long_rep["__data_"].string(length=size)
        return '"%s"' % data


class StringViewPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        val = self.val
        size = int(val["__size_"])
        if size == 0:
            return '""'
        data = val["__data_"].string(length=size)
        return '"%s"' % data


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
            if self.kind == "unordered_map":
                yield str(value["first"]), value["second"]
            else:
                yield "[%d]" % index, value
            index += 1
            node = node.dereference()["__next_"].cast(self.node_type)


def _hash_node_type(val, kind):
    args = [str(t) for t in _template_args(val.type)]
    if kind == "unordered_map":
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
        node = base["__data"]
        for _ in range(index):
            node = node["__tail"]
        return index, node["__head"]["__value"]

    def to_string(self):
        index, value = self._active()
        return "std::__1::variant (index %d) = %s" % (index, value)

    def children(self):
        index, value = self._active()
        yield "index", index
        yield "value", value


def _make_printers():
    pp = gdb.printing.RegexpCollectionPrettyPrinter("libcxx")
    pp.add_printer(
        "string", r"^std::__1::basic_string<char,.*>$", StringPrinter
    )
    pp.add_printer(
        "wstring", r"^std::__1::basic_string<wchar_t,.*>$", StringPrinter
    )
    pp.add_printer(
        "string_view", r"^std::__1::basic_string_view<char,.*>$", StringViewPrinter
    )
    pp.add_printer("vector", r"^std::__1::vector<.*>$", VectorPrinter)
    pp.add_printer("unique_ptr", r"^std::__1::unique_ptr<.*>$", UniquePtrPrinter)
    pp.add_printer("shared_ptr", r"^std::__1::shared_ptr<.*>$", SharedPtrPrinter)
    pp.add_printer("optional", r"^std::__1::optional<.*>$", OptionalPrinter)
    pp.add_printer(
        "map", r"^std::__1::map<.*>$", _tree_printer("map")
    )
    pp.add_printer(
        "multimap", r"^std::__1::multimap<.*>$", _tree_printer("multimap")
    )
    pp.add_printer(
        "set", r"^std::__1::set<.*>$", _tree_printer("set")
    )
    pp.add_printer(
        "multiset", r"^std::__1::multiset<.*>$", _tree_printer("multiset")
    )
    pp.add_printer(
        "unordered_map", r"^std::__1::unordered_map<.*>$",
        _hash_printer("unordered_map"))
    pp.add_printer(
        "unordered_set", r"^std::__1::unordered_set<.*>$",
        _hash_printer("unordered_set"))
    pp.add_printer("tuple", r"^std::__1::tuple<.*>$", TuplePrinter)
    pp.add_printer("variant", r"^std::__1::variant<.*>$", VariantPrinter)
    return pp


gdb.printing.register_pretty_printer(None, _make_printers(), replace=True)
