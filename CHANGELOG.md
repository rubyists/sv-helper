# Changelog

## [5.0.0](https://github.com/rubyists/sv-helper/compare/v4.3.0...v5.0.0) (2026-10-06)


### ⚠ BREAKING CHANGES

* `./install.sh install-stages`, `./install.sh uninstall-stages` and `--runit-dir` are gone. Install sv-helper, then run `sv-helper install-stages`; the old commands say so and change nothing.

### Features

* Install the runit stages from sv-helper, on stage 2's own tree ([#44](https://github.com/rubyists/sv-helper/issues/44)) ([37c0bbb](https://github.com/rubyists/sv-helper/commit/37c0bbb101dc053f91e527c167607e530d7c6351))

## [4.3.0](https://github.com/rubyists/sv-helper/compare/v4.2.1...v4.3.0) (2026-10-06)


### Features

* Add a curl | bash bootstrap installer ([#40](https://github.com/rubyists/sv-helper/issues/40)) ([f45a625](https://github.com/rubyists/sv-helper/commit/f45a625fccc997de3a2180ede629b1165e2751a3)), closes [#39](https://github.com/rubyists/sv-helper/issues/39)


### Documentation

* Author the readmes in AsciiDoc ([#41](https://github.com/rubyists/sv-helper/issues/41)) ([7960aee](https://github.com/rubyists/sv-helper/commit/7960aeee36f429153361109ccc49793607c26e83))

## [4.2.1](https://github.com/rubyists/sv-helper/compare/v4.2.0...v4.2.1) (2026-10-05)


### Bug Fixes

* Explain, rather than pass through, a service runsv will not discuss ([#37](https://github.com/rubyists/sv-helper/issues/37)) ([01a47c2](https://github.com/rubyists/sv-helper/commit/01a47c23837f96643b97304c5d5bd63cb707844b)), closes [#1](https://github.com/rubyists/sv-helper/issues/1)

## [4.2.0](https://github.com/rubyists/sv-helper/compare/v4.1.0...v4.2.0) (2026-10-04)


### Features

* Add --version to every command ([#35](https://github.com/rubyists/sv-helper/issues/35)) ([3a46b60](https://github.com/rubyists/sv-helper/commit/3a46b60f54630ab4954c015bd9fb62399d8117a0))

## [4.1.0](https://github.com/rubyists/sv-helper/compare/v4.0.1...v4.1.0) (2026-10-04)


### Features

* Run the container lifecycle as a regular user ([#31](https://github.com/rubyists/sv-helper/issues/31)) ([32d0dcd](https://github.com/rubyists/sv-helper/commit/32d0dcddd3e5d93b1243e09de47c71ce9e5ce257)), closes [#17](https://github.com/rubyists/sv-helper/issues/17)

## [4.0.1](https://github.com/rubyists/sv-helper/compare/v4.0.0...v4.0.1) (2026-10-04)


### Continuous Integration

* Tag draft releases as release-please creates them ([#29](https://github.com/rubyists/sv-helper/issues/29)) ([83e6874](https://github.com/rubyists/sv-helper/commit/83e6874a2c58dcd6974f480490425a62cba4b767))

## [4.0.0](https://github.com/rubyists/sv-helper/compare/v3.5.0...v4.0.0) (2026-10-04)


### ⚠ BREAKING CHANGES

* sv-helper no longer prepends sudo when a directory is not writable. Managing another user's services is a deliberate act, so it now reports the problem and stops. Together with the user-scoped defaults above, a non-root invocation that previously escalated to manage /var/service now manages the user's own tree instead; set SVDIR and run as the owner to get the old target back.

### Features

* Add a standalone installer for scripts and command symlinks ([043a577](https://github.com/rubyists/sv-helper/commit/043a57712908787c1c3af0539c9f5631e2954626))
* Add runit stages 1, 2, and 3 for root containers ([043a577](https://github.com/rubyists/sv-helper/commit/043a57712908787c1c3af0539c9f5631e2954626))
* Publish signed packslip metadata for the release payload ([043a577](https://github.com/rubyists/sv-helper/commit/043a57712908787c1c3af0539c9f5631e2954626))
* Support regular-user services and logging on macOS and Linux ([#19](https://github.com/rubyists/sv-helper/issues/19)) ([25121ad](https://github.com/rubyists/sv-helper/commit/25121adf1ba3d30f251a8276d7d64b971b67a2c5))


### Continuous Integration

* Automate Homebrew tap updates after verified releases ([043a577](https://github.com/rubyists/sv-helper/commit/043a57712908787c1c3af0539c9f5631e2954626))
* Set up release-please and publish versioned release assets ([043a577](https://github.com/rubyists/sv-helper/commit/043a57712908787c1c3af0539c9f5631e2954626))

## Changelog
