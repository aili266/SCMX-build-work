#!/usr/bin/env python3
"""Build licensed offline register data. Requires cmsis-svd==0.6 and macOS Swift.

Example:
  python build-register-db.py --source-dir /path/to/research --output Resources/Registers
The source directory contains packs-report.json, the original .pack archives,
f1-report.json and verified-f1/*.svd. No downloads or hardware operations occur.
"""

import argparse
import gc
import hashlib
import importlib.metadata
import io
import json
import re
import subprocess
import sys
import tempfile
import zipfile
from collections import Counter, defaultdict
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlparse

from cmsis_svd.parser import SVDParser
from lxml import etree


F1_REPLACEMENTS = {
    "SVD/STM32F100xx.svd": "STM32F100.svd",
    "SVD/STM32F101xx.svd": "STM32F101.svd",
    "SVD/STM32F102xx.svd": "STM32F102.svd",
    "SVD/STM32F103xx.svd": "STM32F103.svd",
    "SVD/STM32F105xx.svd": "STM32F105.svd",
    "SVD/STM32F107xx.svd": "STM32F107.svd",
}
ACCESS = {"read-only", "write-only", "read-write", "writeOnce", "read-writeOnce"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def xml(data):
    parser = etree.XMLParser(resolve_entities=False, no_network=True, huge_tree=True)
    tree = etree.parse(io.BytesIO(data), parser)
    if tree.docinfo.doctype:
        raise ValueError("DOCTYPE is not allowed")
    return tree


def member(name):
    name = name.replace("\\", "/")
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError("Unsafe archive member: " + name)
    return str(path)


def profile_id(vendor, pack, svd):
    identity = vendor + "/" + pack + "/" + svd
    label = re.sub(r"[^a-zA-Z0-9_-]+", "-", vendor + "-" + pack + "-" + Path(svd).stem)
    return label + "-" + digest(identity.encode())[:12]


def family_for(name):
    # L4+ is the R/S/P/Q product line, not the classic L4 line.
    if re.match(r"STM32L4[RSPQ]", name, re.I):
        return "STM32L4+"
    for family in ("H7RS", "H7P", "MP1", "MP2", "WB0", "WBA", "WL3", "WL4",
                   "C0", "C5", "F0", "F1", "F2", "F3", "F4", "F7", "G0", "G4", "G5",
                   "H5", "H7", "L0", "L1", "L4", "L5", "N6", "U0", "U3", "U5", "WB", "WL"):
        if family == "H7RS":
            if re.match(r"STM32H7[RS]", name, re.I):
                return "STM32H7RS"
        elif name.upper().startswith("STM32" + family):
            return "STM32" + family
    raise ValueError("Unknown actual chip family: " + name)


def pdsc_devices(root):
    """Resolve debug attributes in the archive's own family/device hierarchy."""
    output = []

    def visit(node, inherited_debug, inherited_processors):
        debugs = {k: dict(v) for k, v in inherited_debug.items()}
        processors = {k: dict(v) for k, v in inherited_processors.items()}
        for child in node:
            if child.tag == "debug":
                key = child.get("Pname", "")
                debugs[key] = {**debugs.get(key, {}), **child.attrib}
            elif child.tag == "processor":
                key = child.get("Pname", "")
                processors[key] = {**processors.get(key, {}), **child.attrib}
        name = node.get("Dvariant") or node.get("Dname")
        if name:
            named = sorted(set(k for k in debugs if k) | set(k for k in processors if k))
            keys = named or [""]
            choices = []
            for key in keys:
                attributes = {**debugs.get("", {}), **debugs.get(key, {})}
                svd = attributes.get("svd")
                if svd:
                    core = key or processors.get("", {}).get("Dcore", "")
                    choices.append({"svd": member(svd), "core": core})
            output.append({"name": name, "family": family_for(name), "choices": choices})
        for child in node:
            if child.tag in {"family", "subFamily", "device", "variant"}:
                visit(child, debugs, processors)

    devices = root.find("devices")
    if devices is None:
        raise ValueError("PDSC has no devices")
    visit(devices, {}, {})
    return output


def inheritance_expectations(tree):
    """Reject unsupported/unresolved inheritance rather than export partial data."""
    expected = []
    for node in tree.xpath("//*[@derivedFrom]"):
        tag = node.tag
        parts = node.get("derivedFrom").split(".")
        source = None
        if tag == "peripheral" and len(parts) == 1:
            candidates = tree.xpath("/device/peripherals/peripheral[name=$name]", name=parts[0])
        elif len(parts) == 1:
            candidates = [n for n in node.getparent() if n.tag == tag and n.findtext("name") == parts[0]]
        elif tag in {"register", "cluster"} and len(parts) == 2:
            candidates = tree.xpath("/device/peripherals/peripheral[name=$p]//*[local-name()=$tag][name=$name]",
                                    p=parts[0], tag=tag, name=parts[1])
        else:
            raise ValueError("Unsupported derivedFrom path: " + tag + " " + node.get("derivedFrom"))
        if len(candidates) == 1:
            source = candidates[0]
        if source is None:
            raise ValueError("Unresolved derivedFrom: " + tag + " " + node.get("derivedFrom"))
        if tag == "enumeratedValues":
            continue
        missing = [child for child in source if isinstance(child.tag, str) and node.find(child.tag) is None]
        expected.append((node, missing))
    return expected


def enum_value(value):
    return value.value if hasattr(value, "value") else value


def parse_profile(raw):
    tree = xml(raw)
    if tree.find("addressUnitBits") is None or int(tree.findtext("addressUnitBits"), 0) != 8:
        raise ValueError("Only explicitly byte-addressed SVD is supported")
    # cmsis-svd 0.6 relocates direct cluster children, but not outer nested clusters.
    # None of the supplied MCU SVDs uses nested clusters. Fail closed for future inputs.
    if tree.xpath("//cluster/cluster"):
        raise ValueError("Nested clusters need an independently verified parser relocation path")
    expected = inheritance_expectations(tree)
    device = SVDParser(tree, remove_reserved=False).get_device(xml_validation=False)
    for node, missing in expected:
        for child in missing:
            actual = node.find(child.tag)
            if actual is None or (len(child) == 0 and (actual.text or "").strip() != (child.text or "").strip()):
                raise ValueError("Parser did not expand inherited " + child.tag + " for " + (node.findtext("name") or node.tag))
    rows = {}
    duplicates = 0
    for peripheral in device.get_peripherals():
        if not peripheral.name or peripheral.base_address is None:
            raise ValueError("Peripheral name/base address is missing")
        group = peripheral.group_name or re.sub(r"[0-9]+$", "", peripheral.name) or peripheral.name
        for register in peripheral.get_registers():
            if not register.name or register.address_offset is None:
                raise ValueError("Register name/offset is missing in " + peripheral.name)
            address = peripheral.base_address + register.address_offset
            access = enum_value(register.access) if register.access is not None else "unknown"
            if not 0 <= address <= 0xFFFFFFFFFFFFFFFF or register.size is None or not 1 <= register.size <= 4096:
                raise ValueError("Invalid register address/size: " + peripheral.name + "." + register.name)
            if access not in ACCESS | {"unknown"}:
                raise ValueError("Missing/unknown access: " + peripheral.name + "." + register.name)
            row = {"group": group, "instance": peripheral.name, "name": register.name,
                   "address": address, "size": register.size, "access": access,
                   "description": " ".join((register.description or "").split())}
            actions = set()
            if register.read_action is not None:
                actions.add(str(enum_value(register.read_action)))
            for field in register.get_fields():
                if field.read_action is not None:
                    actions.add(str(enum_value(field.read_action)))
            if actions:
                row["readAction"] = " / ".join(sorted(actions))
            key = (peripheral.name, register.name, address)
            if key in rows:
                if rows[key] != row:
                    raise ValueError("Conflicting duplicate definition: " + repr(key))
                duplicates += 1
            else:
                rows[key] = row
    if not rows:
        raise ValueError("Profile contains no registers")
    payload = {"name": device.name, "registers": sorted(rows.values(), key=lambda r: (r["instance"], r["address"], r["name"]))}
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    if len(encoded) > 64_000_000:
        raise ValueError("Uncompressed profile exceeds loader limit")
    return payload, encoded, duplicates


def license_for(raw, pdsc, archive, pack_name):
    tree = xml(raw)
    notices = [str(n.text) for n in tree.xpath("//comment()")
               if re.search(r"copyright|license|SPDX|redistribution", str(n.text), re.I)]
    notices += tree.xpath("/device/licenseText/text()")
    notice = "\n\n".join(notices)
    declarations = [value.strip() for value in re.findall(r"SPDX-License-Identifier:\s*([^\r\n]+)", notice)]
    if any(value != "Apache-2.0" for value in declarations):
        if not (pack_name.lower() == "stm32h7pxx_dfp" and set(declarations) == {"BSD-3-Clause"}):
            raise ValueError("SVD declares an unsupported explicit license: " + ", ".join(declarations))
    if re.search(r"SPDX-License-Identifier:\s*Apache-2\.0\b", notice) or re.search(r"Licensed under the Apache License, Version 2\.0", notice, re.I):
        return "Apache-2.0", "SVD copyright/license declaration", notice
    declaration = (pdsc.findtext("license") or "").strip()
    if declaration and declaration in archive.namelist():
        text = archive.read(declaration).decode("utf-8")
        if re.search(r"Apache License\s+Version 2\.0, January 2004", text) and "TERMS AND CONDITIONS FOR USE" in text:
            return "Apache-2.0", "PDSC declares the complete pack under " + declaration, notice
        if pack_name.lower() == "stm32h7pxx_dfp" and "BSD-3-Clause" in text and "Copyright (c) 2026 STMicroelectronics" in text:
            return "BSD-3-Clause", "H7P PDSC declares pack-wide " + declaration, notice
    raise ValueError("No explicit distributable SVD or pack-wide Apache/H7P BSD license")


def self_test():
    raw = b'''<device schemaVersion="1.3"><name>TEST</name><version>1</version><description>test</description>
    <addressUnitBits>8</addressUnitBits><width>32</width><size>32</size><access>read-write</access><peripherals>
    <peripheral><name>GPIOA</name><baseAddress>0x40000000</baseAddress><registers>
    <register><name>CTRL</name><description>control</description><addressOffset>0</addressOffset></register>
    <register derivedFrom="CTRL"><name>COPY</name><description>copy</description><addressOffset>4</addressOffset></register>
    <register><dim>2</dim><dimIncrement>4</dimIncrement><dimIndex>0-1</dimIndex><name>R%s</name><addressOffset>8</addressOffset><fields>
    <field><name>FLAG</name><bitOffset>0</bitOffset><bitWidth>1</bitWidth><readAction>clear</readAction></field></fields></register>
    <cluster><name>BLOCK</name><addressOffset>0x20</addressOffset><register><name>VALUE</name><addressOffset>4</addressOffset></register></cluster>
    <cluster><dim>2</dim><dimIncrement>0x10</dimIncrement><dimIndex>0-1</dimIndex><name>C%s</name><addressOffset>0x40</addressOffset>
    <register><name>VALUE</name><addressOffset>4</addressOffset></register></cluster></registers></peripheral>
    <peripheral derivedFrom="GPIOA"><name>GPIOB</name><baseAddress>0x50000000</baseAddress></peripheral>
    <peripheral><dim>2</dim><dimIncrement>0x100</dimIncrement><dimIndex>0-1</dimIndex><name>TIMER%s</name><baseAddress>0x60000000</baseAddress>
    <registers><register><name>COUNT</name><addressOffset>4</addressOffset></register></registers></peripheral>
    </peripherals></device>'''
    payload, _, duplicates = parse_profile(raw)
    rows = {(r["instance"], r["name"]): r for r in payload["registers"]}
    for instance, name, address in [("GPIOA", "BLOCK_VALUE", 0x40000024), ("GPIOA", "C1_VALUE", 0x40000054),
                                    ("GPIOB", "COPY", 0x50000004), ("TIMER1", "COUNT", 0x60000104), ("GPIOA", "R1", 0x4000000C)]:
        assert rows[instance, name]["address"] == address, (instance, name)
    assert rows["GPIOA", "R0"]["readAction"] == "clear" and duplicates == 0
    count_register = b'<register><name>COUNT</name><addressOffset>4</addressOffset></register>'
    duplicate, _, removed = parse_profile(raw.replace(count_register, count_register + count_register, 1))
    assert duplicate == payload and removed == 2
    try:
        conflicting = count_register.replace(b"</name>", b"</name><description>conflict</description>")
        parse_profile(raw.replace(count_register, count_register + conflicting, 1))
    except ValueError as error:
        assert "Conflicting duplicate" in str(error)
    else:
        raise AssertionError("Conflicting register definitions must be rejected")
    pdsc = b'''<package><devices><family><processor Pname="CM4"/><processor Pname="CM0"/>
    <debug svd="SVD/shared.svd"/><device Dname="STM32WB55RG"><debug Pname="CM4" svd="SVD/cm4.svd"/>
    <variant Dvariant="STM32WB55RGT6"><debug Pname="CM0" svd="SVD/cm0.svd"/></variant>
    </device></family></devices></package>'''
    mapped = pdsc_devices(xml(pdsc).getroot())
    assert mapped[0]["choices"] == [{"svd": "SVD/shared.svd", "core": "CM0"}, {"svd": "SVD/cm4.svd", "core": "CM4"}]
    assert mapped[1]["choices"] == [{"svd": "SVD/cm0.svd", "core": "CM0"}, {"svd": "SVD/cm4.svd", "core": "CM4"}]
    assert family_for("STM32L4R5ZITx") == "STM32L4+"
    assert family_for("STM32H7S3L8Hx") == "STM32H7RS"
    print("Parser self-test passed: inheritance, arrays, offsets, readAction, duplicates and PDSC core overrides", flush=True)


def audit_coverage(source, output):
    """Also inventory compatibility XMLs which no archived PDSC device uses."""
    reports = json.loads((source / "packs-report.json").read_text())
    provenance = json.loads((output / "sources.json").read_text())
    by_pack = {p["vendor"] + "." + p["name"] + "." + p["version"]: p for p in reports}
    unused = []
    for label, report in sorted(by_pack.items()):
        archive_path = source / Path(urlparse(report["pack_url"]).path).name
        if digest(archive_path.read_bytes()) != report["pack_sha256"]:
            raise ValueError("Source inventory pack SHA256 mismatch: " + label)
        with zipfile.ZipFile(archive_path) as archive:
            pdsc_name = next(n for n in archive.namelist() if n.endswith(".pdsc") and "/" not in n)
            mapped = pdsc_devices(xml(archive.read(pdsc_name)).getroot())
            referenced = {c["svd"] for d in mapped for c in d["choices"]}
            for original in report.get("svd_licenses", []):
                if original["file"] not in referenced:
                    unused.append({"pack": label, "svd": original["file"], "sha256": original["sha256"],
                                   "reason": "Not referenced by any device in this archive's PDSC; not bundled"})
    replacements = []
    for profile in provenance["profiles"]:
        if profile["replacement"]:
            report = by_pack[profile["pack"]]
            original = next(s for s in report["svd_licenses"] if s["file"] == profile["mappingSVD"])
            profile["mappingSvdSHA256"] = original["sha256"]
            replacements.append({"pack": profile["pack"], "excludedLegacySVD": profile["mappingSVD"],
                                 "legacySvdSHA256": original["sha256"], "replacementSVD": profile["svd"],
                                 "replacementSvdSHA256": profile["svdSHA256"], "reason": "Original SVD lacks explicit redistribution authorization; use verified Apache replacement"})
    dump(output / "sources.json", provenance)
    coverage = json.loads((output / "coverage.json").read_text())
    coverage["unreferencedSVDs"] = unused
    coverage["replacedLegacySVDs"] = replacements
    dump(output / "coverage.json", coverage)
    print("Source inventory:", len(unused), "unreferenced XMLs omitted;", len(replacements), "legacy F1 XMLs replaced", flush=True)


def build(args):
    source = args.source_dir.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    reports = json.loads((source / "packs-report.json").read_text())
    f1 = {r["file"]: r for r in json.loads((source / "f1-report.json").read_text())}
    exclusions, provenance, profiles = [], [], []
    devices = {}
    selected = re.compile(args.only) if args.only else None
    all_license_files = {}
    with tempfile.TemporaryDirectory(prefix="register-db-") as temporary:
        temporary = Path(temporary)
        for report in sorted(reports, key=lambda r: (r["vendor"], r["name"], r["version"])):
            pack_file = source / unquote(Path(urlparse(report["pack_url"]).path).name)
            pack_label = report["vendor"] + "." + report["name"] + "." + report["version"]
            if selected and not any(selected.search(s["file"]) for s in report.get("svd_licenses", [])):
                continue
            try:
                pack_hash = digest(pack_file.read_bytes())
                if pack_hash != report["pack_sha256"]:
                    raise ValueError("Pack SHA256 does not match research manifest")
                archive = zipfile.ZipFile(pack_file)
                pdsc_name = next(n for n in archive.namelist() if n.endswith(".pdsc") and "/" not in n)
                pdsc_raw = archive.read(pdsc_name)
                pdsc = xml(pdsc_raw).getroot()
                mapped = pdsc_devices(pdsc)
                references = sorted({c["svd"] for d in mapped for c in d["choices"]})
                accepted = {}
                for svd in references:
                    if selected and not selected.search(svd):
                        continue
                    profile = profile_id(report["vendor"], report["name"], svd)
                    try:
                        if report["name"] == "STM32MP1xx_DFP":
                            raise ValueError("Legacy MP1 SVD has no explicit redistribution authorization; excluded")
                        replacement = F1_REPLACEMENTS.get(svd) if report["name"] == "STM32F1xx_DFP" else None
                        if report["name"] == "STM32F1xx_DFP" and replacement is None:
                            raise ValueError("No explicit verified-F1 replacement mapping")
                        if replacement:
                            original = f1[replacement]
                            raw = (source / "verified-f1" / replacement).read_bytes()
                            if digest(raw) != original["sha256"]:
                                raise ValueError("Verified F1 SHA256 mismatch")
                            license_id, basis, notice = license_for(raw, pdsc, archive, report["name"])
                            source_url = original["url"]
                            profile = profile_id("stm32duino", "stm32_svd", "svd/STM32F1xx/" + replacement)
                        else:
                            raw = archive.read(svd)
                            original = next((s for s in report["svd_licenses"] if s["file"] == svd), None)
                            if original is None or digest(raw) != original["sha256"]:
                                raise ValueError("SVD SHA256 mismatch or missing research manifest entry")
                            license_id, basis, notice = license_for(raw, pdsc, archive, report["name"])
                            source_url = report["pack_url"] + "#" + svd
                        payload, encoded, duplicates = parse_profile(raw)
                        if payload["name"].startswith("STM32G431"):
                            assert any(r["instance"] == "GPIOA" and r["name"].endswith("MODER") and r["address"] == 0x48000000 for r in payload["registers"]), "G431 GPIOA address check failed"
                        if replacement == "STM32F103.svd":
                            assert any(r["instance"] == "GPIOA" and r["name"].endswith("CRL") and r["address"] == 0x40010800 for r in payload["registers"]), "F103 GPIOA address check failed"
                        (temporary / (profile + ".json")).write_bytes(encoded)
                        profiles.append({"id": profile, "name": payload["name"], "source": source_url, "license": license_id,
                                         "uncompressedLength": len(encoded), "sha256": digest(encoded), "registerCount": len(payload["registers"])})
                        accepted[svd] = profile
                        header_path = "notices/" + profile + ".txt"
                        (output / "notices").mkdir(exist_ok=True)
                        (output / header_path).write_text(notice or "No individual SVD copyright notice; see the explicit pack-wide license.\n", encoding="utf-8")
                        license_paths = []
                        for name in sorted(archive.namelist()):
                            if "/" not in name and re.match(r"(?:LICENSE|NOTICE|COPYING)(?:[.\-_].*)?$", name, re.I):
                                data = archive.read(name)
                                # F1's unrelated old peripheral-driver license is intentionally not copied.
                                license_path = "licenses/" + pack_label + "/" + name
                                all_license_files[license_path] = data
                                license_paths.append(license_path)
                        if license_id == "Apache-2.0" and not license_paths:
                            # The complete Apache text is copied below from another verified pack.
                            license_paths.append("licenses/Apache-2.0.txt")
                        provenance.append({"id": profile, "name": payload["name"], "pack": pack_label, "packURL": report["pack_url"],
                                           "packSHA256": pack_hash, "pdsc": pdsc_name, "pdscSHA256": digest(pdsc_raw),
                                           "svd": replacement or svd, "svdURL": source_url, "svdSHA256": digest(raw),
                                           "license": license_id, "licenseBasis": basis, "licenseFiles": license_paths,
                                           "noticeFile": header_path, "originalNotices": notice,
                                           "mappingSVD": svd, "replacement": bool(replacement),
                                           "identicalDuplicatesRemoved": duplicates,
                                           "readActionRegisterCount": sum("readAction" in row for row in payload["registers"]),
                                           "unspecifiedAccessRegisterCount": sum(row["access"] == "unknown" for row in payload["registers"])})
                        print("OK", payload["name"], len(payload["registers"]), "registers", license_id, flush=True)
                    except Exception as error:
                        exclusions.append({"pack": pack_label, "svd": svd, "reason": str(error), "devices": sorted(d["name"] for d in mapped if any(c["svd"] == svd for c in d["choices"]))})
                        print("EXCLUDED", pack_label, svd, str(error), file=sys.stderr, flush=True)
                    finally:
                        gc.collect()
                for device in mapped:
                    choices = defaultdict(set)
                    for choice in device["choices"]:
                        if choice["svd"] in accepted:
                            choices[accepted[choice["svd"]]].add(choice["core"])
                    if not choices:
                        if not selected and not device["choices"]:
                            exclusions.append({"pack": pack_label, "device": device["name"], "reason": "No inherited debug@svd mapping"})
                        continue
                    entry = devices.setdefault(device["name"], {"name": device["name"], "family": device["family"], "profiles": {}})
                    if entry["family"] != device["family"]:
                        raise ValueError("Conflicting family for " + device["name"])
                    for key, cores in choices.items():
                        entry["profiles"].setdefault(key, set()).update(cores)
                archive.close()
            except Exception as error:
                exclusions.append({"pack": pack_label, "reason": str(error)})
                print("EXCLUDED PACK", pack_label, str(error), file=sys.stderr, flush=True)
        apache = next((data for name, data in all_license_files.items()
                       if re.search(rb"Apache License\s+Version 2\.0, January 2004", data)), None)
        if apache is None:
            # Sample runs containing only F1 still obtain the full license from the original G4 pack.
            for report in reports:
                pack = source / Path(urlparse(report["pack_url"]).path).name
                with zipfile.ZipFile(pack) as archive:
                    for name in ["LICENSE-Apache-2.0", "LICENSE"]:
                        if name in archive.namelist():
                            data = archive.read(name)
                            if re.search(rb"Apache License\s+Version 2\.0, January 2004", data):
                                apache = data
                                break
                if apache:
                    break
        if any(p["license"] == "Apache-2.0" for p in profiles):
            if apache is None:
                raise ValueError("Complete Apache-2.0 license text is required")
            all_license_files["licenses/Apache-2.0.txt"] = apache
        for name, data in all_license_files.items():
            target = output / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        device_rows = [{"name": d["name"], "family": d["family"],
                        "profiles": [{"id": key, "core": " / ".join(sorted(core for core in cores if core))}
                                     for key, cores in sorted(d["profiles"].items())]}
                       for d in sorted(devices.values(), key=lambda d: d["name"])]
        manifest = {"schema": 1, "devices": device_rows, "profiles": sorted(profiles, key=lambda p: p["id"])}
        if not profiles or not device_rows:
            dump(output / "coverage.json", {"schema": 1, "deviceCount": 0, "profileCount": 0, "exclusions": exclusions})
            raise ValueError("No distributable profiles/devices were generated; see coverage.json")
        dump(temporary / "manifest.json", manifest)
        dump(output / "sources.json", {"schema": 1, "parser": "cmsis-svd==0.6", "profiles": sorted(provenance, key=lambda p: p["id"]),
                                       "f1Replacements": F1_REPLACEMENTS,
                                       "licenseFiles": [{"path": n, "sha256": digest(d)} for n, d in sorted(all_license_files.items())]})
        summary = {"schema": 1, "deviceCount": len(device_rows), "profileCount": len(profiles),
                   "registerCount": sum(p["registerCount"] for p in profiles),
                   "families": dict(sorted(Counter(d["family"] for d in device_rows).items())),
                   "exclusions": exclusions}
        dump(output / "coverage.json", summary)
        subprocess.run(["swift", str(Path(__file__).with_name("pack-register-db.swift")),
                        str(temporary / "manifest.json"), str(temporary), str(output)], check=True)
        audit_coverage(source, output)
        print(json.dumps({k: v for k, v in summary.items() if k != "exclusions"}, sort_keys=True), flush=True)
        print("Excluded entries:", len(exclusions), "(see coverage.json)", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--only", help="Optional SVD path regex for sample builds")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--audit", action="store_true", help="Refresh only source/exclusion inventory for an existing generated database")
    args = parser.parse_args()
    if importlib.metadata.version("cmsis-svd") != "0.6":
        parser.error("Use exactly cmsis-svd==0.6 for reproducible expansion")
    if args.self_test:
        self_test()
    if args.audit:
        if not args.source_dir or not args.output:
            parser.error("--audit requires --source-dir and --output")
        audit_coverage(args.source_dir.resolve(), args.output.resolve())
    elif args.source_dir and args.output:
        build(args)
    elif not args.self_test:
        parser.error("--source-dir and --output are required")


if __name__ == "__main__":
    main()
