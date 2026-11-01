# Localization

DeckCraftNative's interface is written in English. French, Italian, German and Spanish are **preview translations**.
They were drafted with AI from the English text and a glossary of Microsoft PowerPoint's terms in each language. No
native speaker has reviewed them yet. The app ships them as they are: a string that reads oddly is a known risk
until someone reviews it, and any string with no translation shows in English.

| Language | Code | State | Review sheet |
|---|---|---|---|
| English | `en` | source | — |
| French | `fr` | preview, needs review | [review/fr.csv](review/fr.csv) |
| Italian | `it` | preview, needs review | [review/it.csv](review/it.csv) |
| German | `de` | preview, needs review | [review/de.csv](review/de.csv) |
| Spanish | `es` | preview, needs review | [review/es.csv](review/es.csv) |

Volunteers are welcome. The tracking issue is
[#1, Review the French, Italian, German and Spanish translations](https://github.com/xocialize/DeckCraftNative/issues/1).

## Reviewing a language (no Xcode needed)

1. **Open the sheet.** Open your language's sheet in `review/` in a spreadsheet app: Numbers, Excel, LibreOffice
   Calc or Google Sheets. It is UTF-8 CSV; choose UTF-8 if the app asks. Each row is one piece of text:
   - `id`: which catalog and key. Don't change it.
   - `form`: for text that changes with a number: `one` (singular) or `other` (plural); `value` for the sentence
     around them; `phrases` for Siri and Shortcuts phrases, one per line.
   - `english` / `translation`: the source text and the draft.
   - `state`: `needs_review` (a draft) or `translated` (reviewed).
   - `reviewed`: put an `x` when the translation is right. Leave it empty if you haven't checked the row.
   - `note`: anything you want the maintainers to know.
   - `comment`: where the text appears in the app, written for translators.
2. **Fix what reads wrong** in `translation`. Keep these exactly as they are:
   - the placeholders: `%@`, `%lld`, `%1$@`, `%%`, `%#@slides@`, `%arg`, `${applicationName}`;
   - keyboard symbols (⌘ ⇧ ⌥) and the trailing `…`.
   A placeholder stands for a name or a number the app fills in. Placeholders may move within the sentence. If two
   change order, number them (`%1$@ … %2$lld`).
3. **Use PowerPoint's words.** Ribbon tabs, groups and commands should use the names Microsoft PowerPoint uses in
   your language, so PowerPoint users find what they expect. The shared terms are in
   [`Tools/l10n/glossary.json`](../../Tools/l10n/glossary.json). If a glossary term is wrong, say so in the issue:
   changing it changes it everywhere.
4. **Send it back.** Either open a pull request that changes the sheet, or attach the saved CSV to the issue. Partial
   reviews help: a whole area at a time works well. For example, the ribbon is every row whose id starts with
   `Ribbon|`, and the command names start with `Commands|`. Rows marked `x` become "translated" when they are merged.

## For maintainers

- **Tooling.** [`Tools/l10n/translations.py`](../../Tools/l10n/translations.py) moves text between the String
  Catalogs and these sheets. It refuses any translation that loses or changes a format argument, and
  `TranslationsTests` checks the same in the test suite.
  - `review-import LANG review/LANG.csv` applies a reviewed sheet: rows marked `x` become "translated", and edited
    rows stay "needs review".
  - `review-export LANG review/LANG.csv` rewrites the sheet from the catalogs. Run it after every import, and after
    `Tools/l10n/sync.sh` or `commands.sh` adds or changes English text.
  - `check LANG` counts each language's entries by state and re-checks their arguments.
- **New English strings.** Run `export LANG DIR` for each language. It writes the entries that language lacks, with
  their comments. Translate them into `{"id", "t"}` files, run `validate` on them, then `import LANG FILES…` (they
  arrive as "needs review").
- **What stays in English in every language:**
  - text the engine produces, which must match DeckCraft's replies byte for byte:
    - the placeholder prompts on new slides ("Click to add title");
    - default names such as "Presentation1";
    - command errors and the accessibility checker's findings;
    - some preset and chart names.
  - the control channel, `dccli` and MCP output;
  - what's inside presentations.
