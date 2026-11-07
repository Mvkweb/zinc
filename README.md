# zinc

A Wayland terminal emulator written in Zig.

<p align="center">
  <img src="assets/showcase.gif" alt="Showcase" />
</p>

Keep in mind this is still experimental and you will surely find issues. If you report them in the issues I would really appreciate it and will work on the fix. I am doing this project to learn, not competing with other terminals, although zinc is faster in some tasks and has niche features.

## Highlights

- **Smooth motion**: configurable cursor glide and scrolling.
- **Kitty graphics**: inline image previews for `yazi`, `chafa`, etc.
- **Adaptive TUI padding**: pads your shell, but drops to 0px edge-to-edge in full-screen apps (`nvim`, `btop`, `yazi`).
- **Smart click**: `Ctrl+click` files to open in your editor, `Ctrl+click` folders to `cd`.
- **Lightweight**: memory footprint stays around ~23MB in a maximized window.

Full breakdown in [features.md](features.md).

<details>
<summary><b>Default configuration (<code>~/.config/zinc/config</code>)</b></summary>

```ini
# Zinc configuration
# Changes take effect when you open a new window.
# When new settings ship, Zinc writes an updated reference file to
# config.new next to this file without changing your config.
config-version = 6

# Shell
# Command or binary to run, such as "fish" or "/bin/zsh".
# Leave empty to read your login shell from /etc/passwd.
shell = ""
# Run the shell as a login shell by prepending "-" to argv[0].
login-shell = false

# Window size in character cells (for floating windows; tiling compositors override this)
# Both Ghostty-style and Foot-style formats are supported:
# window-width = 80
# window-height = 24
# Or combined (columns x rows):
# window-size = 80x24

# Fonts
# Font family name or TTF path. Leave empty to use system Nerd Fonts.
font-family = ""
font-size = 12.0

# Padding in pixels
# Normal window padding.
padding-x = 25
padding-y = 25
# Fullscreen and alt-screen padding for terminal apps like Neovim and btop.
alt-padding-x = 0
alt-padding-y = 0

# Window decorations
# Options: auto, none, csd, server.
# auto uses server decorations on KDE and Sway, and client decorations on GNOME.
decorations = auto

# Colors (hex format: #RRGGBB)
background = #0b0f11
foreground = #dcdccc
selection-background = #dcdccc
selection-foreground = #0b0f11
cursor-color = #dcdccc
link-color = #8cd0d3

# Background opacity from 0.0 (transparent) to 1.0 (opaque).
background-opacity = 0.78

# Cursor
# Shape options: bar, block, underline.
cursor-style = bar
cursor-blink = true
cursor-thickness = 1.5

# Animation
# Glide the cursor smoothly to new positions instead of jumping.
cursor-glide = true
cursor-glide-ms = 60
# Overshoot bounce past target cell: 0.0 is smooth glide with no bounce, 1.0 is full bounce.
cursor-overshoot = 1.0
# Afterimage trail duration in milliseconds. 0 disables the trail.
cursor-trail-ms = 0
# Smooth scroll animation for scrollback jumps.
smooth-scroll = true
smooth-scroll-ms = 110
# Rows scrolled per mouse wheel tick (1 to 100).
scroll-step = 5

# Selection
# Set to true to show a 1-cell highlight on a single click before dragging.
selection-single-cell = false

# Search bar (Ctrl+Shift+F)
# Show match index numbers on screen.
find-match-numbers = false
# Badge digit scale: 1 is small, 2 is medium, 3 is large.
find-number-scale = 2

# File and directory clicks
# Command for opening file paths on Ctrl+click.
# Leave empty to use $EDITOR, then xdg-open.
# Supports {file}, {line}, and {col} substitutions.
# Examples:
# editor-command = "code --goto {file}:{line}:{col}"
# editor-command = "zed {file}:{line}:{col}"
editor-command = ""
# In-terminal editor command executed directly inside the current shell session.
# Examples:
# editor-command-terminal = "nvim +{line} {file}"
# editor-command-terminal = "nano +{line} {file}"
editor-command-terminal = ""
# Modifiers for clicking directories: ctrl, shift, ctrl+shift, or off.
# dir-cd-mod changes directory in the current shell.
dir-cd-mod = ctrl
# dir-open-mod opens the directory in your graphical file manager.
dir-open-mod = shift
# Run ls automatically after changing directory with a gesture.
dir-cd-ls = true
```

</details>


## Dependencies

- Zig 0.17.0
- wayland-client
- libxkbcommon
- freetype2
- fontconfig
- hicolor-icon-theme

On Arch:

```bash
sudo pacman -S zig wayland libxkbcommon freetype2 fontconfig hicolor-icon-theme
```

Note: built with Zig 0.17.0.

## Build

Build the release binary:

```bash
zig build -Doptimize=ReleaseSafe
```

Run the binary:

```bash
./zig-out/bin/zinc
```

To compile-check without installing or running anything:

```bash
zig build check
```

## Install

### Arch Linux

Available on the AUR as [`zinc-term`](https://aur.archlinux.org/packages/zinc-term) (release) or [`zinc-term-git`](https://aur.archlinux.org/packages/zinc-term-git) (git):

```bash
paru -S zinc-term
# or
yay -S zinc-term
```

For the latest git master:

```bash
paru -S zinc-term-git
# or
yay -S zinc-term-git
```

### From source

To install for your user only (no root required):

```bash
zig build -Doptimize=ReleaseSafe --prefix ~/.local
update-desktop-database ~/.local/share/applications
```

This installs the binary to `~/.local/bin/zinc` and registers the desktop launcher, multi-res transparent icons, and AppStream metadata in `~/.local/share/`.

Make sure `~/.local/bin` is in your `PATH`:
- **fish**: `fish_add_path ~/.local/bin`
- **bash / zsh**: add `export PATH="$HOME/.local/bin:$PATH"` to your `~/.bashrc` or `~/.zshrc`

For system-wide installation:

```bash
sudo zig build -Doptimize=ReleaseSafe --prefix /usr/local
sudo update-desktop-database /usr/local/share/applications
```

## Uninstall

To uninstall, run the built-in uninstall command pointing to your prefix:

```bash
zig build uninstall -Duninstall-prefix=$HOME/.local
update-desktop-database ~/.local/share/applications
```

Or for system-wide installs:

```bash
sudo zig build uninstall -Duninstall-prefix=/usr/local
sudo update-desktop-database /usr/local/share/applications
```

Your configuration at `~/.config/zinc/config` stays untouched.
