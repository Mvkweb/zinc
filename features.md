# Features

A list of what zinc does.

## Visuals and layout

* **Cursor glide.** The cursor moves smoothly to its target cell instead of jumping instantly.
* **Cursor trails.** A brief fading trail follows the cursor when it moves quickly.
* **Cursor shapes.** Supports block, beam, and underline. Switches to a hollow wireframe box when the window loses focus.
* **Smooth scrolling.** The screen scrolls smoothly per pixel instead of jumping full lines at a time.
* **Auto-hiding scrollbar.** A thin scrollbar appears on the right edge while scrolling and fades away after a second of idle.
* **Window transparency.** Background opacity lets wallpaper or desktop blur show through, while text and colored blocks stay solid.
* **Adaptive padding.** Uses 25px padding in the shell, then drops to 0px in full-screen apps like Neovim, btop, and yazi so they reach the window edge.
* **Font zooming.** `Ctrl + '+'` and `Ctrl + '-'` (or `Ctrl + Mouse Wheel`) resize the font live.

## Clicks and interaction

* **Smart text selection.** Double-click selects words, file paths, or URLs across wrapped lines. Triple-click selects the full line.
* **Clickable links and paths.** `Ctrl + Click` opens URLs in your browser and files in your editor. `Ctrl + Click` on a folder runs `cd` into it. `Shift + Click` on a folder opens your file manager.
* **Mouse tracking.** Supports mouse events in apps like tmux and htop. Hold `Shift` to bypass tracking and select text directly.
* **In-terminal search.** Press `Ctrl + Shift + F` to search through the screen and scrollback history.
* **Vim copy mode.** Press `Ctrl + Shift + Space` to move around history with `hjkl`, start a selection with `v`, and copy with `y`.
* **IME support.** Input method preedit overlays work via Wayland `text-input-v3`.

## Terminal and rendering

* **Software rendering.** Draws straight to Wayland shared memory without needing GPU drivers or heavy UI toolkits.
* **Font fallbacks.** Auto-discovers fonts on your system with fallback for Nerd Font icons, CJK characters, and emoji.
* **Clean box drawing.** Box drawing characters and block elements align with zero pixel gaps between cells.
* **Underline styles and colors.** Supports curly, dotted, and dashed underlines, 24-bit TrueColor, and separate underline colors.
* **Keycap emoji.** Renders compound keycap symbols (like `1️⃣`) as a unit without splitting them across lines.

## Scrollback and reflow

* **Text reflow.** Resizing the window rewraps lines without breaking spacing, ASCII art, or shell prompts.
* **Low memory scrollback.** Allocates scrollback rows on demand so memory usage stays around 14MB even with a large history.
* **Prompt tracking.** Recognizes shell prompt markers (OSC 133) so resizing the window does not duplicate the prompt line.

## Images

* **Kitty graphics protocol.** Shows inline images in tools like yazi and ratatui apps (PNG, RGB, RGBA).
* **Sixel.** Basic Sixel image decoding.

## Configuration

* **Config file.** Settings live in `~/.config/zinc/config` with simple `key = value` lines. Zinc creates it on first launch.
* **Install and uninstall.** `zig build -Doptimize=ReleaseSafe --prefix ~/.local` installs it. `zig build uninstall --prefix ~/.local` removes it.
