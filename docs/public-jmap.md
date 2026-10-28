# Public HTTPS JMAP binding

This is opt-in source/private functionality. It does not change the installed daemon, enable a listener, create an identity or deploy a release. Unix IPC and the default loopback browser at port48728 remain explicit local bindings. Personal peer PSK transport remains a separate authenticated private binding of the same engine.

The configured public binding provides authenticated Session/API, raw blob upload/download, Blob/copy, SSE and credential-scoped PushSubscription/get/set. Item/Revision methods use the same validated dispatcher, current OS admission and current Item ACLs as local clients. A URI, Host, Origin or forwarding header never selects a user. The one logical account is the durable StoreID, not a username, replica, path or profile name.

## Configuration and external identities

Pass an administrator-owned JSON file with `tractanda daemon STORE SOCKET --public-jmap-config /absolute/public-jmap.json`. This adds the explicit endpoint; `--http-port`/`--no-http` still control the existing local browser independently. Configuration files must be regular, non-symlink, root/service-owned, not group/world writable, and at most256KiB.

Example configuration (placeholder names/paths, not an installed service):

```json
{
  "baseURL": "https://server.example:9443",
  "transport": {
    "builtinTLS": {
      "host": "127.0.0.1",
      "port": 9443,
      "identity": {
        "pem": {
          "certificateChainFile": "/absolute/external-chain.pem",
          "privateKeyFile": "/absolute/external-key.pem"
        }
      }
    }
  },
  "callbackPolicy": { "privateOrigins": [] },
  "maxSizeUpload": 50000000,
  "maxConcurrentUpload": 8,
  "maximumStagedBytesPerUser": 1073741824,
  "minimumFreeBytes": 1073741824,
  "requestBodyIdleSeconds": 3600
}
```

Certificate issuance/renewal stays with the OS or an external administrator-operated manager. The daemon creates no CA, ACME account or certificate service. Built-in TLS checks the configured DNS hostname and the full certificate interval for every new connection. Invalid replacement material retains the old independently valid context; an expired/not-yet-valid context cannot serve new handshakes. An explicit host management reload hook or normal managed restart consumes externally replaced identity material. No network method reloads certificates.

On macOS, `identity: {"systemKeychain":{}}` selects the explicitly configured system default identity; explicit identity-domain and persistent-reference selections are also supported. Headless Keychain interaction is disabled once for the process before services, and signing fails closed rather than prompting. Private keys are not exported. Linux uses external PEM files.

An existing same-host TLS proxy can instead use `transport: {"trustedProxyUnix":{"path":"/absolute/private/backend.sock"}}`. The HTTP backend socket is0600 under service-owned private directory custody; unsafe renameable ancestors and symlink traversal are rejected. The proxy must have permission to connect and preserve the configured public Host. Forwarded identity/scheme headers are ignored. Configure the real external HTTPS baseURL and forwarding routes; Tractanda does not install or operate the proxy.

## Routes, authentication and state

Resource URLs come from the administrator's HTTPS baseURL and installed resource providers, not request headers:

| Resource | Route relative to baseURL |
|---|---|
| Session | GET `/jmap/session`; root `/.well-known/jmap` also returns Session |
| API | POST `/jmap/api`, application/json |
| Upload | POST `/jmap/upload/{accountId}`, raw bytes |
| Download | GET `/jmap/download/{accountId}/{blobId}/{name}?type={type}` |
| Events | GET `/jmap/events?types={types}&closeafter={closeafter}&ping={ping}` |
| Sign in/out | POST `/auth/login` / `/auth/logout` |

Sign in over the configured HTTPS origin with JSON username/password using the existing OS password authentication. Retain the returned opaque bearer and send Authorization: Bearer on protected resources. There is no new user database or refresh-token service. Grants retain the existing1hour idle/12hour absolute lifetime; logout, expiry or current OS admission loss invalidates access. Background event/callback maintenance does not renew idle lifetime. The native TractandaAuth/createSession shortcut remains unavailable remotely.

GET Session and the same-binding API's sessionState use the same captured metadata provider. In-batch TractandaSession/get returns that captured document, not a second lookup. Metadata includes configured URLs/limits and effective rights; it excludes Item/query state. A shared client cache accepts either explicit local discovery or the real public Session document without fabricating public URLs for IPC.

## Raw blobs and owned attachments

Blob IDs are SHA256 of immutable raw bytes. A digest is an identifier, never proof of access. Unreferenced stages are accessible only to the uploading UID/principal-name mapping, including in the shared account. Completed stages ordinarily remain at least1hour; quota pressure evicts oldest unreferenced stages first. Aborted/incomplete stages are unaccepted operational data and never become canonical Items during recovery.

TractandaAttachment/attachBlob accepts accountId, itemID, expectedRevisionID, blobId, filename, mediaType and operationID. It uses existing Item CAS/current permission checks and bounded owned-payload transfer, returning the existing compact attachment acknowledgement. Exact retry can reconcile against the canonical operation even after the temporary source stage expires. Canonical descriptors, requestIdentity and immutable history are unchanged. Current permission on the Item governs historical blob reads; a hash guessed from another user's private stage grants nothing. Blob/copy validates both accounts and each blob; the sole same-account mapping may retain the same digest.

Uploads/downloads use bounded256KiB windows and writable-channel backpressure, without whole-file buffering or base64 HTTP bodies. Filename/type substitution cannot inject headers or filesystem paths. Default upload50,000,000bytes/concurrency8, per-user stage quota and filesystem reserve are configurable. API requests are at most8MiB/32calls; standard get64distinct IDs; public Push set64operations; Blob/copy256distinct IDs. Over-limit valid method collections produce requestTooLarge. Standard get is complete or errors; explicit getBounded alone exposes continuation.

## Events and callback policy

SSE supports selected types or `*`, closeafter=state/no, ping0 or the reported bounded interval, reconnect IDs, and coalesced current get-state values. It sends state/identity metadata rather than content. Slow readers do not accumulate an unbounded event history. Channel closure, credential loss or access revocation releases active subscriptions and private stream handles. Healthy bodies have no absolute network-operation deadline; the configurable request body timer measures absence of incoming progress only, apart from credential/protocol lifetimes.

Push subscriptions are scoped to an opaque credential identity, not UID alone. An unverified challenge is not disclosed by get and causes no retries before proof; after verification, the consumed client-provided proof may be returned. URLs and encryption keys are never returned by get. The registry is memory-only, matching memory-only grants; daemon restart invalidates both. Supported encrypted pushes use the standard Web Push encryption format.

Callbacks default to verified public HTTPS destinations. Private, LAN and tailnet destinations require exact administrator-configured host/port origins, for example `callbackPolicy: {"privateOrigins":[{"host":"notify.internal","port":443}]}`. This does not disable TLS verification. DNS/address screening is repeated for each connection, redirects are not followed, and bounded TTL/backoff/rate limits apply. These settings are node-private administration, not Items or peer-supplied trust.

## Qualification and deployment boundary

Receipts under work/jmap-alignment-20261025/http bind the exact source and bounded private checks. Tests use an independent certificate-verifying TLS client and isolated endpoints, with injected OS-directory/password providers; they do not prove a deployed PAM/proxy/certificate-manager installation. No live identity or service was changed. Successful write receipts remain successful if later hydration is denied; retain original operation IDs after uncertain/lost replies. This source work does not introduce generic Item/set, hard destruction or delta feeds; query advertises canCalculateChanges=false and changes returns cannotCalculateChanges after argument validation.
