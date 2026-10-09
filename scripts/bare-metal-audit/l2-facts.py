"""Bare-metal audit, L2 part 2 (Python in C:\\qad\\venv): CPUID, ACPI table OEM fields, BIOS registry strings.
Prints key=value lines; Windows only; read-only. Run in the L2 by `qad-l1.sh audit` (setup.sh audit)."""
import ctypes
import struct
import winreg

k = ctypes.windll.kernel32
k.VirtualAlloc.restype = ctypes.c_void_p
k.VirtualAlloc.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32]
# win64: rcx=leaf, rdx=subleaf, r8=out ptr; mov eax,ecx; mov ecx,edx; cpuid; store eax,ebx,ecx,edx
CODE = bytes([0x53, 0x89, 0xC8, 0x89, 0xD1, 0x0F, 0xA2, 0x41, 0x89, 0x00, 0x41, 0x89, 0x58, 0x04, 0x41, 0x89,
              0x48, 0x08, 0x41, 0x89, 0x50, 0x0C, 0x5B, 0xC3])
mem = k.VirtualAlloc(None, 4096, 0x3000, 0x40)
ctypes.memmove(mem, CODE, len(CODE))
_f = ctypes.CFUNCTYPE(None, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p)(mem)


def cpuid(leaf, sub=0):
    o = (ctypes.c_uint32 * 4)()
    _f(leaf, sub, ctypes.addressof(o))
    return list(o)


r = cpuid(1)
print("cpuid.leaf1_ecx=0x%08x" % r[2])
print("cpuid.hypervisor_bit=%d" % ((r[2] >> 31) & 1))
print("cpuid.leaf40000000=%s" % ",".join("0x%x" % x for x in cpuid(0x40000000)))

k.EnumSystemFirmwareTables.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32]
k.GetSystemFirmwareTable.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32]
P = struct.unpack(">I", b"ACPI")[0]
n = k.EnumSystemFirmwareTables(P, None, 0)
buf = ctypes.create_string_buffer(max(n, 1))
k.EnumSystemFirmwareTables(P, buf, n)
sigs, i = [], 0
for off in range(0, n, 4):
    sig = buf.raw[off:off + 4]
    s = struct.unpack("<I", sig)[0]
    sz = k.GetSystemFirmwareTable(P, s, None, 0)
    t = ctypes.create_string_buffer(sz)
    k.GetSystemFirmwareTable(P, s, t, sz)
    raw = t.raw
    sigs.append(sig.decode("latin1"))
    print("acpi.%d=%s|%s|%s|0x%x" % (i, sig.decode("latin1"), raw[10:16].decode("latin1").rstrip("\0"),
                                     raw[16:24].decode("latin1").rstrip("\0 "), struct.unpack("<I", raw[24:28])[0]))
    i += 1
print("acpi.tables=%s" % ",".join(sigs))


def reg(path, name):
    try:
        v = winreg.QueryValueEx(winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, path), name)[0]
    except OSError:
        return ""
    return " ; ".join(v) if isinstance(v, list) else str(v)


S = r"HARDWARE\DESCRIPTION\System"
print("reg.SystemBiosVersion=" + reg(S, "SystemBiosVersion"))
print("reg.BIOSVendor=" + reg(S + r"\BIOS", "BIOSVendor"))
print("reg.BIOSVersion=" + reg(S + r"\BIOS", "BIOSVersion"))
print("reg.BIOSReleaseDate=" + reg(S + r"\BIOS", "BIOSReleaseDate"))
