# Changelog

## [5.0.0](https://github.com/rubyists/sv-helper/compare/v4.0.0...v5.0.0) (2026-10-04)


### ⚠ BREAKING CHANGES

* sv-helper no longer prepends sudo when a directory is not writable. Managing another user's services is a deliberate act, so it now reports the problem and stops. Together with the user-scoped defaults above, a non-root invocation that previously escalated to manage /var/service now manages the user's own tree instead; set SVDIR and run as the owner to get the old target back.

### Features

* Add a standalone installer for scripts and command symlinks ([043a577](https://github.com/rubyists/sv-helper/commit/043a57712908787c1c3af0539c9f5631e2954626))
* Add runit stages 1, 2, and 3 for root containers ([043a577](https://github.com/rubyists/sv-helper/commit/043a57712908787c1c3af0539c9f5631e2954626))
* Publish signed packslip metadata for the release payload ([043a577](https://github.com/rubyists/sv-helper/commit/043a57712908787c1c3af0539c9f5631e2954626))
* Support regular-user services and logging on macOS and Linux ([#19](https://github.com/rubyists/sv-helper/issues/19)) ([25121ad](https://github.com/rubyists/sv-helper/commit/25121adf1ba3d30f251a8276d7d64b971b67a2c5))


### Bug Fixes

* Allows for expansion of DESTDIR (like for ~/*) ([#6](https://github.com/rubyists/sv-helper/issues/6)) ([397754f](https://github.com/rubyists/sv-helper/commit/397754f08725dc6399fc5e01528e594b5a200a46))
* Correct the permissions of ./main when it is a directory ([#8](https://github.com/rubyists/sv-helper/issues/8)) ([4741a16](https://github.com/rubyists/sv-helper/commit/4741a16897fd83e15ce331046c57d04002b0b0d5))
* Ensure we link ./current in the log directory, if it does not exist ([6a80847](https://github.com/rubyists/sv-helper/commit/6a808478c18f6e1fabc29bbfe64dc5a275b299f5))
* Moves /var/log logic back to where it belongs ([2d9845d](https://github.com/rubyists/sv-helper/commit/2d9845da07f29e0a2425e19b091b003931bb3352))


### Continuous Integration

* Automate Homebrew tap updates after verified releases ([043a577](https://github.com/rubyists/sv-helper/commit/043a57712908787c1c3af0539c9f5631e2954626))
* Set up release-please and publish versioned release assets ([043a577](https://github.com/rubyists/sv-helper/commit/043a57712908787c1c3af0539c9f5631e2954626))

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
