# Maintainer: TJ Vanderpoel <tj@rubyists.com>
pkgname=sv-helper
pkgver=1.0.1
pkgrel=1
pkgdesc="Helpers to make using runit-run, runit-services and runit-dietlibc easier to use"
arch=(i686 x86_64)
url="http://github.com/rubyists/sv-helper"
license=('MIT')
# depends=('runit-dietlibc') # no reference
optdepends=('runit-services: for a variety of pre-made services' 'runit-run: to boot with runit as a pid 1 replacement')
source=(sv-helper.sh rsvlog.sh README.md)
md5sums=('68d480d34e1d579e52cf28ecd90b1604'
         'cd9c83fa9f70a9a045fb48ed10be0d08'
         'e556ab944360485a1fcfb44c5309d67f')

package() {
  install -D -m 0755 {sv-helper.sh,rsvlog.sh} -t "$pkgdir/usr/bin/"
  install -D -m 0644 README.md "$pkgdir/usr/share/doc/sv-helper/README.md"
  cd "$pkgdir/usr/bin"
  for sv in sv-start sv-stop sv-restart sv-list svls sv-enable sv-disable sv-find ; do
    ln -s sv-helper $sv
  done
  ln -s rsvlog.sh rsvlog
}
