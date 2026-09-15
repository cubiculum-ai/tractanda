# Linux PAM broker boundary

`tractanda-auth-helper` is a Linux-only, root-started local broker for a Tractanda daemon that runs as a non-root service account while authenticating ordinary OS accounts. It is not installed or launched by the application.

An administrator selects only these fixed startup values:

```sh
tractanda-auth-helper --socket /run/tractanda/auth.sock --allowed-user tractanda-service
```

The socket parent must already be root-owned and not group/other writable. The helper rejects symlinked or unsafe parents and any existing final path; it creates a `0600` socket owned by the allowed service user. The service sets `TRACTANDA_AUTH_SOCKET` in its trusted process environment before launch. HTTP and CLI arguments do not select the helper, PAM service, target UID, or service UID.

The protocol is local and fixed: a four-byte big-endian payload length followed by `username NUL password NUL` (128/4096 byte maxima), then exactly one eight-byte `(status, uid)` response. Linux clients require a root `SO_PEERCRED` peer and accept success only when the response UID equals their independently resolved account UID. The helper requires the connecting peer's `SO_PEERCRED` UID to equal its configured non-root service account before reading any credential bytes.

The helper invokes the existing fixed `login` PAM path, including authentication, account management, and resolved `PAM_USER` UID matching. It has no command, file, PAM-service, or target-UID inputs. It disables core dumps, clears protocol buffers, puts each PAM attempt in a short-lived child with an alarm deadline, and permits at most four concurrent checks. It records no passwords.

Root authorization, the root-owned runtime directory, service supervision, PAM policy, and host installation are operational deployment responsibilities and are intentionally separate from this source change. Same-user or root daemon PAM verification remains direct. If a non-root daemon needs to authenticate another account and has no valid `TRACTANDA_AUTH_SOCKET`, it returns the existing unavailable-authentication error.

`scripts/test-pam-broker-linux.sh` refuses to run unless `TRACTANDA_PAM_BROKER_CONTAINER_TEST=1` and root are supplied in a fresh disposable Linux container. It creates no-home temporary accounts, uses synthetic credentials, and covers successful other-user authentication, bad password, expired account, unauthorized peer, malformed/oversized/stalled frames, and a non-root fake broker rejection. It does not perform host installation.
