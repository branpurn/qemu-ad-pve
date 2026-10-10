#!/usr/bin/env python3
"""Bare-metal audit: compare the facts reported by L1 and L2 with what the setup configuration promises.

usage: evaluate.py --env /etc/qemu-ad/setup.env --facts FILE [--facts FILE ...]
FILE holds key=value lines (l1-facts.sh, l2-facts.ps1, l2-facts.py output). Prints PASS/FAIL/INFO/SKIP rows and
`AUDIT=PASS|FAIL` (exit 0 / 1). Expectations come from setup.env (QAD_L2_* written by setup.sh), so an install with
`l2.smbios=none`, `l2.optional_patches=none`, ... is checked against what it asked for, not the defaults.
Lab/dev software-compatibility tooling; see docs/bare-metal-appearance.md.
"""
import argparse
import re
import shlex
import sys


def parse_env(path):
    env = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        try:
            parts = shlex.split(v)
        except ValueError:
            parts = [v]
        env[k] = parts[0] if parts else ""
    return env


def parse_facts(paths):
    facts = {}
    for p in paths:
        for line in open(p, encoding="utf-8", errors="replace"):
            line = line.rstrip("\r\n")
            m = re.match(r"^([A-Za-z0-9_.]+)=(.*)$", line)
            if m:
                facts[m.group(1)] = m.group(2).strip()
    return facts


def smbios_fields(blob):
    """{type: {key: value}} from the `|`-separated QAD_L2_SMBIOS (`type=N,key=value,...`; ',,' is a literal comma)."""
    out = {}
    for ent in (blob or "").split("|"):
        m = re.match(r"^type=(\d+),(.*)$", ent)
        if not m:
            continue
        d = {}
        for km in re.finditer(r"(?:^|,)([a-z_]+)=((?:[^,]|,,)*)", m.group(2)):
            d[km.group(1)] = km.group(2).replace(",,", ",")
        out[int(m.group(1))] = d
    return out


def indexed(facts, prefix, field):
    pat = re.compile(r"^" + re.escape(prefix) + r"\.(\d+)\." + re.escape(field) + r"$")
    return [facts[k] for k in sorted(facts, key=lambda s: (len(s), s)) if pat.match(k)]


class Report:
    def __init__(self):
        self.rows = []

    def add(self, status, name, value, expect=""):
        self.rows.append((status, name, value, expect))

    def check(self, name, ok, value, expect):
        self.add("PASS" if ok else "FAIL", name, value, expect)

    @property
    def failed(self):
        return any(r[0] == "FAIL" for r in self.rows)


