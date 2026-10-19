# Pinned peer TLS sources

The standalone `Packages/TractandaPeerTLS` package vendors the production sources of Apple's SwiftNIO SSL at revision `15e0b9e495786807272dd4891fa4bac76aa43034` (https://github.com/apple/swift-nio-ssl), including its BoringSSL snapshot `8eb25be6fa18d475291122887a7bccd3762ff236`.

`LICENSE.txt` and `NOTICE.txt` here are exact upstream files. All component license/copyright headers remain in the tracked vendored sources, including BoringSSL and its third-party code. The upstream NOTICE is retained verbatim, including historical component descriptions. This note does not replace those texts or relicense their sources.

Tractanda's three explicitly marked Swift additions provide package-only imported-PSK context setup and non-secret authentication-fact inspection. Their complete before/after source hashes and diff are recorded in the package's `Vendor/manifest.json` and `Vendor/niossl-psk.patch`. No BoringSSL C/C++ implementation is changed. First-party wrapper/tests/scripts remain under Tractanda's root license.
