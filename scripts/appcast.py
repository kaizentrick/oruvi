#!/usr/bin/env python3
"""Generate update metadata; Sparkle's sign_update signs the complete XML afterwards."""
import base64
import email.utils
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

archive, version, build, repo, signature, destination = sys.argv[1:]
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
assert re.fullmatch(r"[0-9]{1,10}", build) and int(build) > 0
assert re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}", repo)
assert repo.split("/")[1] not in {".", ".."}
assert len(base64.b64decode(signature, validate=True)) == 64
path = pathlib.Path(archive)
assert path.is_file() and path.name == f"Oruvi-{version}-arm64.dmg"
ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", ns)
root = ET.Element("rss", {"version": "2.0"})
channel = ET.SubElement(root, "channel")
ET.SubElement(channel, "title").text = "Oruvi"
ET.SubElement(channel, "link").text = f"https://github.com/{repo}"
ET.SubElement(channel, "description").text = "Versiones verificadas de Oruvi para macOS"
item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"Oruvi {version} · {build}"
ET.SubElement(item, f"{{{ns}}}version").text = build
ET.SubElement(item, f"{{{ns}}}shortVersionString").text = version
ET.SubElement(item, f"{{{ns}}}minimumSystemVersion").text = "26.0.0"
ET.SubElement(item, f"{{{ns}}}hardwareRequirements").text = "arm64"
ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
ET.SubElement(item, "enclosure", {
    "url": f"https://github.com/{repo}/releases/download/v{version}-b{build}/{path.name}",
    "type": "application/octet-stream", "length": str(path.stat().st_size),
    f"{{{ns}}}edSignature": signature,
})
ET.indent(root)
ET.ElementTree(root).write(destination, encoding="utf-8", xml_declaration=True)
print("Update metadata generated; it must be signed before upload.")
