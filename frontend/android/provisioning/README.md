# Android trust provisioning

The checked-in network-security resource is a fail-closed buildable baseline. A
controlled production build MUST render `network_security_config.xml.template` using the
same single host, primary pin, and backup pin supplied to Dart compile-time
configuration, then place it at
`app/src/production/res/xml/network_security_config.xml`. The independently supplied
private root PEM is placed at
`app/src/production/res/raw/provisioned_private_ca.pem`.

**These resources do not govern the app's own API traffic.** Android applies them
to the platform's Java HTTP stacks and WebView; this client's REST and WebSocket
transports both run on `dart:io`, which does not consult them. Trust for that
traffic is installed in Dart from `<ENV>_PRIVATE_CA_PEM_BASE64`; see ADR-043 and
`docs/platform-android.md`. What is rendered here is retained as defence in depth
for any future WebView or Java-side traffic.

Those rendered resources are provisioning artifacts and are ignored by Git. The build
pipeline must verify the CA SHA-256 fingerprint and both SPKI SHA-256 digests before
compilation. The template deliberately has no pin expiration fallback: failure to match
either provisioned pin remains blocking. Development may use a separately branded,
separately provisioned flavor. No checked-in or production configuration trusts the
user-added certificate store.

Android Network Security Configuration performs certificate-chain trust and the primary
or backup SPKI match. The Dart `PlatformTrustPort` is the application boundary for that
native enforcement; it never exposes a certificate-bypass operation.
