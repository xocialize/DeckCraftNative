#!/bin/zsh
# Tools/l10n/commands.sh — regenerate DCAppModel's Commands.xcstrings from the registry (every engine command's
# label, keyed by id), the UI commands (UICommands.all) and the menu tree (MenuTree, keyed `menu.<Title>`).
# Re-run it when commands or menus change; StringsCatalogTests.commandsCatalogMatchesTheRegistry fails until
# you do. Translations of keys still present are kept; a removed key keeps its translations, marked stale.
set -euo pipefail
ROOT=${0:A:h:h:h}
SCRATCH=${SCRATCH:-$ROOT/.build-strings}
DC_L10N_WRITE=1 swift test --package-path "$ROOT" --scratch-path "$SCRATCH" \
    --filter 'StringsCatalogTests/commandsCatalogMatchesTheRegistry' 2>&1 | grep -E "error|✘|passed|failed" | head -20
python3 -I "$ROOT/Tools/l10n/l10n.py" stats "$ROOT/Packages/DCApp/Sources/DCAppModel/Resources/Commands.xcstrings"
