"""Generate a Repo overlay or verify the pinned YARP projects after sync."""

import json
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET


def device_fetch_url():
    """Private device repo needs an authenticated fetch URL on Actions."""
    token = os.environ.get("GEZI_TOKEN", "")
    if token:
        return f"https://x-access-token:{token}@github.com/Gezi121"
    return "https://github.com/Gezi121"


def main():
    command, lock_path, source_path = sys.argv[1:]
    lock = json.loads(Path(lock_path).read_text(encoding="utf-8"))
    source = Path(source_path)
    if command == "overlay":
        manifest = ET.Element("manifest")
        for project in lock["projects"]:
            ET.SubElement(manifest, "extend-project", {
                **project, "upstream": "refs/heads/twrp-16.0"
            })
        ET.SubElement(manifest, "remote", {
            "name": "yarp-device", "fetch": device_fetch_url()
        })
        ET.SubElement(manifest, "project", {
            "name": lock["device"]["name"],
            "path": lock["device"]["path"],
            "revision": lock["device"].get("revision", "main"),
            "remote": "yarp-device",
        })
        target = source / ".repo/local_manifests/yarp-pins.xml"
        target.parent.mkdir(parents=True, exist_ok=True)
        ET.ElementTree(manifest).write(target, encoding="utf-8", xml_declaration=True)
        print(f"Wrote {target}")
    elif command == "verify":
        projects = [{"path": ".repo/manifests", **lock["manifest"]}]
        projects += lock["projects"]
        for project in projects:
            actual = subprocess.check_output(
                ["git", "-C", str(source / project["path"]), "rev-parse", "HEAD"],
                text=True,
            ).strip()
            if actual != project["revision"]:
                raise RuntimeError(f"Source mismatch: {project['path']}: {actual}")
            print(f"Verified {project['path']}: {actual}")
    else:
        raise ValueError(f"Unknown command: {command}")


if __name__ == "__main__":
    main()