def evaluate(env, facts):
    r = Report()
    cpu = env.get("QAD_L2_CPU", "")
    patches = [p for p in env.get("QAD_L2_OPTIONAL_PATCHES", "").split(",") if p]
    smb = smbios_fields(env.get("QAD_L2_SMBIOS", ""))

    # ---- L1 -------------------------------------------------------------------------------------------
    if "l1.detect_virt" in facts:
        if env.get("QAD_L1_BARE_METAL") == "1":
            r.check("L1 systemd-detect-virt", facts["l1.detect_virt"] == "none", facts["l1.detect_virt"], "none")
            r.check("L1 cpuinfo hypervisor flag", facts.get("l1.cpuinfo_hypervisor_flag") == "0",
                    facts.get("l1.cpuinfo_hypervisor_flag", "?"), "0")
            r.check("L1 DMI sys_vendor", facts.get("l1.dmi.sys_vendor") == "ASUS", facts.get("l1.dmi.sys_vendor", "?"), "ASUS")
            r.check("L1 DMI chassis_type", facts.get("l1.dmi.chassis_type") == "3", facts.get("l1.dmi.chassis_type", "?"), "3 (Desktop)")
            r.check("L1 DMI bios_vendor", "American Megatrends" in facts.get("l1.dmi.bios_vendor", ""),
                    facts.get("l1.dmi.bios_vendor", "?"), "American Megatrends Inc.")
        else:
            r.add("INFO", "L1 systemd-detect-virt", facts["l1.detect_virt"], "(l1.smbios/hide_hypervisor not default)")
        r.check("L1 /dev/kvm", facts.get("l1.kvm_dev") == "present", facts.get("l1.kvm_dev", "?"), "present")
    else:
        r.add("SKIP", "L1 facts", "not collected", "")

    # ---- L2 -------------------------------------------------------------------------------------------
    if "cs.manufacturer" not in facts:
        r.add("SKIP", "L2 facts", "not collected (L2 not reachable)", "")
        return r
    hide = "-hypervisor" in cpu
    r.check("L2 HypervisorPresent", (facts.get("cs.hypervisor_present", "") == "False") == hide,
            facts.get("cs.hypervisor_present", "?"), "False" if hide else "(cpu keeps the bit)")
    if "cpuid.hypervisor_bit" in facts:
        r.check("L2 CPUID leaf1 ECX bit31", (facts["cpuid.hypervisor_bit"] == "0") == hide,
                facts["cpuid.hypervisor_bit"], "0" if hide else "(cpu keeps the bit)")
        zero = facts.get("cpuid.leaf40000000", "") in ("0x0,0x0,0x0,0x0",)
        if "kvm=off" in cpu:
            r.check("L2 CPUID 0x40000000", zero, facts.get("cpuid.leaf40000000", "?"), "0x0,0x0,0x0,0x0")
        else:
            r.add("INFO", "L2 CPUID 0x40000000", facts.get("cpuid.leaf40000000", "?"), "")
    else:
        r.add("SKIP", "L2 CPUID/ACPI/registry", "no Python in L2 (stage a python installer)", "")
    r.check("L2 systeminfo 'hypervisor' lines", (facts.get("systeminfo.hypervisor_lines", "?") == "0") == hide,
            facts.get("systeminfo.hypervisor_lines", "?"), "0" if hide else "")

    if smb:
        t0, t1, t2, t4, t17 = (smb.get(i, {}) for i in (0, 1, 2, 4, 17))
        r.check("SMBIOS 0 BIOS vendor", facts.get("bios.manufacturer") == t0.get("vendor"), facts.get("bios.manufacturer", "?"), t0.get("vendor"))
        r.check("SMBIOS 0 BIOS version", facts.get("bios.version") == t0.get("version"), facts.get("bios.version", "?"), t0.get("version"))
        r.check("SMBIOS 0 BIOS date", facts.get("bios.date") == t0.get("date"), facts.get("bios.date", "?"), t0.get("date"))
        r.check("SMBIOS 1 system", (facts.get("cs.manufacturer"), facts.get("cs.model")) == (t1.get("manufacturer"), t1.get("product")),
                f'{facts.get("cs.manufacturer")} / {facts.get("cs.model")}', f'{t1.get("manufacturer")} / {t1.get("product")}')
        r.check("SMBIOS 2 board", (facts.get("board.manufacturer"), facts.get("board.product")) == (t2.get("manufacturer"), t2.get("product")),
                f'{facts.get("board.manufacturer")} / {facts.get("board.product")}', f'{t2.get("manufacturer")} / {t2.get("product")}')
        if env.get("QAD_L2_CHASSIS_B64"):
            r.check("SMBIOS 3 chassis type", facts.get("enclosure.chassis_types") == "3", facts.get("enclosure.chassis_types", "?"), "3 (Desktop)")
            r.check("SMBIOS 3 chassis manufacturer", facts.get("enclosure.manufacturer") == "ASUSTeK COMPUTER INC.",
                    facts.get("enclosure.manufacturer", "?"), "ASUSTeK COMPUTER INC.")
        else:
            r.add("INFO", "SMBIOS 3 chassis", f'{facts.get("enclosure.manufacturer")} types={facts.get("enclosure.chassis_types")}', "(raw desktop chassis off)")
        r.check("SMBIOS 4 CPU", facts.get("cpu.name") == t4.get("version") and facts.get("cpu.socket", "").startswith(t4.get("sock_pfx", "\0")),
                f'{facts.get("cpu.name")} / {facts.get("cpu.socket")}', f'{t4.get("version")} / {t4.get("sock_pfx")}*')
        dm = indexed(facts, "dimm", "manufacturer")
        dp = indexed(facts, "dimm", "part")
        r.check("SMBIOS 17 DIMM", bool(dm) and dm[0] == t17.get("manufacturer") and dp[0] == t17.get("part"),
                f"{dm[0] if dm else '?'} / {dp[0] if dp else '?'}", f'{t17.get("manufacturer")} / {t17.get("part")}')
    else:
        r.add("INFO", "SMBIOS 0-4/17", f'{facts.get("cs.manufacturer")} / {facts.get("cs.model")} / {facts.get("board.product")}', "(l2.smbios=none)")

    mac = env.get("QAD_L2_MAC", "").upper().replace(":", "-")
    macs = [m.upper().replace(":", "-") for m in indexed(facts, "nic", "mac")]
    oui_ok = bool(macs) and any(m == mac for m in macs)
    r.check("L2 NIC MAC (OUI %s)" % mac[:8], oui_ok, ", ".join(macs) or "?", mac)

    model = env.get("QAD_L2_DISK_MODEL", "")
    dmods, dfw = indexed(facts, "disk", "model"), indexed(facts, "disk", "firmware")
    if model:
        r.check("L2 disk model", model in dmods, ", ".join(dmods) or "?", model)
        fw = env.get("QAD_L2_DISK_FW", "")
        if fw:
            r.check("L2 disk firmware", fw in dfw, ", ".join(dfw) or "?", fw)
    else:
        r.add("INFO", "L2 disk", ", ".join(dmods), "(l2.disk_model empty)")

    if "acpi.tables" in facts:
        tables = facts["acpi.tables"].split(",")
        if "0001-acpi-omit-waet" in patches:
            r.check("ACPI WAET table", "WAET" not in tables, facts["acpi.tables"], "absent")
        else:
            r.add("INFO", "ACPI tables", facts["acpi.tables"], "(WAET patch off)")
        if "0002-acpi-oem-id-table-id-revision" in patches:
            want = (env.get("QAD_L2_OEM_ID", ""), env.get("QAD_L2_OEM_TABLE_ID", "").rstrip(), env.get("QAD_L2_OEM_REVISION", "").lower())
            bad = []
            for k, v in facts.items():
                if re.match(r"^acpi\.\d+$", k):
                    sig, oem, tid, rev = v.split("|")
                    if (oem, tid.rstrip(), rev.lower()) != want:
                        bad.append(f"{sig}:{oem}/{tid}/{rev}")
            r.check("ACPI OEM id / table id / revision (all tables)", not bad, "all match" if not bad else "; ".join(bad), " / ".join(want))
        else:
            r.add("INFO", "ACPI OEM", "default (patch 0002 off)", "")
        sbv = facts.get("reg.SystemBiosVersion", "")
        items = [s.strip() for s in sbv.split(";")]
        if "0002-acpi-oem-id-table-id-revision" in patches:
            want_oem = "%s - %s" % (env.get("QAD_L2_OEM_ID", ""), env.get("QAD_L2_OEM_REVISION", "").lower().replace("0x", ""))
            r.check("Registry SystemBiosVersion OEM entry", want_oem in [i.lower() for i in items] or want_oem.lower() in [i.lower() for i in items], sbv, want_oem)
        if env.get("QAD_L2_OVMF_IDENTITY") == "1":
            r.check("Registry SystemBiosVersion firmware vendor", any(i.startswith("American Megatrends") for i in items), sbv, "American Megatrends ...")
        else:
            r.add("INFO", "Registry SystemBiosVersion", sbv, "(ovmf_identity off)")
    else:
        r.add("SKIP", "ACPI / registry", "not collected", "")

    cdn, cdm = indexed(facts, "cdrom", "name"), indexed(facts, "cdrom", "media")
    cmodel = env.get("QAD_L2_CDROM_MODEL", "")
    if cmodel and "0003-atapi-inquiry-from-model" not in facts.get("l1.qemu_optpatches", "0003-atapi-inquiry-from-model"):
        r.add("INFO", "L2 optical drive model", ", ".join(cdn) or "none",
              "(QEMU built without patch 0003, shown as the base 'ASUS ASUS DVD-ROM'; rebuild l1_optional_qemu to get %s)" % cmodel)
    elif cmodel:
        r.check("L2 optical drive model", cmodel in cdn, ", ".join(cdn) or "none", cmodel)
    else:
        r.add("INFO", "L2 optical drive", ", ".join(cdn) or "none", "(l2.cdrom_model empty: patched QEMU default)")
    if env.get("QAD_L2_DETACH_STAGE", "1") == "1":
        r.check("L2 optical drive media (staging ISO detached)", "True" not in cdm, ", ".join(cdm) or "none", "no media")
    else:
        r.add("INFO", "L2 optical drive media", ", ".join(cdm) or "none", "(l2.detach_stage_iso = no)")

    if "residue.unattend" in facts:
        for key, label, opt in (("residue.unattend", "Answer-file residue (unattend.xml, Panther)", "QAD_L2_CLEAN_UNATTEND"),
                                ("residue.staging", "Staging residue (C:\\qad installers, firstlogon/gpu-driver)", "QAD_L2_CLEAN_STAGING")):
            if env.get(opt, "1") == "1":
                r.check(label, facts[key] == "", facts[key] or "none", "none")
            else:
                r.add("INFO", label, facts[key] or "none", "(l2.cleanup_* = no)")

    gpu = [(n, c) for n, c in zip(indexed(facts, "video", "name"), indexed(facts, "video", "code")) if "NVIDIA" in n]
    r.check("L2 GPU problem code", bool(gpu) and all(c == "0" for _, c in gpu), ", ".join(f"{n}: {c}" for n, c in gpu) or "no NVIDIA device", "0")
    return r


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--env", required=True)
    ap.add_argument("--facts", action="append", default=[])
    a = ap.parse_args(argv)
    r = evaluate(parse_env(a.env), parse_facts(a.facts))
    w = max([len(x[1]) for x in r.rows] + [5])
    for st, name, val, exp in r.rows:
        print(f"{st:<5} {name:<{w}}  {val}" + (f"   [expected: {exp}]" if exp and st != "PASS" else ""))
    print("AUDIT=" + ("FAIL" if r.failed else "PASS"))
    return 1 if r.failed else 0


if __name__ == "__main__":
    sys.exit(main())
