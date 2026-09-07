#!/usr/bin/env python3
"""Fail closed before uploading source to a PUBLIC repository. Prints filenames, never secrets."""
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
allowed_dirs = {"Sources", "Resources", "scripts", ".github"}
allowed_root = {".gitignore", "README.md", "CHANGELOG.md", "SECURITY.md", "THIRD_PARTY_NOTICES.md", "LICENSE"}
forbidden_suffixes = {".key", ".pem", ".p12", ".pfx", ".ttf", ".otf", ".ttc", ".lrc", ".dmg", ".zip", ".log"}
patterns = [re.compile(rb"gh[pousr]_[A-Za-z0-9]{20,}"), re.compile(rb"github_pat_[A-Za-z0-9_]{30,}"),
            re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
            re.compile(rb"/Users/[A-Za-z][A-Za-z0-9_-]+/")]
staged = "--staged" in sys.argv
if staged:
    names = subprocess.check_output(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"], cwd=root).decode().split("\0")
    paths = [pathlib.PurePosixPath(n) for n in names if n]
else:
    paths = [p.relative_to(root) for d in allowed_dirs if (root / d).exists() for p in (root / d).rglob("*") if p.is_file()]
    paths += [pathlib.Path(n) for n in allowed_root if (root / n).is_file()]
    paths = [p for p in paths if str(p) != "Sources/LumaQA.swift"]
seed = root / ".private/sparkle.key"
secret = seed.read_bytes().strip() if seed.is_file() else b""
errors = []
for rel in paths:
    path = root / rel
    if (rel.parts[0] not in allowed_dirs and str(rel) not in allowed_root) or rel.suffix.lower() in forbidden_suffixes or path.is_symlink() or rel.name.startswith(".env"):
        errors.append(str(rel)); continue
    if rel.suffix == ".icns":
        if str(rel) != "Resources/Luma.icns": errors.append(str(rel))
        continue
    data = subprocess.check_output(["git", "show", ":" + str(rel)], cwd=root) if staged else path.read_bytes()
    if any(p.search(data) for p in patterns) or (secret and secret in data): errors.append(str(rel))
if errors:
    print("Public-source audit blocked these files:\n" + "\n".join(sorted(set(errors))), file=sys.stderr)
    sys.exit(1)
print(f"Public-source audit passed: {len(paths)} files; no private key, credentials, personal paths or font binaries detected.")
