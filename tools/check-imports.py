#!/usr/bin/env python3
import os
import struct
import sys


def load(path):
    with open(path, "rb") as file:
        data = file.read()

    if data[:2] != b"MZ":
        return None

    header = struct.unpack_from("<I", data, 0x3C)[0]

    if data[header:header + 4] != b"PE\0\0":
        return None

    section_count = struct.unpack_from("<H", data, header + 6)[0]
    optional_size = struct.unpack_from("<H", data, header + 20)[0]
    optional = header + 24
    is64 = struct.unpack_from("<H", data, optional)[0] == 0x20B
    directories_offset = optional + (112 if is64 else 96)
    sections = [
        struct.unpack_from("<IIII", data, optional + optional_size + i * 40 + 8)
        for i in range(section_count)
    ]
    directories = [struct.unpack_from("<II", data, directories_offset + i * 8) for i in range(16)]

    return {"data": data, "sections": sections, "directories": directories, "is64": is64}


def offset(pe, rva):
    for virtual_size, virtual_address, raw_size, raw_offset in pe["sections"]:
        if virtual_address <= rva < virtual_address + max(virtual_size, raw_size):
            return rva - virtual_address + raw_offset

    raise ValueError(f"RVA {rva:#x} is outside every section")


def c_string(pe, rva):
    start = offset(pe, rva)
    end = pe["data"].index(b"\0", start)

    return pe["data"][start:end].decode("latin1")


def thunk_names(pe, rva):
    size, fmt, ordinal_bit = (8, "<Q", 63) if pe["is64"] else (4, "<I", 31)
    position = offset(pe, rva)
    names = []

    while value := struct.unpack_from(fmt, pe["data"], position)[0]:
        names.append(None if value >> ordinal_bit else c_string(pe, value + 2))
        position += size

    return names


def imports(pe):
    result = []
    import_rva = pe["directories"][1][0]
    delay_rva = pe["directories"][13][0]

    if import_rva:
        position = offset(pe, import_rva)

        while True:
            original_thunks, _, _, name, thunks = struct.unpack_from("<5I", pe["data"], position)

            if not name:
                break

            result.append(("import", c_string(pe, name), thunk_names(pe, original_thunks or thunks)))
            position += 20

    if delay_rva:
        position = offset(pe, delay_rva)

        while True:
            _, name, _, _, name_table, *_ = struct.unpack_from("<8I", pe["data"], position)

            if not name:
                break

            result.append(("delay", c_string(pe, name), thunk_names(pe, name_table)))
            position += 32

    return result


def exports(path):
    pe = load(path)
    export_rva = pe["directories"][0][0]

    if not export_rva:
        return set()

    position = offset(pe, export_rva)
    count = struct.unpack_from("<I", pe["data"], position + 24)[0]
    names_rva = struct.unpack_from("<I", pe["data"], position + 32)[0]
    names_offset = offset(pe, names_rva)

    return {c_string(pe, struct.unpack_from("<I", pe["data"], names_offset + i * 4)[0]) for i in range(count)}


def apiset_hosts(wine_dir):
    path = os.path.join(wine_dir, "apisetschema.dll")

    if not os.path.exists(path):
        return {}

    pe = load(path)
    data = pe["data"]
    header = struct.unpack_from("<I", data, 0x3C)[0]
    section_count = struct.unpack_from("<H", data, header + 6)[0]
    optional_size = struct.unpack_from("<H", data, header + 20)[0]
    base = None

    for i in range(section_count):
        section = header + 24 + optional_size + i * 40

        if data[section:section + 8].rstrip(b"\0") == b".apiset":
            base = struct.unpack_from("<I", data, section + 20)[0]

    if base is None:
        return {}

    def utf16(position, length):
        return data[base + position:base + position + length].decode("utf-16-le").lower()

    _, _, _, count, entry_offset, _, _ = struct.unpack_from("<7I", data, base)
    hosts = {}

    for i in range(count):
        _, name_offset, _, hashed_length, value_offset, value_count = struct.unpack_from(
            "<6I", data, base + entry_offset + i * 24
        )

        if not value_count:
            continue

        _, _, _, host_offset, host_length = struct.unpack_from("<5I", data, base + value_offset)

        if host_length:
            hosts[utf16(name_offset, hashed_length)] = utf16(host_offset, host_length)

    return hosts


def resolve_apiset(dll, hosts):
    name = dll.lower().removesuffix(".dll")

    if not name.startswith(("api-", "ext-")):
        return None

    return hosts.get(name.rsplit("-", 1)[0])


def wine_dll_dir(runner):
    for candidate in ("files/lib64/wine/x86_64-windows", "files/lib/wine/x86_64-windows"):
        path = os.path.join(runner, candidate)

        if os.path.isdir(path):
            return path

    sys.exit(f"No x86_64-windows DLL directory found in {runner}")


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: check-imports.py <Riot Client directory> <Proton runner directory>")

    app_dir, runner = sys.argv[1], sys.argv[2]
    wine_dir = wine_dll_dir(runner)
    hosts = apiset_hosts(wine_dir)
    app_files = {}

    for root, _, files in os.walk(app_dir):
        for name in files:
            if name.lower().endswith((".dll", ".exe")):
                app_files.setdefault(name.lower(), os.path.join(root, name))

    export_cache = {}
    missing = {}

    for name, path in sorted(app_files.items()):
        pe = load(path)

        if not pe or not pe["is64"]:
            continue

        for kind, dll, functions in imports(pe):
            key = resolve_apiset(dll, hosts) or dll.lower()
            target = app_files.get(key) or os.path.join(wine_dir, key)

            if key not in export_cache:
                export_cache[key] = exports(target) if os.path.exists(target) else None

            available = export_cache[key]

            if available is None:
                missing.setdefault((name, kind, dll), set()).add("<whole DLL missing>")
                continue

            for function in functions:
                if function and function not in available:
                    missing.setdefault((name, kind, dll), set()).add(function)

    for (name, kind, dll), functions in sorted(missing.items()):
        print(f"{name:34} {kind:6} {dll:40} {', '.join(sorted(functions))}")

    print(f"Checked {len(app_files)} files against {wine_dir}: {len(missing)} import groups with missing functions")


if __name__ == "__main__":
    main()
