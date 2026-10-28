# Contributing to Tractanda

This is a proof of concept. Discuss changes that affect canonical records, permissions, public query semantics or recovery before implementing them.

- Use Swift 6.4 and the project's `swift format` configuration.
- Keep service semantics independent of any one client. The browser Kanban is an example adapter.
- Preserve unknown metadata, item identity, whole-edit guards and exact retry behavior.
- Treat categories, structural parentage, data-class inheritance and access rights as distinct concepts.
- Add meaningful tests for changed behavior; use temporary stores and synthetic data.
- Run `sh scripts/test.sh`. State what ran, what failed and what was unavailable; do not treat a successful shell exit as proof every test bundle passed.
- Never include local stores, credentials, model weights, screenshots of private data or research/reference documents in a contribution. Use `python3 scripts/audit-release.py` to inspect the candidate source tree.
- Prefer concise changes with a concrete before/after description, validation and remaining limitations.

Issue reports should include platform/toolchain, minimal reproduction and sanitized diagnostics. Security-sensitive reports belong in the private route described in SECURITY.md.

## Licensing of contributions

The current first-party license is PolyForm Noncommercial 1.0.0. The maintainer may offer separate commercial terms or choose a different license for future releases. Before accepting substantive external code, the maintainer must settle the necessary contribution and relicensing permissions with its author. No copyright assignment is implied merely by opening an issue or pull request. Please discuss proposed contributions first; a standard contribution agreement is not yet established.
