#!/usr/bin/env python3
"""Verify the pinned downloads and their current Debian release metadata; never edit the lock."""
import argparse
import hashlib
import json
import lzma
from pathlib import Path
import subprocess
import tempfile
import urllib.request


def fetch(url, path, expected=None, size=None):
    if not url.startswith("https://"):
        raise ValueError("HTTPS source required")
    with urllib.request.urlopen(url, timeout=90) as response:
        data = response.read()
    if size is not None and len(data) != size:
        raise ValueError("Unexpected size: " + url)
    if expected and hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("SHA-256 mismatch: " + url)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return data


def paragraphs(text):
    for paragraph in text.split("\n\n"):
        result = {}
        key = None
        for line in paragraph.splitlines():
            if line.startswith(" ") and key:
                result[key] += "\n" + line
            elif ": " in line or line.endswith(":"):
                key, value = line.split(":", 1)
                result[key] = value.strip()
        if result:
            yield result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keyring", type=Path, default=Path("/usr/share/keyrings/debian-archive-keyring.gpg"))
    args = parser.parse_args()
    if not args.keyring.is_file():
        parser.error("Install the Debian archive keyring through a trusted package manager first")
    root = Path(__file__).resolve().parents[1]
    lock = json.loads((root / "assets.lock.json").read_text())
    if lock["schemaVersion"] != 1 or lock["distribution"] != "trixie":
        raise ValueError("Unsupported lock")
    with tempfile.TemporaryDirectory(prefix="w2d-asset-verification-") as temporary:
        work = Path(temporary)
        release_path = work / "release" / "InRelease"
        release = fetch("https://deb.debian.org/debian/dists/trixie/InRelease", release_path)
        subprocess.run(["gpgv", "--keyring", str(args.keyring), str(release_path)], check=True)
        metadata = next(item for item in paragraphs(release.decode()) if "SHA256" in item)
        if metadata.get("Version") != lock["debianVersion"]:
            raise ValueError("Current Debian release differs from the lock; review an update, do not bypass verification")
        indexes = {}
        for line in metadata["SHA256"].splitlines():
            if line.strip():
                digest, size, name = line.split()
                indexes[name] = (digest, int(size))
        checksums_name = "main/installer-amd64/current/images/SHA256SUMS"
        udebs_name = "main/debian-installer/binary-amd64/Packages.xz"
        checksums = fetch("https://deb.debian.org/debian/dists/trixie/" + checksums_name, work / "checksums" / "SHA256SUMS", *indexes[checksums_name])
        packages_data = fetch("https://deb.debian.org/debian/dists/trixie/" + udebs_name, work / "index" / "Packages.xz", *indexes[udebs_name])
        image_hashes = {line.split()[1].removeprefix("./"): line.split()[0] for line in checksums.decode().splitlines() if line.strip()}
        package_hashes = {item["Filename"]: (item["SHA256"], int(item["Size"])) for item in paragraphs(lzma.decompress(packages_data).decode()) if "Filename" in item}
        for asset in lock["assets"]:
            if asset["role"] in {"kernel", "initrd", "shim", "grub"}:
                filename = "bootnetx64.efi" if asset["role"] == "shim" else asset["name"]
                key = "netboot/debian-installer/amd64/" + filename
                if image_hashes.get(key) != asset["sha256"]:
                    raise ValueError("Locked boot artifact differs from signed Debian metadata: " + asset["name"])
            elif asset["role"] == "udeb":
                key = asset["url"].removeprefix("https://deb.debian.org/debian/")
                if package_hashes.get(key) != (asset["sha256"], asset["size"]):
                    raise ValueError("Locked udeb differs from signed Debian metadata: " + asset["name"])
            elif asset["role"] != "dbupdate":
                raise ValueError("Unknown artifact role")
            fetch(asset["url"], work / asset["name"] / asset["name"], asset["sha256"], asset["size"])
            print("VERIFIED", asset["name"], flush=True)
    print("Pinned downloads and Debian release chain verified. This is not a firmware or full-install test.")


if __name__ == "__main__":
    main()
