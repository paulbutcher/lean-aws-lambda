# Changelog

## [0.4.0] - 2026-08-30

* A runtime API response whose `Content-Length` cannot be read is rejected rather than read to the end of the connection
* `ofHex?` carries a proof that a secret decodes to exactly half as many bytes as its hex text had characters
* The build treats warnings as errors, in both shipping packages and the test package

## [0.3.0] - 2026-08-20

Move to Lean's module system.

## [0.2.0] - 2026-08-20

Switch from `Lean.Data.Json` to the `lean-json` library.

## [0.1.0] - 2026-08-17

Initial release.
