# TLS test fixtures

Test-only certificates for `test/features/networking/transport_security_test.dart`.
They exist so the trust behaviour can be proved against a real TLS handshake
rather than a mock, which is the only way to show that a chain outside the
provisioned authority is actually refused.

| File | Purpose |
|---|---|
| `provisioned_ca.pem` | The authority the client under test is provisioned with. |
| `server_chain.pem` | A `localhost` leaf signed by that authority. |
| `server_key.pem` | The leaf's private key, used by the in-test server. |
| `unrelated_ca.pem` | A second, unrelated authority, used to prove refusal. |

`server_key.pem` is a **test key**. It is generated for `localhost`, is not
used by any build or deployment, protects nothing, and must never be treated as
a secret or reused anywhere. The signing keys for both authorities were
discarded at generation time, so neither can issue anything further.

None of this is release provisioning. The real authority reaches a provisioned
build through `PRODUCTION_PRIVATE_CA_PEM_BASE64`, or through
`DEVELOPMENT_PRIVATE_CA_PEM_BASE64` in the development flavor; see
`android/provisioning/README.md`.
