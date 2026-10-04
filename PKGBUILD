# Maintainer: TJ Vanderpoel <tj@rubyists.com>
pkgname=sv-helper
pkgver=4.1.0 # x-release-please-version
pkgrel=1
pkgdesc="Helpers to make runit services easier to administer, as root or as a regular user"
arch=(any)
url="https://github.com/rubyists/sv-helper"
license=('MIT')
depends=('runit')
optdepends=(
  'runit-services: for a variety of pre-made services'
  'runit-run: to boot with runit as a pid 1 replacement'
)
source=("$pkgname-$pkgver.tar.gz::$url/releases/download/v$pkgver/$pkgname-linux.tar.gz")
# Refreshed per release from the release's own SHA256SUMS asset; see
# docs/releasing.md. `updpkgsums` does the same thing locally.
sha256sums=('SKIP')

package() {
  cd "$srcdir/$pkgname-$pkgver"
  # The same installer the release archive ships for everyone else, staged
  # into $pkgdir rather than installed live.
  ./install.sh install --destdir "$pkgdir" --prefix /usr
}
