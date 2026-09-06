#!/bin/bash
# Run in your own Terminal with GitHub CLI authenticated. No token is ever printed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
command -v gh >/dev/null || { echo 'Instala GitHub CLI y ejecuta gh auth login.' >&2; exit 1; }
LOGIN="$(gh api user --jq .login)" || { echo 'Autoriza GitHub desde Terminal: gh auth login' >&2; exit 1; }
USER_ID="$(gh api user --jq .id)"
TARGET="${1:-$LOGIN/oruvi}"
[[ "$TARGET" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$ && "$TARGET" != */.. && "$TARGET" != */. ]] || { echo 'Usa propietario/repositorio.'; exit 1; }
if gh repo view "$TARGET" --json nameWithOwner >/dev/null 2>&1; then
    echo "El repositorio $TARGET ya existe. Este script solo crea uno NUEVO; elige otro nombre." >&2; exit 1
fi
[[ -s .private/sparkle.key ]] || { echo 'Falta la clave privada local de actualizaciones. No se publicará una clave distinta.' >&2; exit 1; }
xcrun swift scripts/update-key.swift
python3 scripts/audit-source.py
if git rev-parse --show-toplevel >/dev/null 2>&1; then
    [[ "$(git rev-parse --show-toplevel)" == "$ROOT" ]] || { echo 'La carpeta pertenece a otro repositorio.'; exit 1; }
else
    git init -b main
fi
if git remote get-url origin >/dev/null 2>&1; then echo 'Ya hay un origin configurado; se requiere revisión manual para evitar sobrescribirlo.'; exit 1; fi
git add .gitignore README.md CHANGELOG.md SECURITY.md THIRD_PARTY_NOTICES.md Sources Resources scripts .github
python3 scripts/audit-source.py --staged
if ! git diff --cached --quiet; then
    git -c "user.name=$LOGIN" -c "user.email=$USER_ID+$LOGIN@users.noreply.github.com" commit -m 'Oruvi: native player, smooth lyrics and signed release updates'
fi
# Public creation is explicit. Only the allowlisted source is pushed; dist and .private stay local.
gh repo create "$TARGET" --public --source . --remote origin --description 'Oruvi: reloj, música y ambiente nativos para macOS'
# Grant the main-branch release workflow access to THIS newly-created signing seed.
# stdin avoids exposing the seed in arguments or logs; pull requests never receive this secret.
gh secret set ORUVI_SPARKLE_PRIVATE_KEY --repo "$TARGET" < .private/sparkle.key
git push -u origin main
printf '\nRepositorio creado y código subido:\n'
gh repo view "$TARGET" --json url,isPrivate --jq 'if .isPrivate then error("No es público") else .url end'
printf '\nLa primera compilación se publica mediante Actions. Consulta su estado:\n'
printf 'gh run list --repo %s\n' "$TARGET"
printf '\nEn Oruvi > Ajustes > Actualizaciones, guarda %s. La clave pública ya coincide con esta instalación.\n' "$TARGET"
