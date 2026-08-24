# DefThis

Select it. DefThis.

DefThis is an Omarchy shell overlay that defines the currently selected word
without leaving the application you are using.

Definitions come from Wiktionary. Successful lookups are cached locally, so
previously looked-up words remain available offline.

## Requirements

- Omarchy Quattro
- `wl-clipboard` for reading the Wayland primary selection
- An internet connection for the first lookup of a word

The plugin runs inside the existing Omarchy shell process. It does not start a
second Quickshell instance or require elevated privileges.

## Install

```sh
omarchy plugin add https://github.com/cbullard/defthis.git --enable
```

## Add a shortcut

Add the following to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + D", "DefThis", "omarchy-shell shell summon io.github.cbullard.defthis '{}'")
```

Hyprland reloads the binding automatically. Change `SUPER + ALT + D` to any
unused combination if it conflicts with another shortcut.

## Usage

1. Select one word in any application that supports Wayland primary selection.
2. Press `Super+Alt+D`.
3. Press Escape or click outside the card to close it.

Press `O` while the overlay is open to view the full Wiktionary entry.

For development, a word can be supplied directly without changing the primary
selection:

```sh
omarchy-shell shell summon io.github.cbullard.defthis '{"term":"serendipity"}'
```

## Privacy and storage

The selected word is sent to Wiktionary only when it is not already cached.
Cached definitions are stored in `${XDG_CACHE_HOME:-~/.cache}/omarchy-defthis.json`.
Wiktionary responses are limited to 1 MiB. The persistent cache is limited to
100 entries and 1 MiB, with the oldest stored entries pruned first. An oversized
legacy cache is reset before it can be loaded into the shell process.
No clipboard watcher runs in the background; selection is read only when the
overlay is summoned.

Wiktionary text is available under the Creative Commons Attribution-ShareAlike
License. The plugin UI links every result back to its Wiktionary entry.

## Validate

```sh
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" DefThis.qml
env -u QT_QPA_PLATFORMTHEME QT_QPA_PLATFORM=offscreen \
  /usr/lib/qt6/bin/qmltestrunner -input tests
```

## Remove

Remove the shortcut line from `~/.config/hypr/bindings.lua`, then run:

```sh
omarchy plugin remove io.github.cbullard.defthis
```
