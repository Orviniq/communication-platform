# TLS

**This is provisioning, not code.** Nothing in the backend reads these files; nginx
and the client devices do.

## Superseded posture: the wildcard certificate

The public deployment at `chat.orviniq.com` used to terminate TLS in the host's
nginx with the wildcard Let's Encrypt certificate the VPS already renews. Only the
nginx site has moved off it; coturn still points at `/etc/letsencrypt/live/`.

## Active posture: a private CA for a network shutdown

A public CA has to be reachable to issue and renew. If the system must keep working
through a network shutdown, it can depend on no live foreign CA: the root generated
by `make_ca.sh` is created once, kept offline, and pre-installed on the devices that
will use the server. `ops/nginx/chat.orviniq.com.conf` now carries the private-CA
`ssl_certificate` pair directly; the clients pin the CA as described below.

### Generating

```sh
DOMAIN=chat.example.internal bash ops/tls/make_ca.sh
```

Everything lands in `ops/tls/out/`, which is **gitignored**. `ca.key` is the trust
anchor for every client: keep it off the server, offline, and backed up separately.
Only `server.crt` and `server.key` belong on the VPS, at `/etc/chat/tls/`.

### nginx posture under the private CA

These are set in the site file, not in a snippet:

- **TLS 1.3 only** (`ssl_protocols TLSv1.3`)
- **0-RTT / early data off** (`ssl_early_data off`) — 0-RTT payloads are replayable
- **HSTS** for a year, including subdomains

### Client pinning

The script prints two SPKI pins. Pin **both** in the client:

- the **primary** pin, from the current server certificate;
- the **backup** pin, from `backup.key`, which is not yet in use.

Pinning only the primary means a key rotation — or a lost key — locks every device
out permanently. Pinning a backup gives you exactly one safe rotation; generate a new
backup and ship it in a client update before you use the old one.

Recompute a pin from any certificate with:

```sh
openssl x509 -in server.crt -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary \
  | base64
```

### Distributing the trust anchor before a shutdown

The root certificate and the client app have to reach devices **before** they are
needed, because afterwards there may be no channel to deliver them. That is a
distribution problem, not a backend one, and it is out of scope for this repository.
What matters here is that it is a real prerequisite and not an afterthought:

- ship the root certificate **inside** the client app rather than asking users to
  install a profile, so trust travels with the binary;
- distribute the app out-of-band (sideload, MDM, or a signed local build) and record
  which build carries which pins;
- re-verify pins on every client release — a client shipped with stale pins cannot
  connect and cannot be fixed remotely.

## Honest limits

A private CA moves trust from the public PKI to you. It does not add confidentiality
beyond what the end-to-end layer already provides, and it does not hide **that** a
device connected or **when**. It protects the transport, and it removes a live
external dependency. That is all it is for.
