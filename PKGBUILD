# Maintainer: Mvkweb <https://github.com/Mvkweb>
# Local build while AUR submissions are closed: makepkg -si
# NOTE: upstream is private for now, so plain `git clone` needs auth.
# NOTE: needs release tag v$pkgver to exist; none exist yet.
pkgname=zinc
pkgver=0.1.0
pkgrel=1
pkgdesc="A terminal written in Zig"
arch=('x86_64' 'aarch64')
url="https://github.com/Mvkweb/zinc"
license=('MIT')
depends=('wayland' 'libxkbcommon' 'freetype2' 'fontconfig')
makedepends=('git' 'zig>=0.16' 'zig<0.17' 'pkgconf')
# Requires Zig 0.16.x (see build.zig.zon minimum_zig_version).
source=("git+$url.git#tag=v$pkgver")
sha256sums=('SKIP')

build() {
  cd "$pkgname"
  # Baseline CPU so the package runs anywhere, not just the build host.
  # Staging prefix: package() copies the tree into $pkgdir.
  zig build \
    -Doptimize=ReleaseSafe \
    -Dcpu=baseline \
    -Dversion="$pkgver" \
    --prefix "$srcdir/stage"
}

package() {
  cp -a "$srcdir/stage/." "$pkgdir/usr/"
  install -Dm644 "$srcdir/$pkgname/LICENSE" "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
