#!/usr/bin/env python3
"""Build a 128-byte EDID 1.4 base block for a real desktop monitor model and print it as base64.

    edid.py asus-vg248qe [--hex]

Profiles are plausible 24" 1080p monitors (valid checksum, manufacturer id, product code, serial, name/serial/range
descriptors, one detailed 1920x1080@60 timing). Used by qad-l1.sh edid -> setup/l1/windows/edid.ps1.
"""
import base64
import sys

PROFILES = {
    # name: (mfg, product code, serial, week, year, size cm (w, h), monitor name, serial text)
    "asus-vg248qe": ("AUS", 0x2448, 0x0001B5C7, 21, 2020, (53, 30), "ASUS VG248QE", "L9LMQS047310"),
    "dell-s2421h": ("DEL", 0xA0E7, 0x4C3B2A19, 14, 2021, (53, 30), "DELL S2421H", "CN0V8MTK74445"),
}


def mfg_id(s):
    v = ((ord(s[0]) - 64) << 10) | ((ord(s[1]) - 64) << 5) | (ord(s[2]) - 64)
    return bytes([v >> 8, v & 0xFF])


def text_desc(tag, s):
    t = s[:13]
    if len(t) < 13:
        t += "\n"
    return bytes([0, 0, 0, tag, 0]) + t.ljust(13).encode("ascii")


def detailed_1080p60(w_mm, h_mm):
    pclk = 14850  # 148.50 MHz in 10 kHz units
    ha, hb, hfp, hsw = 1920, 280, 88, 44
    va, vb, vfp, vsw = 1080, 45, 4, 5
    d = bytearray(18)
    d[0], d[1] = pclk & 0xFF, pclk >> 8
    d[2], d[3] = ha & 0xFF, hb & 0xFF
    d[4] = ((ha >> 8) << 4) | (hb >> 8)
    d[5], d[6] = va & 0xFF, vb & 0xFF
    d[7] = ((va >> 8) << 4) | (vb >> 8)
    d[8], d[9] = hfp & 0xFF, hsw & 0xFF
    d[10] = ((vfp & 0xF) << 4) | (vsw & 0xF)
    d[11] = ((hfp >> 8) << 6) | ((hsw >> 8) << 4) | ((vfp >> 4) << 2) | (vsw >> 4)
    d[12], d[13] = w_mm & 0xFF, h_mm & 0xFF
    d[14] = ((w_mm >> 8) << 4) | (h_mm >> 8)
    d[15], d[16] = 0, 0
    d[17] = 0x1E  # digital separate sync, +/+
    return bytes(d)


def build(name):
    mfg, prod, serial, week, year, (wcm, hcm), model, sntext = PROFILES[name]
    e = bytearray(b"\x00\xff\xff\xff\xff\xff\xff\x00")
    e += mfg_id(mfg) + prod.to_bytes(2, "little") + serial.to_bytes(4, "little")
    e += bytes([week, year - 1990, 1, 4])           # EDID 1.4
    e += bytes([0xA5, wcm, hcm, 0x78, 0x2E])        # digital 8 bit DisplayPort, size, gamma 2.2, features
    e += bytes.fromhex("EE91A3544C99260F5054")      # sRGB chromaticity
    e += bytes([0x21, 0x08, 0x00])                  # established timings 640x480@60, 800x600@60, 1024x768@60
    std = [(1920, 16, 9), (1680, 16, 10), (1600, 16, 9), (1440, 16, 10), (1280, 5, 4), (1280, 16, 9), (1024, 4, 3), None]
    aspect = {(16, 10): 0, (4, 3): 1, (5, 4): 2, (16, 9): 3}
    for s in std:
        if s is None:
            e += b"\x01\x01"
        else:
            e += bytes([s[0] // 8 - 31, (aspect[(s[1], s[2])] << 6) | 0])  # @60 Hz
    e += detailed_1080p60(wcm * 10, hcm * 10)
    e += text_desc(0xFC, model)
    e += text_desc(0xFF, sntext)
    e += bytes([0, 0, 0, 0xFD, 0, 48, 144, 30, 160, 33, 0, 10, 32, 32, 32, 32, 32, 32])  # 48-144 Hz, 30-160 kHz, 330 MHz
    e += bytes([0, 0])                              # no extension, checksum placeholder
    e[127] = (-sum(e[:127])) & 0xFF
    assert len(e) == 128 and sum(e) % 256 == 0
    return bytes(e)


def main(argv):
    if len(argv) < 2 or argv[1] not in PROFILES:
        print("usage: edid.py {%s} [--hex]" % "|".join(PROFILES), file=sys.stderr)
        return 2
    b = build(argv[1])
    print(b.hex() if "--hex" in argv else base64.b64encode(b).decode())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
