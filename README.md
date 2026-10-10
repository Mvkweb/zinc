# zinc

A Wayland terminal emulator written in Zig.

<p align="center">
  <img src="assets/showcase.gif" alt="Zinc terminal showcase" />
</p>

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

System-wide (needs root):

```bash
sudo zig build install -Doptimize=ReleaseSafe --prefix /usr/local
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
