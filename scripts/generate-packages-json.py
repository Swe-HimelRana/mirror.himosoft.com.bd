#!/usr/bin/env python3
"""Merge packages/manifest.json with built .deb artifacts → site/packages.json"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def deb_info(deb_path: Path) -> dict:
    out = subprocess.check_output(["dpkg-deb", "-I", str(deb_path)], text=True)
    wanted = frozenset({"Package", "Version", "Architecture", "Installed-Size"})
    fields: dict[str, str] = {}
    key: str | None = None
    for raw in out.splitlines():
        line = raw.strip()
        if not line:
            key = None
            continue
        if key and raw.startswith(" ") and ": " not in raw:
            fields[key] += " " + line
        elif ": " in line:
            field, val = line.split(": ", 1)
            if field in wanted:
                key = field
                fields[field] = val.strip()
            else:
                key = None
        else:
            key = None
    return fields


def pool_path(package: str, deb_name: str) -> str:
    letter = package[0].lower()
    return f"pool/main/{letter}/{package}/{deb_name}"


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    manifest_path = root / "packages" / "manifest.json"
    site_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "site"
    packages_root = root / "packages"

    manifest = json.loads(manifest_path.read_text())
    mirror_url = manifest.get("mirrorUrl", "https://mirror.himosoft.com.bd").rstrip("/")
    generated_at = datetime.now(timezone.utc).isoformat()

    # Index built .deb files by package name
    deb_index: dict[str, Path] = {}
    deb_pattern = re.compile(r"^(?P<name>.+)_(?P<ver>[^_]+)_(?P<arch>[^.]+)\.deb$")
    for deb in packages_root.glob("*/build/*.deb"):
        m = deb_pattern.match(deb.name)
        if m:
            deb_index[m.group("name")] = deb

    output_packages = []
    for entry in manifest.get("packages", []):
        name = entry["name"]
        pkg_out = {
            "name": name,
            "title": entry.get("title", name),
            "description": entry.get("description", ""),
            "status": entry.get("status", "planned"),
            "architecture": entry.get("architecture", "all"),
            "depends": entry.get("depends", []),
            "installCommand": entry.get("installCommand"),
            "usageCommand": entry.get("usageCommand"),
            "tags": entry.get("tags", []),
            "deb": None,
        }

        deb_path = deb_index.get(name)
        if deb_path and entry.get("status") == "available":
            info = deb_info(deb_path)
            rel = pool_path(name, deb_path.name)
            pkg_out.update(
                {
                    "status": "available",
                    "version": info.get("Version", entry.get("version", "")),
                    "architecture": info.get("Architecture", pkg_out["architecture"]),
                    "installedSizeKb": int(info.get("Installed-Size", "0") or 0),
                    "deb": {
                        "filename": deb_path.name,
                        "path": rel,
                        "url": f"{mirror_url}/{rel}",
                        "sizeBytes": deb_path.stat().st_size,
                    },
                }
            )
        elif entry.get("status") == "available" and not deb_path:
            pkg_out["status"] = "missing"
            pkg_out["error"] = "Listed as available but .deb not built"

        output_packages.append(pkg_out)

    payload = {
        "generatedAt": generated_at,
        "mirrorUrl": mirror_url,
        "suite": manifest.get("suite", "stable"),
        "featuredInstall": manifest.get("featuredInstall", {}),
        "packageCount": {
            "total": len(output_packages),
            "available": sum(1 for p in output_packages if p["status"] == "available"),
            "planned": sum(1 for p in output_packages if p["status"] == "planned"),
        },
        "packages": output_packages,
    }

    site_dir.mkdir(parents=True, exist_ok=True)
    out_file = site_dir / "packages.json"
    out_file.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"Wrote {out_file} ({len(output_packages)} packages)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
