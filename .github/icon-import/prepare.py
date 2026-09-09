#!/usr/bin/env python3
"""One-time, checksum-verified artwork import on the isolated GitHub runner."""
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import urllib.request
import zlib

repo = os.environ['GITHUB_REPOSITORY']
branch = 'fix/icon-delivery-091'
assert repo == 'kaizentrick/oruvi'
assert os.environ['GITHUB_REF'] == 'refs/heads/' + branch
head = os.environ['GITHUB_SHA']
root = Path(os.environ['GITHUB_WORKSPACE'])
os.chdir(root)
chunks = []
for index in range(1, 27):
    value = (root / '.github/icon-import' / f'{index:02}').read_bytes()
    if index in (9, 14):
        value = zlib.decompress(value)
    assert len(value) == (620 if index == 26 else 1024), f'Bad transfer segment {index}'
    chunks.append(value)
data = b''.join(chunks)
expected = 'a94835b7bd3d6f3b3e391846af6b100030d50a7ec064cd16187c52fa31816f96'
assert len(data) == 26220 and hashlib.sha256(data).hexdigest() == expected, 'Artwork transfer integrity failed'
print('Approved artwork transfer: SHA-256 verified, 26220 bytes.', flush=True)

with tempfile.TemporaryDirectory() as temporary:
    work = Path(temporary)
    webp = work / 'approved.webp'
    webp.write_bytes(data)
    converter = work / 'export.swift'
    converter.write_text('''import Foundation
import CoreGraphics
import ImageIO
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      CGImageSourceGetStatus(source) == .statusComplete,
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == 1024, image.height == 1024,
      let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)
else { fatalError("Cannot decode the approved 1024-pixel artwork") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("PNG export failed") }
print("ImageIO decoded approved artwork: 1024x1024, alpha \\(image.alphaInfo.rawValue)")
''')
    png = root / 'Resources/OruviIcon.png'
    icns = root / 'Resources/OruviIcon.icns'
    subprocess.run(['xcrun', 'swift', str(converter), str(webp), str(png)], check=True)
    iconset = work / 'Oruvi.iconset'
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = size * scale
            suffix = '@2x' if scale == 2 else ''
            target = iconset / f'icon_{size}x{size}{suffix}.png'
            if pixels == 1024:
                target.write_bytes(png.read_bytes())
            else:
                subprocess.run(['sips', '-z', str(pixels), str(pixels), str(png), '--out', str(target)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['iconutil', '-c', 'icns', '-o', str(icns), str(iconset)], check=True)
    binary = icns.read_bytes()
    assert binary[:4] == b'icns' and struct.unpack('>I', binary[4:8])[0] == len(binary)
    offset = 8
    types = []
    while offset < len(binary):
        kind, length = struct.unpack('>4sI', binary[offset:offset+8])
        assert length >= 8 and offset + length <= len(binary)
        types.append(kind.decode('ascii'))
        offset += length
    assert offset == len(binary)
    assert 'ic10' in types, 'Missing 1024-pixel representation'

manifest = {
    'design': 'Frosted Window',
    'source_file': 'OruviIcon.png',
    'source_sha256': hashlib.sha256(png.read_bytes()).hexdigest(),
    'icns_file': 'OruviIcon.icns',
    'icns_sha256': hashlib.sha256(icns.read_bytes()).hexdigest(),
    'source_pixels': [1024, 1024],
    'transport_sha256': expected,
    'export_note': 'Approved artwork; high-quality image export with opaque interior and transparent exterior. Native iconutil output.',
    'icns_chunks': types,
}
manifest_path = root / 'Resources/OruviIcon.json'
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2), flush=True)

# Commit actual binary bytes, not text disguised with a .png or .icns extension.
# The only credential is this runner's short-lived token, scoped to this repository.
def api(method, path, payload=None):
    request = urllib.request.Request(
        f'https://api.github.com/repos/{repo}/{path}',
        data=None if payload is None else json.dumps(payload).encode(),
        method=method,
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
                 'Accept': 'application/vnd.github+json', 'Content-Type': 'application/json',
                 'X-GitHub-Api-Version': '2022-11-28'},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)

assert api('GET', 'git/ref/heads/' + branch)['object']['sha'] == head, 'Branch changed during import; refusing to overwrite it'
base = api('GET', 'git/commits/' + head)
entries = []
for path in (png, icns, manifest_path):
    value = path.read_bytes()
    expected_blob = hashlib.sha1(b'blob ' + str(len(value)).encode() + b'\0' + value).hexdigest()
    blob = api('POST', 'git/blobs', {'encoding': 'base64', 'content': base64.b64encode(value).decode()})
    assert blob['sha'] == expected_blob, 'GitHub binary upload mismatch'
    entries.append({'path': path.relative_to(root).as_posix(), 'mode': '100644', 'type': 'blob', 'sha': blob['sha']})
tree = api('POST', 'git/trees', {'base_tree': base['tree']['sha'], 'tree': entries})
commit = api('POST', 'git/commits', {'message': 'Add verified native Oruvi icon assets', 'tree': tree['sha'], 'parents': [head]})
api('PATCH', 'git/refs/heads/' + branch, {'sha': commit['sha'], 'force': False})
print('Native icon assets committed to the isolated branch: ' + commit['sha'], flush=True)
with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
    summary.write('## Native icon export verified\n\n')
    summary.write('Approved transport SHA-256 matched. ImageIO decoded 1024x1024 artwork. iconutil generated the ICNS. All three uploaded Git blobs matched their expected object IDs.\n\n')
    summary.write('Asset commit: `' + commit['sha'] + '`\n')
