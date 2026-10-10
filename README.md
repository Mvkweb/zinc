# zinc

A Wayland terminal emulator written in Zig.

<p align="center">
  <img src="assets/showcase.gif" alt="Showcase" />
</p>

Keep in mind this is still experimental and you will surely find issues. If you report them in the issues I would really appreciate it and will work on the fix. I am doing this project to learn, not competing with other terminals, although zinc is faster in some tasks and has niche features.

## Highlights

The cursor glides to its cell over 60ms instead of teleporting. Scrolling pours instead of jumping, with a scrollbar that fades when idle. Ctrl+click a file to open it in your editor, Ctrl+click a folder to cd into it, Shift+click to open the file manager. Images render inline through the Kitty graphics protocol, so tools like yazi show real previews. Fonts auto-discover with CJK and emoji fallback, and Ctrl+plus/minus zooms.

Everything lives in `~/.config/zinc/config`, created on first launch and never rewritten. Tune `cursor-glide-ms`, `smooth-scroll-ms`, or `scroll-step` and restart.

## Dependencies

- Zig 0.16.0
- wayland-client
- libxkbcommon
- freetype2
- fontconfig

On Arch:

```bash
sudo pacman -S zig wayland libxkbcommon freetype2 fontconfig
```

Note: built with Zig 0.16.0.

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

`zig build install` lays out the binary plus the launcher files
(desktop entry, icon, app metadata). It installs relative to a prefix,
so pick where it goes.

For your user only, no root needed:

```bash
zig build install -Doptimize=ReleaseSafe --prefix ~/.local
```

This puts the binary in `~/.local/bin` and the desktop files under
`~/.local/share`. Make sure `~/.local/bin` is on your PATH. Your app
launcher should list Zinc after that. If it does not show up right away,
most launchers pick it up on next login.

System-wide (needs root). Build as yourself first, otherwise the build
cache in your repo ends up owned by root:

```bash
zig build -Doptimize=ReleaseSafe --prefix ./stage
sudo cp -a stage/. /usr/local/
```

On Arch, you can also build a proper package from the repo:

```bash
makepkg -si
```

This needs a release tag to exist (it builds `v$pkgver`). AUR submission
will follow once registrations reopen.

To uninstall, delete what the prefix install placed:

```bash
rm ~/.local/bin/zinc
rm ~/.local/share/applications/io.github.mvkweb.zinc.desktop
rm ~/.local/share/metainfo/io.github.mvkweb.zinc.metainfo.xml
rm -rf ~/.local/share/icons/hicolor/*/apps/zinc.png
rm ~/.local/share/pixmaps/zinc.png
```

Your config at `~/.config/zinc/config` stays put. Zinc creates it on
first launch if it is missing.

## Known issues

- Hard resizes can strand one stray character. Content restores fine.
  Cause unknown, see `src/term/reflow.zig`.
