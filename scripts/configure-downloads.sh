#!/bin/bash
# Run in the maintainer's Terminal. Uses their normal gh session, never reads tokens.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
REPO="${ORUVI_REPOSITORY:-kaizentrick/oruvi}"
[[ "$REPO" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$ ]]
command -v gh >/dev/null || { echo 'Instala GitHub CLI y ejecuta gh auth login.'; exit 1; }
gh auth status --hostname github.com
ORIGIN="$(git remote get-url origin)"
case "$ORIGIN" in
  "https://github.com/$REPO"|"https://github.com/$REPO.git"|"git@github.com:$REPO.git") ;;
  *) echo 'El remoto no coincide con el repositorio seleccionado. No se publica.'; exit 1;;
esac
[[ "$(git branch --show-current)" == main ]] || { echo 'Cambia a main antes de publicar.'; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'Hay cambios sin commit. Revísalos y crea un commit antes de publicar.'; exit 1; }
[[ "$(gh repo view "$REPO" --json isPrivate --jq .isPrivate)" == false ]] || { echo 'El repositorio no es público; no se cambiará su visibilidad automáticamente.'; exit 1; }
gh secret list --repo "$REPO" --json name --jq '.[].name' | grep -qx ORUVI_SPARKLE_PRIVATE_KEY || {
  echo 'Falta ORUVI_SPARKLE_PRIVATE_KEY. Configura el secreto de firma sin publicarlo en el repositorio.'; exit 1;
}
python3 scripts/audit-source.py
# Configure the repository landing area, not global gh settings or another repository.
gh repo edit "$REPO" \
    --description 'Oruvi: native macOS notch companion and full-screen Standby for Apple Music and Spotify.' \
    --homepage "https://github.com/$REPO/releases/latest" \
    --add-topic macos --add-topic swiftui --add-topic notch --add-topic apple-music --add-topic spotify --add-topic standby
# Ask gh's credential helper only for this push, without changing global git configuration.
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin HEAD:main
SHA="$(git rev-parse HEAD)"
RUN=""
for attempt in {1..12}; do
  RUN="$(gh run list --repo "$REPO" --workflow release.yml --branch main --commit "$SHA" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
  [[ -z "$RUN" ]] || break
  sleep 5
done
if [[ -z "$RUN" ]]; then
  echo 'El código está subido. Ejecuta el workflow Build and publish Oruvi desde Actions para publicar la release.'
  exit 0
fi
gh run watch "$RUN" --repo "$REPO" --exit-status
URL="https://github.com/$REPO/releases/latest/download/Oruvi.dmg"
curl --fail --location --head --max-time 30 --silent --show-error "$URL" >/dev/null
printf '\nDescarga pública verificada: %s\n' "$URL"
printf 'Release: https://github.com/%s/releases/latest\n' "$REPO"
