# Signed Debian preview channel

The preview repository serves Debian 13 packages for `amd64` and `arm64` from the existing [Tractanda Pages site](https://cubiculum-ai.github.io/tractanda/). It contains package bytes under `/apt/pool/`, signed metadata under `/apt/dists/preview/`, and the dedicated public archive key. Package installation preserves an existing compatible store; it does not create cluster membership or OS accounts.

Download the public key, inspect its complete fingerprint, and compare it with [the reviewed fingerprint](apt/fingerprint.txt) in the release's source before installing it. The archive key is separate from GitHub and Apple signing identities.

```sh
curl --fail --location --output tractanda-archive-keyring.asc \
  https://cubiculum-ai.github.io/tractanda/apt/tractanda-archive-keyring.asc
gpg --show-keys --fingerprint tractanda-archive-keyring.asc
sudo install -d -m 0755 /etc/apt/keyrings
sudo install -m 0644 tractanda-archive-keyring.asc /etc/apt/keyrings/tractanda-archive-keyring.asc
sudo tee /etc/apt/sources.list.d/tractanda.sources >/dev/null <<'EOF'
Types: deb
URIs: https://cubiculum-ai.github.io/tractanda/apt/
Suites: preview
Components: main
Signed-By: /etc/apt/keyrings/tractanda-archive-keyring.asc
EOF
sudo apt update
apt-cache policy tractanda
sudo apt install tractanda
```

APT selects the host architecture. This source trusts only its named archive key and uses normal signature, index and package hash validation. Never use `trusted=yes`, disable authentication, or ignore an expired or invalid signature. Normal updates use `sudo apt update` followed by `sudo apt upgrade`; the preview channel does not install an unattended-upgrades policy.

The site publishes a complete signed snapshot with SHA-256 by-hash indexes. Retention is bounded to the current version and at most one previous version when they fit the site budget. Release metadata expires after 90 days: maintainers must publish freshly signed metadata before expiry, using the existing key. An expired channel fails closed; direct GitHub release assets remain available with release checksums. A key rotation is an explicit reviewed operation: verify the new full fingerprint through a trusted source, then replace the per-source key file. Package builds never generate a fresh production key.

For maintainers, `scripts/apt-repository.py` builds from the two admitted release `.deb` files. The private key stays in a protected local GnuPG home or existing agent; only its public export and signed output are uploaded. `apt-site.tar.gz` is a release asset, covered by `SHA256SUMS`. The Pages workflow verifies that archive, the pinned source key and all signed metadata/package hashes before deploying the manual and APT subtree together. No package bytes or private signing material are committed to Git.
