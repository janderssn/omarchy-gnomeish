# Changelog

## 0.9.0

First packaged release.

- The current workspace zooms out of the desktop into its card and back, with no flash on open.
- The bar fades in place instead of shrinking with the workspace.
- Window borders fade out as the workspace shrinks, so the first and last frames match the desktop.
- The backdrop is the wallpaper, darkened; the amount is the `dim` setting.
- The `bar` setting keeps the bar visible and usable instead of fading it.
- A card is a miniature of the work area, without the bar's strip, so the gaps around its windows are even.
- The wallpaper darkens and blurs a little, slowly, as the overview opens; the `blur` setting sets the amount.
- App search: results that start with what you typed come first, rows are centred, names wrap to two lines, the selection has an accent outline, the backdrop darkens further, and the search field has a magnifier and a caret.
- Workspaces and search results crossfade.
- Colours follow the theme.
- Animations follow `omarchy toggle animations`; the `animate` setting overrides it.
- The spare workspace never takes an id used on another monitor.
- Output of helper processes is capped, commands are run without a shell, and only integer workspace ids and hex window addresses reach Hyprland.
- Translations: Danish, Dutch, Finnish, French, German, Italian, Norwegian, Polish, Portuguese, Brazilian Portuguese, Spanish and Swedish.
