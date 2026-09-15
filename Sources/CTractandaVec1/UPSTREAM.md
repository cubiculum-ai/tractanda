# SQLite Vec1 provenance

`Vendor/vec1.c` is an unmodified copy of SQLite Vec1 from Fossil check-in
`1965bb9e53c83a85c36fe9f911c832183a11cf50845c1dbf9f2270d5a2d38668`
(trunk, 2026-09-09 14:05:56 UTC).

Source: https://sqlite.org/vec1/raw/vec1.c?ci=1965bb9e53c83a85c36fe9f911c832183a11cf50845c1dbf9f2270d5a2d38668

SHA-256: `b4bc039d0b5ecb5d7749f95b9fdc2a8224228aacf59518bb3e37afa6535d7662`

The upstream source begins with SQLite's public-domain dedication and blessing.
This project adds only `vec1_registration.c`, which registers the extension on
the supplied SQLite connection. It does not call `sqlite3_auto_extension`.
