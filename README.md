# DefThis

Select it—or place the text cursor inside it. DefThis.

DefThis is an Omarchy shell overlay that defines the word selected in the
focused text control, or the word containing its text cursor, without leaving
the application you are using.

Definitions come from Wiktionary. Successful lookups are cached locally, so
previously looked-up words remain available offline and can be revisited from
the Recent words view.
When Wiktionary identifies a noun as a plural form, DefThis follows that entry
and displays the definition of its singular form instead.

## Requirements

- Omarchy Quattro
- Python 3.10 or newer
- AT-SPI and PyGObject for best-effort accessible-text lookup (included with
  Omarchy)
- `wl-clipboard` for reading the Wayland primary selection
- An internet connection for the first lookup of a word

The plugin runs inside the existing Omarchy shell process. It does not start a
second Quickshell instance or require elevated privileges.

## Install

```sh
omarchy plugin add https://github.com/cbullard/defthis.git --enable
```

## Add a shortcut

DefThis installs its small `omarchy-defthis` shortcut command into
`~/.local/bin/` when the plugin first loads. Add either or both bindings to
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + D", "DefThis selection", "omarchy-defthis selection")
o.bind("ALT + SHIFT + D", "DefThis at cursor", "omarchy-defthis cursor")
```

Hyprland reloads the bindings automatically. The shortcut text is entirely
user-configurable; change either combination to any unused binding. Check
existing bindings with `omarchy menu keybindings --print`.

## Usage

1. Select one word and press `Super+Alt+D`, or place the text cursor inside a
   word and press `Alt+Shift+D`.
2. The cursor shortcut selects the word using the focused application's normal
   word-navigation behavior before opening DefThis.
3. Press `H` while DefThis is open to toggle Recent words.
4. Press Space while DefThis is open to type a word directly; Enter looks it up
   and Escape cancels the input.
5. Press Escape or click outside the card to close it.

The cursor shortcut sends `Ctrl+Right`, followed by `Ctrl+Shift+Left`, to the
focused application and then reads its Wayland primary selection. Word
boundaries therefore follow the application's own editing behavior. Directly
summoning the overlay without a shortcut mode retains best-effort AT-SPI lookup
and falls back to the primary selection.

Press `O` while the overlay is open to view the full Wiktionary entry.

In Recent words, use the arrow keys to move and Enter to reopen a definition.
Press Delete to remove the selected word and its cached definition. The Clear
button removes all saved words and definitions after confirmation.

For development, a word can be supplied directly without changing the primary
selection:

```sh
omarchy-shell shell summon io.github.cbullard.defthis '{"term":"serendipity"}'
```

## Privacy and storage

Lookup terms are sent to Wiktionary only when a needed definition is not
already cached. Recent definitions and plural-to-singular aliases are stored in
`${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-defthis.json`, along with a
most-recent-first list of up to 50 words without timestamps. The singular
resolver uses the inspectable Python helper and its separate bounded cache at
`${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-defthis/cache.json`; its Wiktionary
responses are limited to 1 MiB, and its cache is limited to 100 entries and
1 MiB with atomic, owner-only updates.
Focused accessible text is inspected only when the overlay is summoned, with
both the traversal and its runtime bounded. The primary selection fallback is
also read through the helper with a 1 KiB limit. No clipboard or accessibility
watcher runs in the background. Saved lookup data can be removed from Recent
words.

Wiktionary text is available under the Creative Commons Attribution-ShareAlike
License. The plugin UI links every result back to its Wiktionary entry.

## Validate

```sh
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" DefThis.qml
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
env -u QT_QPA_PLATFORMTHEME QT_QPA_PLATFORM=offscreen \
  /usr/lib/qt6/bin/qmltestrunner -input tests
```

## Remove

Remove the shortcut lines from `~/.config/hypr/bindings.lua`, then run:

```sh
omarchy plugin remove io.github.cbullard.defthis
rm ~/.local/bin/omarchy-defthis
```
