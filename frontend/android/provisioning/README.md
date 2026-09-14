# Android trust provisioning

The checked-in network-security resource is a fail-closed buildable baseline. A
controlled production build MUST render `network_security_config.xml.template` using the
same single host, primary pin, and backup pin supplied to Dart compile-time
configuration, then place it at
`app/src/production/res/xml/network_security_config.xml`. The independently supplied
private root PEM is placed at
`app/src/production/res/raw/provisioned_private_ca.pem`.

`tool/render_production_trust.sh` renders both from the `PRODUCTION_*` provisioning
values. `tool/build_production_release.sh`, the only supported way to make a production
artifact for a phone, runs it on every build, so the rendered resources cannot drift from
the values compiled into Dart (ADR-076 D7), and `tool/verify_release_apk.sh --production`
reads them back out of the packaged artifact. `docs/release-signing.md` is the manual.

**These resources do not govern the app's own API traffic.** Android applies them
to the platform's Java HTTP stacks and WebView; this client's REST and WebSocket
transports both run on `dart:io`, which does not consult them. Trust for that
traffic is installed in Dart from `<ENV>_PRIVATE_CA_PEM_BASE64`; see ADR-043 and
`docs/platform-android.md`. What is rendered here is retained as defence in depth
for any future WebView or Java-side traffic.

Those rendered resources are provisioning artifacts and are ignored by Git, and no pin,
CA digest or CA certificate is committed. Before compilation the renderer requires every
value in the form the app accepts, checks the CA certificate against its SHA-256
fingerprint and its expiry, requires the two SPKI SHA-256 digests to differ, and refuses a
placeholder that survives substitution; the release script also requires the primary
digest to equal the one the live host serves. The template deliberately has no pin
expiration fallback: failure to match either provisioned pin remains blocking. Development
may use a separately branded, separately provisioned flavor. No checked-in or production
configuration trusts the user-added certificate store.

Android Network Security Configuration performs certificate-chain trust and the primary
or backup SPKI match. The Dart `PlatformTrustPort` is the application boundary for that
native enforcement; it never exposes a certificate-bypass operation.
