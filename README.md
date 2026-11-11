# Workspace Switcher

A GNOME-style Activities overview for [Omarchy](https://omarchy.org/). Tap Super and the current workspace shrinks into a row of workspaces with live window previews.

- The workspace zooms out from full screen and back in, window for window. The bar stays put and fades, or stays visible if you prefer.
- Left/Right, Tab, the scroll wheel, a touchpad swipe or a touchscreen swipe move between workspaces.
- Enter or a click goes to the selected workspace. Clicking a window focuses it.
- An empty workspace is always kept at the end to drop into.
- Start typing to search apps. Arrows move, Enter launches.
- Esc clears the search, then closes. Tapping Super again goes to the selected workspace.
- Colours follow the Omarchy theme.

## Requirements

Omarchy 4.5 or later (the Quickshell-based shell with Hyprland's Lua config).

## Install

```bash
omarchy plugin add https://github.com/janderssn/omarchy-workspace-switcher.git --enable
```

Then bind a key to it. For GNOME's "tap Super", add this to the end of `~/.config/hypr/bindings.lua`:

```lua
-- Tap Super on its own to open or close the overview. It fires on release,
-- so Super+key combinations keep working.
o.bind("SUPER + SUPER_L", "Workspace switcher", { panel = "janderssn.workspace-switcher" }, { release = true })
```

Any other key works the same way, for example `"SUPER + TAB"` without the `release` option.

To open it from a script:

```bash
omarchy-shell shell toggle janderssn.workspace-switcher '{}'
```

## Settings

Optional. Add an `[workspace-switcher]` section to `~/.config/omarchy/shell.toml`:

```toml
[workspace-switcher]
animate = "auto"   # "auto" follows `omarchy toggle animations`; "always" or "never" override it
dim = 0.5          # how much the wallpaper is darkened behind the workspaces, 0 to 1
bar = "fade"       # "fade" hides the bar while the overview is open; "keep" leaves it showing and usable
```

## Limits

- It shows the workspaces of the focused monitor. Setups with several monitors, rotated monitors and fractional scaling have had little testing.
- Named and special (scratchpad) workspaces are not shown.
- Windows cannot be dragged between workspaces.
- Right-to-left layouts are untested.

## Update and remove

```bash
omarchy plugin update janderssn.workspace-switcher
omarchy plugin remove janderssn.workspace-switcher
```

## Translations

Strings live in `i18n/<language>.json`, one file per Omarchy language code. A missing language falls back to English.

## Licence

MIT. See [LICENSE](LICENSE).
