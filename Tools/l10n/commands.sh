#!/bin/zsh
# Tools/l10n/commands.sh — regenerate DCAppModel's Commands.xcstrings from the registry (every engine command's
# label, keyed by id), the UI commands (UICommands.all), the menu tree (MenuTree, keyed `menu.<Title>`) and the
# descriptions (CommandHelp, keyed `help.<id>`), and its Ribbon.xcstrings from the ribbon's layout (RibbonLayout:
# `ribbon.tab.<id>`, `ribbon.group.<tab>.<id>`, `ribbon.control.<id>`). Re-run it when commands, menus or the
# ribbon change; StringsCatalogTests.commandsCatalogMatchesTheRegistry and ribbonCatalogMatchesTheLayout fail until
# you do. Translations of keys still present are kept; a removed key keeps its translations, marked stale.
set -euo pipefail
ROOT=${0:A:h:h:h}
SCRATCH=${SCRATCH:-$ROOT/.build-strings}
DC_L10N_WRITE=1 swift test --package-path "$ROOT" --scratch-path "$SCRATCH" \
    --filter 'StringsCatalogTests/(commandsCatalogMatchesTheRegistry|ribbonCatalogMatchesTheLayout)' 2>&1 | grep -E "error|✘|passed|failed" | head -20
python3 -I "$ROOT/Tools/l10n/l10n.py" stats "$ROOT/Packages/DCApp/Sources/DCAppModel/Resources/Commands.xcstrings"
python3 -I "$ROOT/Tools/l10n/l10n.py" stats "$ROOT/Packages/DCApp/Sources/DCAppModel/Resources/Ribbon.xcstrings"
