#!/usr/bin/env python3
"""Validate source and packaged icon bytes before any installer is signed or published."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parent.parent
ICON = 'OruviIcon.icns'
REQUIRED = {b'ic04', b'ic05', b'ic07', b'ic08', b'ic09', b'ic10', b'ic11', b'ic12', b'ic13', b'ic14'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_icns(data):
    require(len(data) >= 8 and data[:4] == b'icns', 'Not a binary ICNS file')
    require(struct.unpack('>I', data[4:8])[0] == len(data), 'Truncated ICNS or incorrect declared length')
    offset, chunks = 8, set()
    while offset < len(data):
        require(offset + 8 <= len(data), 'Truncated ICNS chunk header')
        kind, length = struct.unpack('>4sI', data[offset:offset + 8])
        require(length >= 8 and offset + length <= len(data), 'Invalid ICNS chunk bounds')
        require(kind not in chunks, 'Duplicate ICNS representation')
        chunks.add(kind)
        offset += length
    require(offset == len(data) and REQUIRED <= chunks, 'Missing native or Retina representations')
    return chunks


def validate_png(data):
    require(data.startswith(b'\x89PNG\r\n\x1a\n'), 'Master is not a PNG')
    offset, first, ended, idat = 8, True, False, bytearray()
    while offset < len(data):
        require(offset + 12 <= len(data), 'Truncated PNG chunk')
        size = struct.unpack('>I', data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + size
        require(end <= len(data), 'PNG chunk exceeds file')
        payload = data[offset + 8:offset + 8 + size]
        crc = struct.unpack('>I', data[offset + 8 + size:end])[0]
        require(zlib.crc32(kind + payload) & 0xffffffff == crc, 'PNG CRC mismatch')
        if first:
            require(kind == b'IHDR' and size == 13, 'Invalid PNG header')
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            require((width, height, depth, color) == (1024, 1024, 8, 6), 'Master must be 1024x1024 RGBA, not a palette preview')
            require(compression == filtering == 0 and interlace in (0, 1), 'Invalid PNG encoding')
            first = False
        if kind == b'IDAT':
            idat.extend(payload)
        if kind == b'IEND':
            require(size == 0 and end == len(data), 'Unexpected bytes after PNG end')
            ended = True
        offset = end
    require(ended and len(idat) > 0, 'Incomplete PNG')
    decompressor = zlib.decompressobj()
    decompressor.decompress(bytes(idat))
    require(decompressor.eof and not decompressor.unused_data, 'Invalid compressed PNG data')


def verified_digest(data, expected, label):
    require(hashlib.sha256(data).hexdigest() == expected, label + ' differs from the approved asset manifest')


def validate_bundle(info, icon_data, manifest):
    require(info.get('CFBundleIdentifier') == 'com.kaizentrick.Oruvi', 'Bundle identity changed')
    require(info.get('CFBundleIconFile') == ICON, 'Info.plist references the wrong icon')
    require(not info.get('CFBundleIconName'), 'Unexpected asset-catalog override')
    validate_icns(icon_data)
    verified_digest(icon_data, manifest['icns_sha256'], 'Packaged icon')


def self_test(good, manifest, info):
    invalid = [b'', b'not-an-icon', good[1:], good[:-1], good + b'\0',
               good[:4] + struct.pack('>I', len(good) + 1) + good[8:],
               good[:12] + struct.pack('>I', 0) + good[16:],
               b'icns' + struct.pack('>I', 8)]
    for index, bad in enumerate(invalid):
        try:
            validate_icns(bad)
        except ValueError:
            continue
        raise ValueError('Corrupt icon fixture was accepted: ' + str(index))
    bad_info = dict(info, CFBundleIconFile='Oruvi.icns')
    try:
        validate_bundle(bad_info, good, manifest)
    except ValueError:
        pass
    else:
        raise ValueError('Legacy icon reference was accepted')
    changed = bytearray(good)
    changed[-1] ^= 1
    try:
        verified_digest(changed, manifest['icns_sha256'], 'Changed icon')
    except ValueError:
        pass
    else:
        raise ValueError('Changed artwork was accepted')
    print('Icon regression tests: 10 damaged/misreferenced fixtures rejected.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, help='Read-only verification of a built or mounted app')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    resources = ROOT / 'Resources'
    manifest = json.loads((resources / 'OruviIcon.json').read_text())
    require(manifest['source_file'] == 'OruviIcon.png' and manifest['icns_file'] == ICON, 'Unexpected manifest filenames')
    master = (resources / 'OruviIcon.png').read_bytes()
    icon = (resources / ICON).read_bytes()
    validate_png(master)
    validate_icns(icon)
    verified_digest(master, manifest['source_sha256'], 'Master PNG')
    verified_digest(icon, manifest['icns_sha256'], 'Source ICNS')
    info = plistlib.loads((resources / 'Info.plist').read_bytes())
    validate_bundle(info, icon, manifest)
    require(not (resources / 'Luma.icns').exists(), 'Corrupt legacy icon must not remain in the source tree')
    if args.self_test:
        self_test(icon, manifest, info)
    if args.app:
        contents = args.app / 'Contents'
        packaged_info = plistlib.loads((contents / 'Info.plist').read_bytes())
        packaged_icon = (contents / 'Resources' / ICON).read_bytes()
        validate_bundle(packaged_info, packaged_icon, manifest)
        require(packaged_icon == icon, 'Mounted installer contains different icon bytes')
        require((contents / 'Resources/OruviIcon.json').read_bytes() == (resources / 'OruviIcon.json').read_bytes(), 'Packaged manifest differs')
        require(packaged_info['CFBundleShortVersionString'] == info['CFBundleShortVersionString'], 'Wrong installer version')
        build = os.environ.get('ORUVI_BUILD_NUMBER')
        require(build is not None and packaged_info['CFBundleVersion'] == build, 'Wrong installer build')
        require(not (contents / 'Resources/Luma.icns').exists() and not (contents / 'Resources/Oruvi.icns').exists(), 'Stale legacy resources in installer')
        print('Packaged icon verified: version ' + packaged_info['CFBundleShortVersionString'] + ', build ' + build)
    print('Icon bytes verified: 1024px RGBA PNG; 10 native/Retina ICNS representations; SHA-256 ' + manifest['icns_sha256'])


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, struct.error, zlib.error) as error:
        print('ICON VALIDATION FAILED: ' + str(error), file=sys.stderr)
        sys.exit(1)
