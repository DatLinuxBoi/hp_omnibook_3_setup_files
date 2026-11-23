#!/usr/bin/env python3
"""Read a .dtb file (read-only) and print every 'firmware-name' and the model.

A .dtb is a packed tree: nodes (folders) holding properties (name = value).
This walks that tree and prints the node path for each firmware-name value.
"""
import struct, sys

data = open(sys.argv[1], "rb").read()
magic, total, off_struct, off_strings = struct.unpack(">IIII", data[:16])
assert magic == 0xD00DFEED, "not a dtb"

def string_at(off):
    end = data.index(b"\0", off_strings + off)
    return data[off_strings + off:end].decode()

pos, path = off_struct, []
while True:
    tok = struct.unpack(">I", data[pos:pos + 4])[0]; pos += 4
    if tok == 1:  # start of a node
        end = data.index(b"\0", pos)
        path.append(data[pos:end].decode()); pos = (end + 4) & ~3
    elif tok == 2:  # end of a node
        path.pop()
    elif tok == 3:  # a property
        length, nameoff = struct.unpack(">II", data[pos:pos + 8]); pos += 8
        value = data[pos:pos + length]; pos = (pos + length + 3) & ~3
        name = string_at(nameoff)
        if name in ("firmware-name", "model") or (name == "compatible" and len(path) == 1):
            vals = [v.decode() for v in value.split(b"\0") if v]
            print("/".join(path) or "/", name, vals)
    elif tok == 9:  # end of tree
        break
