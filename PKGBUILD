# Maintainer: Mvkweb <https://github.com/Mvkweb>
# Local build while AUR submissions are closed: makepkg -si
# NOTE: upstream is private for now, so plain `git clone` needs auth.
# TODO(release): add a LICENSE file; then license=('MIT') (or actual).
pkgname=zinc
pkgver=0.1.0
pkgrel=1
pkgdesc="A terminal written in Zig"
arch=('x86_64' 'aarch64')
url="https://github.com/Mvkweb/zinc"
license=('custom')
depends=('wayland' 'libxkbcommon' 'freetype2' 'fontconfig')
makedepends=('git' 'zig' 'pkgconf')
# Requires Zig 0.16.0 (see build.zig.zon minimum_zig_version).
source=("git+$url.git#tag=v$pkgver")
sha256sums=('SKIP')

build() {
  cd "$pkgname"
  zig build \
    -Doptimize=ReleaseSafe \
    -Dversion="$pkgver" \
    --prefix "$pkgdir/usr"
}

# No separate package(): `zig build --prefix` already lays out
# bin/ + share/{applications,icons,metainfo} under $pkgdir/usr.
