# TractandaPeerTLS

Standalone Swift 6.4 package for the certificate-free peer TLS profile proved on macOS and Linux ARM64. It is not yet connected to the root product, a listener or Store authorization.

Only `TractandaPeerTLS` is exported as a package product. `PeerTLSSecret` owns a 32-byte secret with cleansed storage; callers remain responsible for input copies and host-private storage. Persist and exchange pairing material outside this package, then supply its bytes to the initializer; `generate()` intentionally provides no secret-export API. Use OS-random pairing secrets, not passwords/PINs padded to 32 bytes. `PeerTLSContext` is immutable after construction. Install it before channel activation and application handlers. A `PeerTLSSession` callback and application activation occur only after the exact imported-PSK/TLS 1.3/X25519MLKEM768/AES-256-GCM/ALPN profile succeeds. Application writes before authentication fail instead of being queued. This authenticates a peer binding; current Store trust and user permissions remain separate checks.

The initial profile deliberately retains the proof's exact domain/version/ALPN strings. Changing those strings is a profile change, not a transparent rename. Store/replica/pairing identifiers are canonical lowercase UUIDv1s. Roles and importer-context field order are fixed. Pairwise secrets, live configuration and production data never belong in this repository.

## Source and licenses

`Sources/NIOSSL`, `Sources/CNIOBoringSSL` and `Sources/CNIOBoringSSLShims` are vendored from Apple NIOSSL revision `15e0b9e495786807272dd4891fa4bac76aa43034`, bundling BoringSSL `8eb25be6fa18d475291122887a7bccd3762ff236`. Upstream `LICENSE.txt`, `NOTICE.txt` and every source license header remain intact. The three Swift modifications are marked Tractanda additions and recorded in `Vendor/niossl-psk.patch`; no C/C++ implementation is modified. First-party wrapper, tests and maintenance scripts are governed by the root repository LICENSE; upstream terms remain applicable to vendored material.

Ordinary clean-checkout builds use public SwiftPM dependencies and `Package.resolved`:

```sh
swift test --package-path Packages/TractandaPeerTLS --jobs 2
python3 Packages/TractandaPeerTLS/Vendor/regenerate.py
```

No build step requires an ignored work directory or patched dependency checkout. Offline source verification checks the full vendored file inventory and patch digest. For reviewed regeneration, first obtain the exact public upstream revision, then run `Vendor/regenerate.py --upstream-checkout PATH`; it reads pinned Git objects, never uncommitted upstream files. Review the generated manifest and patch before accepting an upgrade. Keep C++17, module/prefix headers and `PrivacyInfo.xcprivacy` intact.

`Scripts/validate.py` supplies a bounded isolated validation run, with a 2 GiB total artifact cap including 256 MiB runtime allowance and a genuine 10 GiB free-space reserve. Optional `--cached-checkouts PATH` creates local, exact-revision Git mirrors without fetching new dependencies. It never imports root Core sources or shares the root build tree. On Linux mount only this package at `/proof`, use the cached Swift 6.4 image, a read-only guest root and non-root UID, then run `/proof/Scripts/validate.py`; DNS/network are unnecessary once mirrors exist. The runner uses native SwiftPM on Linux because current xcbuild overrides the writable TMPDIR for assembler work; macOS uses the default build backend. Native Linux test discovery keeps compiler index records enabled; disabling them fails discovery in Swift 6.4. `--linux-cached` performs that exact cached-image run from the host. Native scripts own child waits, logs and timeout cleanup.

Synthetic tests generate certificate controls in memory through BoringSSL; no private-key fixture is shipped or logged. Tests include fresh hybrid handshakes/protected payloads, importer identity/context rejection, downgrade/certificate/ALPN rejection, pre-authentication handoff/write blocking and ciphertext integrity. x86 Linux and release packaging require separate validation.
