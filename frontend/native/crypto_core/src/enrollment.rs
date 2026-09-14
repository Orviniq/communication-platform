//! Two-phase device enrollment and recovery-owned identity backup operations.
//!
//! Dart treats the returned state packages as opaque, protected-database records.
//! All parsing, key generation, signing, password derivation, authenticated
//! encryption, checksum handling, and secret cleanup remain in this module.

#![allow(
    clippy::missing_errors_doc,
    reason = "All protocol operations use the shared payload-free CryptoError contract."
)]

use ed25519_dalek::SigningKey;
use subtle::ConstantTimeEq;
use zeroize::Zeroize;

use crate::{
    device_signatures::{
        CrossSigningIdentity, DeviceBundle, Ed25519Signature, IkPublic, PublicPrekey, RawUuid,
        SignedPrekey, encode_cross_signature, encode_master_signature, encode_pq_signed_prekey,
        encode_signed_prekey, verify_cross_signature, verify_master_signature,
        verify_pq_signed_prekey, verify_signed_prekey,
    },
    error::{CryptoError, CryptoResult},
    provider::{
        ARGON2_SALT_BYTES, CryptoProvider, ED25519_PUBLIC_BYTES, ED25519_SECRET_BYTES,
        ED25519_SIGNATURE_BYTES, MLKEM768_PUBLIC_BYTES, MLKEM768_SECRET_BYTES, RustCryptoProvider,
        X25519_PUBLIC_BYTES, X25519_SECRET_BYTES, XCHACHA_NONCE_BYTES,
    },
    secret::{SecretBytes, SecretVec},
};

pub const INITIAL_CLASSICAL_ONE_TIME_PREKEYS: usize = 8;
pub const INITIAL_PQ_ONE_TIME_PREKEYS: usize = 4;
pub const BACKUP_BUCKET_BYTES: usize = 4096;
pub const DEVICE_FINGERPRINT_BYTES: usize = 32;
pub const DEVICE_LOG_BUCKET_BYTES: usize = 256;
pub const DEVICE_LOG_INSPECTION_BYTES: usize = 72;
pub const PEER_DEVICE_LOG_INSPECTION_BYTES: usize = 108;
pub const SAFETY_FINGERPRINT_BYTES: usize = 32;
pub const DEVICE_LABEL_BUCKET_BYTES: usize = 256;

const DEVICE_PACKAGE_MAGIC: &[u8; 8] = b"CPDVV001";
const IDENTITY_PACKAGE_MAGIC: &[u8; 8] = b"CPIDV001";
const BACKUP_MAGIC: &[u8; 8] = b"CPKBV001";
const IDENTITY_PLAINTEXT_MAGIC: &[u8; 8] = b"CPIPV001";
const DEVICE_LOG_MAGIC: &[u8; 8] = b"CPDLV001";
const BACKUP_DOMAIN: &[u8] = b"chat:v1:identity-backup";
const DEVICE_LOG_DOMAIN: &[u8] = b"chat:v1:device-log-record";
const SAFETY_FINGERPRINT_DOMAIN: &[u8] = b"chat:v1:safety-fingerprint";
const USER_ATTESTATION_DOMAIN: &[u8] = b"chat:v1:user-signing-attestation";
const DEVICE_LABEL_MAGIC: &[u8; 8] = b"CPLBV001";
const DEVICE_LABEL_PLAINTEXT_MAGIC: &[u8; 8] = b"CPLPV001";
const DEVICE_LABEL_DOMAIN: &[u8] = b"chat:v1:device-label";
const DEVICE_LABEL_KEY_DOMAIN: &[u8] = b"chat:v1:device-label-key";
const VERIFY_IDENTITY_MAGIC: &[u8; 8] = b"CPIRV001";
const VERIFY_BUNDLE_MAGIC: &[u8; 8] = b"CPBRV001";
const VERIFY_LOG_MAGIC: &[u8; 8] = b"CPDLR001";
const SAFETY_MAGIC: &[u8; 8] = b"CPSFV001";
const VERIFY_ATTESTATION_MAGIC: &[u8; 8] = b"CPUAV001";
const BACKUP_MEMORY_KIB: u32 = 65_536;
const BACKUP_ITERATIONS: u32 = 3;
const BACKUP_PARALLELISM: u32 = 4;
const BACKUP_HEADER_BYTES: usize = 64;
const IDENTITY_PLAINTEXT_BYTES: usize = 120;
const IDENTITY_PRIVATE_BYTES: usize = ED25519_SECRET_BYTES * 3;
const DEVICE_FIXED_PUBLIC_BYTES: usize = 8
    + 16
    + 4
    + 4
    + 4
    + 2
    + 2
    + 64
    + X25519_PUBLIC_BYTES
    + ED25519_SIGNATURE_BYTES
    + MLKEM768_PUBLIC_BYTES
    + ED25519_SIGNATURE_BYTES
    + DEVICE_FINGERPRINT_BYTES;
const RECOVERY_ENTROPY_BYTES: usize = 32;
const RECOVERY_CHECKSUM_BYTES: usize = 2;
const RECOVERY_PAYLOAD_BYTES: usize = RECOVERY_ENTROPY_BYTES + RECOVERY_CHECKSUM_BYTES;
const DEVICE_LABEL_PLAINTEXT_BYTES: usize = 160;
const DEVICE_LABEL_MAX_BYTES: usize = 128;
const DEVICE_LABEL_MAX_SCALARS: usize = 64;
const CROCKFORD_ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

struct IdentitySecrets {
    master: [u8; ED25519_SECRET_BYTES],
    self_signing: [u8; ED25519_SECRET_BYTES],
    user_signing: [u8; ED25519_SECRET_BYTES],
}

impl Drop for IdentitySecrets {
    fn drop(&mut self) {
        self.master.zeroize();
        self.self_signing.zeroize();
        self.user_signing.zeroize();
    }
}

#[allow(
    dead_code,
    reason = "test vectors inspect the parsed public projection"
)]
struct ParsedIdentityPackage<'a> {
    user_id: RawUuid,
    master_public: [u8; ED25519_PUBLIC_BYTES],
    self_signing_public: [u8; ED25519_PUBLIC_BYTES],
    master_signature: [u8; ED25519_SIGNATURE_BYTES],
    secrets: IdentitySecrets,
    recovery_secret: &'a [u8],
    backup: &'a [u8],
}

struct ParsedDevicePackage<'a> {
    user_id: RawUuid,
    registration_id: u32,
    spk_id: u32,
    pq_spk_id: u32,
    ik_public: IkPublic,
    spk_public: [u8; X25519_PUBLIC_BYTES],
    pq_spk_public: [u8; MLKEM768_PUBLIC_BYTES],
    _remainder: &'a [u8],
}

pub fn prepare_device() -> impl FnOnce(&[u8]) -> CryptoResult<Vec<u8>> {
    |user_id| prepare_device_with_provider(&RustCryptoProvider::default(), user_id)
}

pub fn prepare_device_with_provider<P: CryptoProvider>(
    provider: &P,
    user_id: &[u8],
) -> CryptoResult<Vec<u8>> {
    let user_id = raw_uuid(user_id)?;
    let mut device_signing_secret = SecretBytes::<ED25519_SECRET_BYTES>::zeroed();
    let mut identity_secret = SecretBytes::<X25519_SECRET_BYTES>::zeroed();
    let mut signed_prekey_secret = SecretBytes::<X25519_SECRET_BYTES>::zeroed();
    provider.random_bytes(device_signing_secret.expose_mut())?;
    provider.random_bytes(identity_secret.expose_mut())?;
    provider.random_bytes(signed_prekey_secret.expose_mut())?;

    let device_signing_public = SigningKey::from_bytes(device_signing_secret.expose())
        .verifying_key()
        .to_bytes();
    let identity_public = provider.x25519_public(&identity_secret)?;
    let ik_public = IkPublic::from_halves(device_signing_public, identity_public);
    let spk_public = provider.x25519_public(&signed_prekey_secret)?;
    let spk_id = 1;
    let signed_prekey_bytes = encode_signed_prekey(&SignedPrekey {
        user_id,
        prekey: PublicPrekey {
            id: spk_id,
            public: &spk_public,
        },
    })?;
    let spk_signature = provider.ed25519_sign(&device_signing_secret, &signed_prekey_bytes)?;

    let (pq_spk_public, pq_spk_secret) = provider.mlkem768_keypair()?;
    let pq_spk_id = 1;
    let pq_signed_prekey_bytes = encode_pq_signed_prekey(&SignedPrekey {
        user_id,
        prekey: PublicPrekey {
            id: pq_spk_id,
            public: &pq_spk_public,
        },
    })?;
    let pq_spk_signature =
        provider.ed25519_sign(&device_signing_secret, &pq_signed_prekey_bytes)?;

    let mut registration_bytes = [0u8; 4];
    provider.random_bytes(&mut registration_bytes)?;
    let registration_id = u32::from_be_bytes(registration_bytes) & 0x7fff_ffff;
    let fingerprint = provider.sha256(ik_public.as_bytes())?;

    let mut classical_public =
        Vec::with_capacity(INITIAL_CLASSICAL_ONE_TIME_PREKEYS * (4 + X25519_PUBLIC_BYTES));
    let mut classical_secrets =
        Vec::with_capacity(INITIAL_CLASSICAL_ONE_TIME_PREKEYS * X25519_SECRET_BYTES);
    for index in 0..INITIAL_CLASSICAL_ONE_TIME_PREKEYS {
        let mut secret = SecretBytes::<X25519_SECRET_BYTES>::zeroed();
        provider.random_bytes(secret.expose_mut())?;
        let public = provider.x25519_public(&secret)?;
        push_u32(&mut classical_public, u32::try_from(index + 1)?);
        classical_public.extend_from_slice(&public);
        classical_secrets.extend_from_slice(secret.expose());
    }

    let mut pq_public =
        Vec::with_capacity(INITIAL_PQ_ONE_TIME_PREKEYS * (4 + MLKEM768_PUBLIC_BYTES));
    let mut pq_secrets = Vec::with_capacity(INITIAL_PQ_ONE_TIME_PREKEYS * MLKEM768_SECRET_BYTES);
    for index in 0..INITIAL_PQ_ONE_TIME_PREKEYS {
        let (public, secret) = provider.mlkem768_keypair()?;
        push_u32(&mut pq_public, u32::try_from(index + 1)?);
        pq_public.extend_from_slice(&public);
        pq_secrets.extend_from_slice(secret.expose());
    }

    let private_bytes = ED25519_SECRET_BYTES
        + X25519_SECRET_BYTES
        + X25519_SECRET_BYTES
        + MLKEM768_SECRET_BYTES
        + classical_secrets.len()
        + pq_secrets.len();
    let mut package = Vec::with_capacity(
        DEVICE_FIXED_PUBLIC_BYTES + classical_public.len() + pq_public.len() + private_bytes,
    );
    package.extend_from_slice(DEVICE_PACKAGE_MAGIC);
    package.extend_from_slice(user_id.as_bytes());
    push_u32(&mut package, registration_id);
    push_u32(&mut package, spk_id);
    push_u32(&mut package, pq_spk_id);
    push_u16(
        &mut package,
        u16::try_from(INITIAL_CLASSICAL_ONE_TIME_PREKEYS)?,
    );
    push_u16(&mut package, u16::try_from(INITIAL_PQ_ONE_TIME_PREKEYS)?);
    package.extend_from_slice(ik_public.as_bytes());
    package.extend_from_slice(&spk_public);
    package.extend_from_slice(&spk_signature);
    package.extend_from_slice(&pq_spk_public);
    package.extend_from_slice(&pq_spk_signature);
    package.extend_from_slice(&fingerprint);
    package.extend_from_slice(&classical_public);
    package.extend_from_slice(&pq_public);
    package.extend_from_slice(device_signing_secret.expose());
    package.extend_from_slice(identity_secret.expose());
    package.extend_from_slice(signed_prekey_secret.expose());
    package.extend_from_slice(pq_spk_secret.expose());
    package.extend_from_slice(&classical_secrets);
    package.extend_from_slice(&pq_secrets);
    classical_secrets.zeroize();
    pq_secrets.zeroize();
    Ok(package)
}

pub fn prepare_first_identity(user_id: &[u8]) -> CryptoResult<Vec<u8>> {
    prepare_first_identity_with_provider(&RustCryptoProvider::default(), user_id)
}

pub fn prepare_first_identity_with_provider<P: CryptoProvider>(
    provider: &P,
    user_id: &[u8],
) -> CryptoResult<Vec<u8>> {
    let user_id = raw_uuid(user_id)?;
    let mut secrets = IdentitySecrets {
        master: [0; ED25519_SECRET_BYTES],
        self_signing: [0; ED25519_SECRET_BYTES],
        user_signing: [0; ED25519_SECRET_BYTES],
    };
    provider.random_bytes(&mut secrets.master)?;
    provider.random_bytes(&mut secrets.self_signing)?;
    provider.random_bytes(&mut secrets.user_signing)?;

    let mut recovery_entropy = [0u8; RECOVERY_ENTROPY_BYTES];
    provider.random_bytes(&mut recovery_entropy)?;
    let recovery_secret = encode_recovery_secret(provider, &recovery_entropy)?;
    recovery_entropy.zeroize();

    let backup = encrypt_backup(provider, &user_id, &secrets, recovery_secret.as_bytes())?;
    encode_identity_package(
        provider,
        user_id,
        &secrets,
        recovery_secret.as_bytes(),
        &backup,
    )
}

pub fn restore_identity(
    user_id: &[u8],
    recovery_secret: &[u8],
    backup: &[u8],
) -> CryptoResult<Vec<u8>> {
    restore_identity_with_provider(
        &RustCryptoProvider::default(),
        user_id,
        recovery_secret,
        backup,
    )
}

pub fn restore_identity_with_provider<P: CryptoProvider>(
    provider: &P,
    user_id: &[u8],
    recovery_secret: &[u8],
    backup: &[u8],
) -> CryptoResult<Vec<u8>> {
    let user_id = raw_uuid(user_id)?;
    let normalized = normalize_recovery_secret(provider, recovery_secret)?;
    let secrets = decrypt_backup(provider, &user_id, normalized.as_bytes(), backup)?;
    encode_identity_package(provider, user_id, &secrets, &[], &[])
}

pub fn sanitize_identity_package(package: &[u8]) -> CryptoResult<Vec<u8>> {
    let parsed = parse_identity_package(package)?;
    encode_identity_package(
        &RustCryptoProvider::default(),
        parsed.user_id,
        &parsed.secrets,
        &[],
        &[],
    )
}

/// Re-wraps the *same* cross-signing identity under a freshly generated
/// recovery secret and returns a package carrying both, for one display.
///
/// This is the replacement half of recovery: an already-saved secret is never
/// re-shown, because the application does not retain one, so the only honest
/// remedy for a lost or exposed secret is a new one over the identity that
/// already exists. Generating a *new* identity would invalidate every device
/// cross-signature and every peer attestation of the master key, which is why
/// the caller may not reach for `prepare_first_identity` here.
///
/// No construction changes. The entropy, the Crockford encoding and the
/// Argon2id/XChaCha20-Poly1305 backup are exactly the ones the first upload
/// used, and the encoded package is byte-identical to the original apart from
/// the recovery and backup fields — the master signature included, because
/// Ed25519 signing is deterministic over the same key and message. The old
/// secret stops being usable when the server accepts the higher backup
/// version, not here: this function does not touch the network.
pub fn rotate_recovery_secret(identity_package: &[u8]) -> CryptoResult<Vec<u8>> {
    rotate_recovery_secret_with_provider(&RustCryptoProvider::default(), identity_package)
}

pub fn rotate_recovery_secret_with_provider<P: CryptoProvider>(
    provider: &P,
    identity_package: &[u8],
) -> CryptoResult<Vec<u8>> {
    let parsed = parse_identity_package(identity_package)?;
    let mut recovery_entropy = [0u8; RECOVERY_ENTROPY_BYTES];
    provider.random_bytes(&mut recovery_entropy)?;
    let recovery_secret = encode_recovery_secret(provider, &recovery_entropy)?;
    recovery_entropy.zeroize();
    let backup = encrypt_backup(
        provider,
        &parsed.user_id,
        &parsed.secrets,
        recovery_secret.as_bytes(),
    )?;
    encode_identity_package(
        provider,
        parsed.user_id,
        &parsed.secrets,
        recovery_secret.as_bytes(),
        &backup,
    )
}

/// Encrypts an account-private device label into the backend's smallest label bucket.
///
/// The key is domain-separated from the self-signing seed shared through recovery.
/// The device id is authenticated associated data so the server cannot swap labels
/// between two otherwise authorized devices.
pub fn seal_device_label(
    identity_package: &[u8],
    user_id: &[u8],
    device_id: &[u8],
    label: &[u8],
) -> CryptoResult<Vec<u8>> {
    let provider = RustCryptoProvider::default();
    let identity = parse_identity_package(identity_package)?;
    let user_id = raw_uuid(user_id)?;
    let device_id = raw_uuid(device_id)?;
    if identity.user_id != user_id
        || label.is_empty()
        || label.len() > DEVICE_LABEL_MAX_BYTES
        || std::str::from_utf8(label)
            .map_err(|_| CryptoError::MalformedInput)?
            .chars()
            .count()
            > DEVICE_LABEL_MAX_SCALARS
    {
        return Err(CryptoError::InvalidArgument);
    }
    let key_material = SecretVec::from_slice(&identity.secrets.self_signing, 32)?;
    let derived =
        provider.hkdf_sha256(user_id.as_bytes(), &key_material, DEVICE_LABEL_KEY_DOMAIN)?;
    let key = SecretBytes::new(
        derived
            .expose()
            .try_into()
            .map_err(|_| CryptoError::InternalFailure)?,
    );
    let mut nonce = [0_u8; XCHACHA_NONCE_BYTES];
    provider.random_bytes(&mut nonce)?;
    let mut plaintext = Vec::with_capacity(DEVICE_LABEL_PLAINTEXT_BYTES);
    plaintext.extend_from_slice(DEVICE_LABEL_PLAINTEXT_MAGIC);
    push_u16(&mut plaintext, u16::try_from(label.len())?);
    plaintext.extend_from_slice(label);
    plaintext.resize(DEVICE_LABEL_PLAINTEXT_BYTES, 0);
    provider.random_bytes(&mut plaintext[10 + label.len()..])?;
    let plaintext = SecretVec::from_vec(plaintext, DEVICE_LABEL_PLAINTEXT_BYTES)?;
    let mut header = Vec::with_capacity(8 + 1 + XCHACHA_NONCE_BYTES + 2);
    header.extend_from_slice(DEVICE_LABEL_MAGIC);
    header.push(1);
    header.extend_from_slice(&nonce);
    push_u16(
        &mut header,
        u16::try_from(DEVICE_LABEL_PLAINTEXT_BYTES + 16)?,
    );
    let aad = device_label_aad(&header, &user_id, &device_id);
    let ciphertext = provider.xchacha20poly1305_encrypt(&key, &nonce, &plaintext, &aad)?;
    let mut output = Vec::with_capacity(DEVICE_LABEL_BUCKET_BYTES);
    output.extend_from_slice(&header);
    output.extend_from_slice(&ciphertext);
    let used = output.len();
    output.resize(DEVICE_LABEL_BUCKET_BYTES, 0);
    provider.random_bytes(&mut output[used..])?;
    Ok(output)
}

pub fn open_device_label(
    identity_package: &[u8],
    user_id: &[u8],
    device_id: &[u8],
    blob: &[u8],
) -> CryptoResult<Vec<u8>> {
    if blob.len() != DEVICE_LABEL_BUCKET_BYTES {
        return Err(CryptoError::MalformedInput);
    }
    let provider = RustCryptoProvider::default();
    let identity = parse_identity_package(identity_package)?;
    let user_id = raw_uuid(user_id)?;
    let device_id = raw_uuid(device_id)?;
    if identity.user_id != user_id {
        return Err(CryptoError::AuthenticationFailed);
    }
    let mut reader = Reader::new(blob);
    if reader.take(DEVICE_LABEL_MAGIC.len())? != DEVICE_LABEL_MAGIC {
        return Err(CryptoError::MalformedInput);
    }
    if reader.u8()? != 1 {
        return Err(CryptoError::UnsupportedVersion);
    }
    let nonce: [u8; XCHACHA_NONCE_BYTES] = reader.array()?;
    let ciphertext_len = usize::from(reader.u16()?);
    if ciphertext_len != DEVICE_LABEL_PLAINTEXT_BYTES + 16 {
        return Err(CryptoError::MalformedInput);
    }
    let header_len = reader.position;
    let ciphertext = reader.take(ciphertext_len)?;
    let key_material = SecretVec::from_slice(&identity.secrets.self_signing, 32)?;
    let derived =
        provider.hkdf_sha256(user_id.as_bytes(), &key_material, DEVICE_LABEL_KEY_DOMAIN)?;
    let key = SecretBytes::new(
        derived
            .expose()
            .try_into()
            .map_err(|_| CryptoError::InternalFailure)?,
    );
    let aad = device_label_aad(&blob[..header_len], &user_id, &device_id);
    let plaintext = provider.xchacha20poly1305_decrypt(&key, &nonce, ciphertext, &aad)?;
    let mut plaintext_reader = Reader::new(plaintext.expose());
    if plaintext_reader.take(DEVICE_LABEL_PLAINTEXT_MAGIC.len())? != DEVICE_LABEL_PLAINTEXT_MAGIC {
        return Err(CryptoError::MalformedInput);
    }
    let label_len = usize::from(plaintext_reader.u16()?);
    if label_len == 0 || label_len > DEVICE_LABEL_MAX_BYTES {
        return Err(CryptoError::MalformedInput);
    }
    let label = plaintext_reader.take(label_len)?;
    if std::str::from_utf8(label)
        .map_err(|_| CryptoError::MalformedInput)?
        .chars()
        .count()
        > DEVICE_LABEL_MAX_SCALARS
    {
        return Err(CryptoError::MalformedInput);
    }
    Ok(label.to_vec())
}

fn device_label_aad(header: &[u8], user_id: &RawUuid, device_id: &RawUuid) -> Vec<u8> {
    let mut aad = Vec::with_capacity(DEVICE_LABEL_DOMAIN.len() + header.len() + 32);
    aad.extend_from_slice(DEVICE_LABEL_DOMAIN);
    aad.extend_from_slice(header);
    aad.extend_from_slice(user_id.as_bytes());
    aad.extend_from_slice(device_id.as_bytes());
    aad
}

pub fn cross_sign_device(
    device_package: &[u8],
    identity_package: &[u8],
    device_id: &[u8],
    bundle_version: u32,
) -> CryptoResult<Vec<u8>> {
    if bundle_version == 0 {
        return Err(CryptoError::InvalidArgument);
    }
    let device = parse_device_package(device_package)?;
    let identity = parse_identity_package(identity_package)?;
    let device_id = raw_uuid(device_id)?;
    if device.user_id != identity.user_id {
        return Err(CryptoError::StateViolation);
    }
    let bundle = DeviceBundle {
        user_id: device.user_id,
        device_id,
        ik_public: device.ik_public,
        spk_id: device.spk_id,
        spk_public: &device.spk_public,
        pq_signed_prekey: Some(PublicPrekey {
            id: device.pq_spk_id,
            public: &device.pq_spk_public,
        }),
        registration_id: device.registration_id,
        bundle_version,
    };
    let encoded = encode_cross_signature(&bundle)?;
    let self_signing_secret = SecretBytes::new(identity.secrets.self_signing);
    Ok(RustCryptoProvider::default()
        .ed25519_sign(&self_signing_secret, &encoded)?
        .to_vec())
}

pub fn create_device_log_record(
    identity_package: &[u8],
    user_id: &[u8],
    sequence: u64,
    previous_hash: &[u8],
    canonical_live_set: &[u8],
    identity_version: u32,
    coarse_unix_day: u32,
) -> CryptoResult<Vec<u8>> {
    let provider = RustCryptoProvider::default();
    create_device_log_record_with_provider(
        &provider,
        identity_package,
        user_id,
        sequence,
        previous_hash,
        canonical_live_set,
        identity_version,
        coarse_unix_day,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn create_device_log_record_with_provider<P: CryptoProvider>(
    provider: &P,
    identity_package: &[u8],
    user_id: &[u8],
    sequence: u64,
    previous_hash: &[u8],
    canonical_live_set: &[u8],
    identity_version: u32,
    coarse_unix_day: u32,
) -> CryptoResult<Vec<u8>> {
    if identity_version == 0 {
        return Err(CryptoError::InvalidArgument);
    }
    let identity = parse_identity_package(identity_package)?;
    let user_id = raw_uuid(user_id)?;
    if identity.user_id != user_id {
        return Err(CryptoError::StateViolation);
    }
    let previous_hash = if previous_hash.is_empty() {
        [0; 32]
    } else {
        fixed::<32>(previous_hash)?
    };
    let live_set_hash = provider.sha256(canonical_live_set)?;
    let signed = encode_device_log_signature(
        &user_id,
        sequence,
        &previous_hash,
        &live_set_hash,
        identity_version,
        coarse_unix_day,
    )?;
    let self_signing_secret = SecretBytes::new(identity.secrets.self_signing);
    let signature = provider.ed25519_sign(&self_signing_secret, &signed)?;

    let mut record = Vec::with_capacity(DEVICE_LOG_BUCKET_BYTES);
    record.extend_from_slice(DEVICE_LOG_MAGIC);
    record.push(1);
    push_u64(&mut record, sequence);
    push_u32(&mut record, coarse_unix_day);
    push_u32(&mut record, identity_version);
    record.extend_from_slice(user_id.as_bytes());
    record.extend_from_slice(&previous_hash);
    record.extend_from_slice(&live_set_hash);
    record.extend_from_slice(&signature);
    let padding = DEVICE_LOG_BUCKET_BYTES
        .checked_sub(record.len())
        .ok_or(CryptoError::InternalFailure)?;
    let start = record.len();
    record.resize(DEVICE_LOG_BUCKET_BYTES, 0);
    provider.random_bytes(&mut record[start..start + padding])?;
    Ok(record)
}

pub fn inspect_device_log_record(
    identity_package: &[u8],
    user_id: &[u8],
    record: &[u8],
) -> CryptoResult<Vec<u8>> {
    if record.len() != DEVICE_LOG_BUCKET_BYTES {
        return Err(CryptoError::MalformedInput);
    }
    let identity = parse_identity_package(identity_package)?;
    let expected_user = raw_uuid(user_id)?;
    let mut reader = Reader::new(record);
    if reader.take(8)? != DEVICE_LOG_MAGIC {
        return Err(CryptoError::MalformedInput);
    }
    if reader.u8()? != 1 {
        return Err(CryptoError::UnsupportedVersion);
    }
    let sequence = reader.u64()?;
    let coarse_unix_day = reader.u32()?;
    let identity_version = reader.u32()?;
    let record_user = RawUuid::new(reader.array()?);
    let previous_hash: [u8; 32] = reader.array()?;
    let live_set_hash: [u8; 32] = reader.array()?;
    let signature = Ed25519Signature::new(reader.array()?);
    if record_user != expected_user || identity.user_id != expected_user {
        return Err(CryptoError::AuthenticationFailed);
    }
    let signed = encode_device_log_signature(
        &record_user,
        sequence,
        &previous_hash,
        &live_set_hash,
        identity_version,
        coarse_unix_day,
    )?;
    RustCryptoProvider::default().ed25519_verify(
        &identity.self_signing_public,
        &signed,
        signature.as_bytes(),
    )?;
    let hash = RustCryptoProvider::default().sha256(record)?;
    let mut inspection = Vec::with_capacity(DEVICE_LOG_INSPECTION_BYTES);
    push_u64(&mut inspection, sequence);
    inspection.extend_from_slice(&previous_hash);
    inspection.extend_from_slice(&hash);
    Ok(inspection)
}

/// Verifies one public peer-identity response over the exact served key bytes.
pub fn verify_published_identity(input: &[u8]) -> CryptoResult<()> {
    let mut reader = Reader::new(input);
    if reader.take(8)? != VERIFY_IDENTITY_MAGIC {
        return Err(CryptoError::MalformedInput);
    }
    let user_id = RawUuid::new(reader.array()?);
    let master_public: [u8; ED25519_PUBLIC_BYTES] = reader.array()?;
    let self_signing_public: [u8; ED25519_PUBLIC_BYTES] = reader.array()?;
    let user_signing_public: [u8; ED25519_PUBLIC_BYTES] = reader.array()?;
    let master_signature = Ed25519Signature::new(reader.array()?);
    if !reader.is_finished() {
        return Err(CryptoError::MalformedInput);
    }
    verify_master_signature(
        &RustCryptoProvider::default(),
        &CrossSigningIdentity {
            user_id,
            self_signing_public: &self_signing_public,
            user_signing_public: &user_signing_public,
        },
        &master_public,
        &master_signature,
    )
}

/// Verifies the complete claimed device bundle, including both signed prekeys.
pub fn verify_claimed_device_bundle(input: &[u8]) -> CryptoResult<()> {
    let mut reader = Reader::new(input);
    if reader.take(8)? != VERIFY_BUNDLE_MAGIC {
        return Err(CryptoError::MalformedInput);
    }
    let user_id = RawUuid::new(reader.array()?);
    let device_id = RawUuid::new(reader.array()?);
    let self_signing_public: [u8; ED25519_PUBLIC_BYTES] = reader.array()?;
    let ik_public = IkPublic::try_from_bytes(reader.take(64)?)?;
    let spk_id = reader.u32()?;
    let spk_public = reader.sized_bytes()?;
    let spk_signature = Ed25519Signature::new(reader.array()?);
    let pq_present = reader.u8()?;
    let pq = match pq_present {
        0 => None,
        1 => Some((
            reader.u32()?,
            reader.sized_bytes()?,
            Ed25519Signature::new(reader.array()?),
        )),
        _ => return Err(CryptoError::MalformedInput),
    };
    let registration_id = reader.u32()?;
    let bundle_version = reader.u32()?;
    let cross_signature = Ed25519Signature::new(reader.array()?);
    if !reader.is_finished()
        || spk_public.len() != X25519_PUBLIC_BYTES
        || pq
            .as_ref()
            .is_some_and(|(_, public, _)| public.len() != MLKEM768_PUBLIC_BYTES)
        || bundle_version == 0
    {
        return Err(CryptoError::MalformedInput);
    }
    let signed_prekey = SignedPrekey {
        user_id,
        prekey: PublicPrekey {
            id: spk_id,
            public: spk_public,
        },
    };
    verify_signed_prekey(
        &RustCryptoProvider::default(),
        &signed_prekey,
        &ik_public,
        &spk_signature,
    )?;
    if let Some((id, public, signature)) = pq.as_ref() {
        verify_pq_signed_prekey(
            &RustCryptoProvider::default(),
            &SignedPrekey {
                user_id,
                prekey: PublicPrekey { id: *id, public },
            },
            &ik_public,
            signature,
        )?;
    }
    let bundle = DeviceBundle {
        user_id,
        device_id,
        ik_public,
        spk_id,
        spk_public,
        pq_signed_prekey: pq
            .as_ref()
            .map(|(id, public, _)| PublicPrekey { id: *id, public }),
        registration_id,
        bundle_version,
    };
    verify_cross_signature(
        &RustCryptoProvider::default(),
        &bundle,
        &self_signing_public,
        &cross_signature,
    )
}

/// Verifies a peer log record with only the peer's authenticated public subkey.
pub fn inspect_peer_device_log_record(input: &[u8]) -> CryptoResult<Vec<u8>> {
    let mut reader = Reader::new(input);
    if reader.take(8)? != VERIFY_LOG_MAGIC {
        return Err(CryptoError::MalformedInput);
    }
    let expected_user = RawUuid::new(reader.array()?);
    let self_signing_public: [u8; ED25519_PUBLIC_BYTES] = reader.array()?;
    let verify_live_set = match reader.u8()? {
        0 => false,
        1 => true,
        _ => return Err(CryptoError::MalformedInput),
    };
    let device_count = usize::try_from(reader.u32()?)?;
    if device_count > 100 {
        return Err(CryptoError::ResourceExhausted);
    }
    let mut devices = Vec::with_capacity(device_count);
    for _ in 0..device_count {
        let device_id: [u8; 16] = reader.array()?;
        let ik_public: [u8; 64] = reader.array()?;
        let registration_id = reader.u32()?;
        let signature_present = reader.u8()?;
        let cross_signature = match signature_present {
            0 => None,
            1 => Some(reader.array()?),
            _ => return Err(CryptoError::MalformedInput),
        };
        let bundle_version = reader.u32()?;
        if (cross_signature.is_none() && bundle_version != 0)
            || (cross_signature.is_some() && bundle_version == 0)
        {
            return Err(CryptoError::MalformedInput);
        }
        devices.push((
            device_id,
            ik_public,
            registration_id,
            cross_signature,
            bundle_version,
        ));
    }
    let record = reader.remaining_bytes();
    if record.len() != DEVICE_LOG_BUCKET_BYTES {
        return Err(CryptoError::MalformedInput);
    }
    let expected_live_set_hash = if verify_live_set {
        Some(hash_canonical_live_set(&mut devices)?)
    } else {
        None
    };
    inspect_log_with_public(
        expected_user,
        &self_signing_public,
        expected_live_set_hash.as_ref(),
        record,
    )
}

/// Returns a symmetric SHA-256 commitment to both exact user/master-key pairs.
pub fn safety_fingerprint(input: &[u8]) -> CryptoResult<Vec<u8>> {
    let mut reader = Reader::new(input);
    if reader.take(8)? != SAFETY_MAGIC {
        return Err(CryptoError::MalformedInput);
    }
    let first_user: [u8; 16] = reader.array()?;
    let first_master: [u8; 32] = reader.array()?;
    let second_user: [u8; 16] = reader.array()?;
    let second_master: [u8; 32] = reader.array()?;
    if !reader.is_finished() {
        return Err(CryptoError::MalformedInput);
    }
    let (left_user, left_master, right_user, right_master) = if first_user <= second_user {
        (first_user, first_master, second_user, second_master)
    } else {
        (second_user, second_master, first_user, first_master)
    };
    let mut committed = Vec::with_capacity(SAFETY_FINGERPRINT_DOMAIN.len() + 112);
    committed.extend_from_slice(SAFETY_FINGERPRINT_DOMAIN);
    framed(&mut committed, &left_user)?;
    framed(&mut committed, &left_master)?;
    framed(&mut committed, &right_user)?;
    framed(&mut committed, &right_master)?;
    Ok(RustCryptoProvider::default().sha256(&committed)?.to_vec())
}

/// Signs a peer's exact master key after explicit out-of-band confirmation.
pub fn attest_peer_master(
    identity_package: &[u8],
    peer_user_id: &[u8],
    peer_master_public: &[u8],
) -> CryptoResult<Vec<u8>> {
    let identity = parse_identity_package(identity_package)?;
    let peer_user = raw_uuid(peer_user_id)?;
    let peer_master: [u8; ED25519_PUBLIC_BYTES] = fixed(peer_master_public)?;
    let signed = encode_user_attestation(&identity.user_id, &peer_user, &peer_master)?;
    let secret = SecretBytes::new(identity.secrets.user_signing);
    Ok(RustCryptoProvider::default()
        .ed25519_sign(&secret, &signed)?
        .to_vec())
}

/// Verifies a stored user-signing attestation before restoring verified state.
pub fn verify_user_attestation(input: &[u8]) -> CryptoResult<()> {
    let mut reader = Reader::new(input);
    if reader.take(8)? != VERIFY_ATTESTATION_MAGIC {
        return Err(CryptoError::MalformedInput);
    }
    let signer_user = RawUuid::new(reader.array()?);
    let signer_public: [u8; ED25519_PUBLIC_BYTES] = reader.array()?;
    let peer_user = RawUuid::new(reader.array()?);
    let peer_master: [u8; ED25519_PUBLIC_BYTES] = reader.array()?;
    let signature: [u8; ED25519_SIGNATURE_BYTES] = reader.array()?;
    if !reader.is_finished() {
        return Err(CryptoError::MalformedInput);
    }
    let signed = encode_user_attestation(&signer_user, &peer_user, &peer_master)?;
    RustCryptoProvider::default().ed25519_verify(&signer_public, &signed, &signature)
}

fn inspect_log_with_public(
    expected_user: RawUuid,
    self_signing_public: &[u8; ED25519_PUBLIC_BYTES],
    expected_live_set_hash: Option<&[u8; 32]>,
    record: &[u8],
) -> CryptoResult<Vec<u8>> {
    let mut reader = Reader::new(record);
    if reader.take(8)? != DEVICE_LOG_MAGIC || reader.u8()? != 1 {
        return Err(CryptoError::MalformedInput);
    }
    let sequence = reader.u64()?;
    let coarse_unix_day = reader.u32()?;
    let identity_version = reader.u32()?;
    let record_user = RawUuid::new(reader.array()?);
    let previous_hash: [u8; 32] = reader.array()?;
    let live_set_hash: [u8; 32] = reader.array()?;
    let signature: [u8; ED25519_SIGNATURE_BYTES] = reader.array()?;
    if record_user != expected_user
        || expected_live_set_hash.is_some_and(|expected| live_set_hash.ct_ne(expected).into())
    {
        return Err(CryptoError::AuthenticationFailed);
    }
    let signed = encode_device_log_signature(
        &record_user,
        sequence,
        &previous_hash,
        &live_set_hash,
        identity_version,
        coarse_unix_day,
    )?;
    let provider = RustCryptoProvider::default();
    provider.ed25519_verify(self_signing_public, &signed, &signature)?;
    let hash = provider.sha256(record)?;
    let mut inspection = Vec::with_capacity(PEER_DEVICE_LOG_INSPECTION_BYTES);
    push_u64(&mut inspection, sequence);
    inspection.extend_from_slice(&previous_hash);
    inspection.extend_from_slice(&hash);
    inspection.extend_from_slice(&live_set_hash);
    push_u32(&mut inspection, identity_version);
    Ok(inspection)
}

type PublicLogDevice = ([u8; 16], [u8; 64], u32, Option<[u8; 64]>, u32);

fn hash_canonical_live_set(devices: &mut [PublicLogDevice]) -> CryptoResult<[u8; 32]> {
    devices.sort_by_key(|device| device.0);
    let mut encoded = Vec::with_capacity(24 + devices.len() * 172);
    encoded.extend_from_slice(b"chat:v1:device-set");
    push_u32(&mut encoded, u32::try_from(devices.len())?);
    for (device_id, ik_public, registration_id, cross_signature, bundle_version) in devices {
        encoded.extend_from_slice(device_id);
        framed(&mut encoded, ik_public)?;
        push_u32(&mut encoded, *registration_id);
        framed(
            &mut encoded,
            cross_signature
                .as_ref()
                .map_or(&[][..], |signature| &signature[..]),
        )?;
        push_u32(&mut encoded, *bundle_version);
    }
    RustCryptoProvider::default().sha256(&encoded)
}

fn encode_user_attestation(
    signer_user: &RawUuid,
    peer_user: &RawUuid,
    peer_master: &[u8; ED25519_PUBLIC_BYTES],
) -> CryptoResult<Vec<u8>> {
    let mut encoded = Vec::with_capacity(USER_ATTESTATION_DOMAIN.len() + 76);
    encoded.extend_from_slice(USER_ATTESTATION_DOMAIN);
    framed(&mut encoded, signer_user.as_bytes())?;
    framed(&mut encoded, peer_user.as_bytes())?;
    framed(&mut encoded, peer_master)?;
    Ok(encoded)
}

fn encode_identity_package<P: CryptoProvider>(
    provider: &P,
    user_id: RawUuid,
    secrets: &IdentitySecrets,
    recovery_secret: &[u8],
    backup: &[u8],
) -> CryptoResult<Vec<u8>> {
    let master_public = SigningKey::from_bytes(&secrets.master)
        .verifying_key()
        .to_bytes();
    let self_signing_public = SigningKey::from_bytes(&secrets.self_signing)
        .verifying_key()
        .to_bytes();
    let user_signing_public = SigningKey::from_bytes(&secrets.user_signing)
        .verifying_key()
        .to_bytes();
    let master_bytes = encode_master_signature(&CrossSigningIdentity {
        user_id,
        self_signing_public: &self_signing_public,
        user_signing_public: &user_signing_public,
    })?;
    let master_secret = SecretBytes::new(secrets.master);
    let master_signature = provider.ed25519_sign(&master_secret, &master_bytes)?;
    let recovery_len = u16::try_from(recovery_secret.len())?;
    let backup_len = u32::try_from(backup.len())?;
    let mut package = Vec::with_capacity(
        8 + 1
            + 16
            + ED25519_PUBLIC_BYTES * 3
            + ED25519_SIGNATURE_BYTES
            + 2
            + 4
            + IDENTITY_PRIVATE_BYTES
            + recovery_secret.len()
            + backup.len(),
    );
    package.extend_from_slice(IDENTITY_PACKAGE_MAGIC);
    let flags = u8::from(!recovery_secret.is_empty()) | (u8::from(!backup.is_empty()) << 1);
    package.push(flags);
    package.extend_from_slice(user_id.as_bytes());
    package.extend_from_slice(&master_public);
    package.extend_from_slice(&self_signing_public);
    package.extend_from_slice(&user_signing_public);
    package.extend_from_slice(&master_signature);
    push_u16(&mut package, recovery_len);
    push_u32(&mut package, backup_len);
    package.extend_from_slice(&secrets.master);
    package.extend_from_slice(&secrets.self_signing);
    package.extend_from_slice(&secrets.user_signing);
    package.extend_from_slice(recovery_secret);
    package.extend_from_slice(backup);
    Ok(package)
}

fn parse_identity_package(package: &[u8]) -> CryptoResult<ParsedIdentityPackage<'_>> {
    let mut reader = Reader::new(package);
    if reader.take(8)? != IDENTITY_PACKAGE_MAGIC {
        return Err(CryptoError::MalformedInput);
    }
    let flags = reader.u8()?;
    if flags & !0b11 != 0 {
        return Err(CryptoError::MalformedInput);
    }
    let user_id = RawUuid::new(reader.array()?);
    let master_public = reader.array()?;
    let self_signing_public = reader.array()?;
    let user_signing_public = reader.array()?;
    let master_signature = reader.array()?;
    let recovery_len = usize::from(reader.u16()?);
    let backup_len = usize::try_from(reader.u32()?)?;
    let secrets = IdentitySecrets {
        master: reader.array()?,
        self_signing: reader.array()?,
        user_signing: reader.array()?,
    };
    let recovery_secret = reader.take(recovery_len)?;
    let backup = reader.take(backup_len)?;
    if !reader.is_finished()
        || ((flags & 1 != 0) == recovery_secret.is_empty())
        || ((flags & 2 != 0) == backup.is_empty())
        || SigningKey::from_bytes(&secrets.master)
            .verifying_key()
            .to_bytes()
            != master_public
        || SigningKey::from_bytes(&secrets.self_signing)
            .verifying_key()
            .to_bytes()
            != self_signing_public
        || SigningKey::from_bytes(&secrets.user_signing)
            .verifying_key()
            .to_bytes()
            != user_signing_public
    {
        return Err(CryptoError::MalformedInput);
    }
    let identity = CrossSigningIdentity {
        user_id,
        self_signing_public: &self_signing_public,
        user_signing_public: &user_signing_public,
    };
    let encoded = encode_master_signature(&identity)?;
    RustCryptoProvider::default().ed25519_verify(&master_public, &encoded, &master_signature)?;
    Ok(ParsedIdentityPackage {
        user_id,
        master_public,
        self_signing_public,
        master_signature,
        secrets,
        recovery_secret,
        backup,
    })
}

fn parse_device_package(package: &[u8]) -> CryptoResult<ParsedDevicePackage<'_>> {
    let mut reader = Reader::new(package);
    if reader.take(8)? != DEVICE_PACKAGE_MAGIC {
        return Err(CryptoError::MalformedInput);
    }
    let user_id = RawUuid::new(reader.array()?);
    let registration_id = reader.u32()?;
    let spk_id = reader.u32()?;
    let pq_spk_id = reader.u32()?;
    let classical_count = usize::from(reader.u16()?);
    let pq_count = usize::from(reader.u16()?);
    if classical_count == 0
        || classical_count > INITIAL_CLASSICAL_ONE_TIME_PREKEYS
        || pq_count == 0
        || pq_count > INITIAL_PQ_ONE_TIME_PREKEYS
    {
        return Err(CryptoError::MalformedInput);
    }
    let ik_public = IkPublic::try_from_bytes(reader.take(64)?)?;
    let spk_public = reader.array()?;
    let spk_signature: [u8; ED25519_SIGNATURE_BYTES] = reader.array()?;
    let pq_spk_public = reader.array()?;
    let pq_spk_signature: [u8; ED25519_SIGNATURE_BYTES] = reader.array()?;
    let fingerprint = reader.array()?;
    let public_variable_bytes = classical_count
        .checked_mul(4 + X25519_PUBLIC_BYTES)
        .and_then(|value| value.checked_add(pq_count * (4 + MLKEM768_PUBLIC_BYTES)))
        .ok_or(CryptoError::InputTooLarge)?;
    let private_bytes = ED25519_SECRET_BYTES
        + X25519_SECRET_BYTES
        + X25519_SECRET_BYTES
        + MLKEM768_SECRET_BYTES
        + classical_count * X25519_SECRET_BYTES
        + pq_count * MLKEM768_SECRET_BYTES;
    let remainder = reader.take(
        public_variable_bytes
            .checked_add(private_bytes)
            .ok_or(CryptoError::InputTooLarge)?,
    )?;
    if !reader.is_finished()
        || RustCryptoProvider::default().sha256(ik_public.as_bytes())? != fingerprint
    {
        return Err(CryptoError::MalformedInput);
    }
    let spk = SignedPrekey {
        user_id,
        prekey: PublicPrekey {
            id: spk_id,
            public: &spk_public,
        },
    };
    RustCryptoProvider::default().ed25519_verify(
        &ik_public.device_signing_public(),
        &encode_signed_prekey(&spk)?,
        &spk_signature,
    )?;
    let pq_spk = SignedPrekey {
        user_id,
        prekey: PublicPrekey {
            id: pq_spk_id,
            public: &pq_spk_public,
        },
    };
    RustCryptoProvider::default().ed25519_verify(
        &ik_public.device_signing_public(),
        &encode_pq_signed_prekey(&pq_spk)?,
        &pq_spk_signature,
    )?;
    Ok(ParsedDevicePackage {
        user_id,
        registration_id,
        spk_id,
        pq_spk_id,
        ik_public,
        spk_public,
        pq_spk_public,
        _remainder: remainder,
    })
}

fn encrypt_backup<P: CryptoProvider>(
    provider: &P,
    user_id: &RawUuid,
    secrets: &IdentitySecrets,
    recovery_secret: &[u8],
) -> CryptoResult<Vec<u8>> {
    let mut salt = [0u8; ARGON2_SALT_BYTES];
    let mut nonce = [0u8; XCHACHA_NONCE_BYTES];
    provider.random_bytes(&mut salt)?;
    provider.random_bytes(&mut nonce)?;
    let password = SecretVec::password(recovery_secret)?;
    let key = provider.argon2id(&password, &salt)?;

    let mut plaintext = Vec::with_capacity(IDENTITY_PLAINTEXT_BYTES);
    plaintext.extend_from_slice(IDENTITY_PLAINTEXT_MAGIC);
    plaintext.extend_from_slice(user_id.as_bytes());
    plaintext.extend_from_slice(&secrets.master);
    plaintext.extend_from_slice(&secrets.self_signing);
    plaintext.extend_from_slice(&secrets.user_signing);
    let plaintext = SecretVec::from_vec(plaintext, IDENTITY_PLAINTEXT_BYTES)?;
    let ciphertext_len = IDENTITY_PLAINTEXT_BYTES
        .checked_add(16)
        .ok_or(CryptoError::InputTooLarge)?;
    let header = backup_header(&salt, &nonce, u32::try_from(ciphertext_len)?);
    let aad = backup_aad(&header, user_id);
    let ciphertext = provider.xchacha20poly1305_encrypt(&key, &nonce, &plaintext, &aad)?;
    let mut backup = Vec::with_capacity(BACKUP_BUCKET_BYTES);
    backup.extend_from_slice(&header);
    backup.extend_from_slice(&ciphertext);
    let content_len = backup.len();
    backup.resize(BACKUP_BUCKET_BYTES, 0);
    provider.random_bytes(&mut backup[content_len..])?;
    Ok(backup)
}

fn decrypt_backup<P: CryptoProvider>(
    provider: &P,
    user_id: &RawUuid,
    recovery_secret: &[u8],
    backup: &[u8],
) -> CryptoResult<IdentitySecrets> {
    if !matches!(backup.len(), 4096 | 16_384 | 65_536 | 262_144 | 1_048_576) {
        return Err(CryptoError::MalformedInput);
    }
    let mut reader = Reader::new(backup);
    if reader.take(8)? != BACKUP_MAGIC {
        return Err(CryptoError::MalformedInput);
    }
    let memory = reader.u32()?;
    let iterations = reader.u32()?;
    let parallelism = reader.u32()?;
    if memory != BACKUP_MEMORY_KIB
        || iterations != BACKUP_ITERATIONS
        || parallelism != BACKUP_PARALLELISM
    {
        return Err(CryptoError::UnsupportedVersion);
    }
    let salt: [u8; ARGON2_SALT_BYTES] = reader.array()?;
    let nonce: [u8; XCHACHA_NONCE_BYTES] = reader.array()?;
    let ciphertext_len = usize::try_from(reader.u32()?)?;
    if ciphertext_len != IDENTITY_PLAINTEXT_BYTES + 16
        || BACKUP_HEADER_BYTES + ciphertext_len > backup.len()
    {
        return Err(CryptoError::MalformedInput);
    }
    let ciphertext = reader.take(ciphertext_len)?;
    let password = SecretVec::password(recovery_secret)?;
    let key = provider.argon2id(&password, &salt)?;
    let header = &backup[..BACKUP_HEADER_BYTES];
    let aad = backup_aad(header, user_id);
    let plaintext = provider.xchacha20poly1305_decrypt(&key, &nonce, ciphertext, &aad)?;
    let mut plaintext_reader = Reader::new(plaintext.expose());
    if plaintext_reader.take(8)? != IDENTITY_PLAINTEXT_MAGIC
        || plaintext_reader.take(16)? != user_id.as_bytes()
    {
        return Err(CryptoError::AuthenticationFailed);
    }
    let secrets = IdentitySecrets {
        master: plaintext_reader.array()?,
        self_signing: plaintext_reader.array()?,
        user_signing: plaintext_reader.array()?,
    };
    if !plaintext_reader.is_finished() {
        return Err(CryptoError::MalformedInput);
    }
    Ok(secrets)
}

fn backup_header(
    salt: &[u8; ARGON2_SALT_BYTES],
    nonce: &[u8; XCHACHA_NONCE_BYTES],
    ciphertext_len: u32,
) -> Vec<u8> {
    let mut header = Vec::with_capacity(BACKUP_HEADER_BYTES);
    header.extend_from_slice(BACKUP_MAGIC);
    push_u32(&mut header, BACKUP_MEMORY_KIB);
    push_u32(&mut header, BACKUP_ITERATIONS);
    push_u32(&mut header, BACKUP_PARALLELISM);
    header.extend_from_slice(salt);
    header.extend_from_slice(nonce);
    push_u32(&mut header, ciphertext_len);
    header
}

fn backup_aad(header: &[u8], user_id: &RawUuid) -> Vec<u8> {
    let mut aad = Vec::with_capacity(BACKUP_DOMAIN.len() + header.len() + 16);
    aad.extend_from_slice(BACKUP_DOMAIN);
    aad.extend_from_slice(header);
    aad.extend_from_slice(user_id.as_bytes());
    aad
}

fn encode_recovery_secret<P: CryptoProvider>(
    provider: &P,
    entropy: &[u8; RECOVERY_ENTROPY_BYTES],
) -> CryptoResult<String> {
    let digest = provider.sha256(entropy)?;
    let mut payload = [0u8; RECOVERY_PAYLOAD_BYTES];
    payload[..RECOVERY_ENTROPY_BYTES].copy_from_slice(entropy);
    payload[RECOVERY_ENTROPY_BYTES..].copy_from_slice(&digest[..RECOVERY_CHECKSUM_BYTES]);
    let encoded = crockford_encode(&payload);
    payload.zeroize();
    Ok(group_recovery_secret(&encoded))
}

fn normalize_recovery_secret<P: CryptoProvider>(
    provider: &P,
    input: &[u8],
) -> CryptoResult<String> {
    let input = std::str::from_utf8(input).map_err(|_| CryptoError::AuthenticationFailed)?;
    let compact: String = input
        .chars()
        .filter(|character| !character.is_ascii_whitespace() && *character != '-')
        .map(|character| character.to_ascii_uppercase())
        .collect();
    let mut payload = crockford_decode(&compact).map_err(|_| CryptoError::AuthenticationFailed)?;
    if payload.len() != RECOVERY_PAYLOAD_BYTES {
        payload.zeroize();
        return Err(CryptoError::AuthenticationFailed);
    }
    let digest = provider.sha256(&payload[..RECOVERY_ENTROPY_BYTES])?;
    let checksum_valid: bool = payload[RECOVERY_ENTROPY_BYTES..]
        .ct_eq(&digest[..RECOVERY_CHECKSUM_BYTES])
        .into();
    if !checksum_valid {
        payload.zeroize();
        return Err(CryptoError::AuthenticationFailed);
    }
    let canonical = group_recovery_secret(&crockford_encode(&payload));
    payload.zeroize();
    Ok(canonical)
}

fn crockford_encode(input: &[u8]) -> String {
    let mut output = String::with_capacity(input.len().div_ceil(5) * 8);
    let mut accumulator = 0u32;
    let mut bits = 0u8;
    for &byte in input {
        accumulator = (accumulator << 8) | u32::from(byte);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            let index = usize::try_from((accumulator >> bits) & 0x1f).unwrap_or(0);
            output.push(char::from(CROCKFORD_ALPHABET[index]));
        }
    }
    if bits > 0 {
        let index = usize::try_from((accumulator << (5 - bits)) & 0x1f).unwrap_or(0);
        output.push(char::from(CROCKFORD_ALPHABET[index]));
    }
    output
}

fn crockford_decode(input: &str) -> CryptoResult<Vec<u8>> {
    let mut output = Vec::with_capacity(input.len() * 5 / 8);
    let mut accumulator = 0u32;
    let mut bits = 0u8;
    for byte in input.bytes() {
        let value = crockford_value(byte).ok_or(CryptoError::MalformedInput)?;
        accumulator = (accumulator << 5) | u32::from(value);
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            output.push(u8::try_from((accumulator >> bits) & 0xff)?);
        }
    }
    if bits > 0 && accumulator & ((1u32 << bits) - 1) != 0 {
        output.zeroize();
        return Err(CryptoError::MalformedInput);
    }
    Ok(output)
}

fn crockford_value(byte: u8) -> Option<u8> {
    match byte {
        b'0' | b'O' => Some(0),
        b'1' | b'I' | b'L' => Some(1),
        b'2'..=b'9' => Some(byte - b'0'),
        b'A'..=b'H' => Some(byte - b'A' + 10),
        b'J'..=b'K' => Some(byte - b'J' + 18),
        b'M'..=b'N' => Some(byte - b'M' + 20),
        b'P'..=b'T' => Some(byte - b'P' + 22),
        b'V'..=b'Z' => Some(byte - b'V' + 27),
        _ => None,
    }
}

fn group_recovery_secret(compact: &str) -> String {
    compact
        .as_bytes()
        .chunks(5)
        .map(|chunk| std::str::from_utf8(chunk).unwrap_or_default())
        .collect::<Vec<_>>()
        .join("-")
}

fn encode_device_log_signature(
    user_id: &RawUuid,
    sequence: u64,
    previous_hash: &[u8; 32],
    live_set_hash: &[u8; 32],
    identity_version: u32,
    coarse_unix_day: u32,
) -> CryptoResult<Vec<u8>> {
    let mut encoded = Vec::with_capacity(DEVICE_LOG_DOMAIN.len() + 4 * 6 + 96);
    encoded.extend_from_slice(DEVICE_LOG_DOMAIN);
    framed(&mut encoded, user_id.as_bytes())?;
    framed(&mut encoded, &sequence.to_be_bytes())?;
    framed(&mut encoded, previous_hash)?;
    framed(&mut encoded, live_set_hash)?;
    framed(&mut encoded, &identity_version.to_be_bytes())?;
    framed(&mut encoded, &coarse_unix_day.to_be_bytes())?;
    Ok(encoded)
}

fn framed(output: &mut Vec<u8>, value: &[u8]) -> CryptoResult<()> {
    push_u32(output, u32::try_from(value.len())?);
    output.extend_from_slice(value);
    Ok(())
}

fn raw_uuid(value: &[u8]) -> CryptoResult<RawUuid> {
    Ok(RawUuid::new(fixed(value)?))
}

fn fixed<const LENGTH: usize>(value: &[u8]) -> CryptoResult<[u8; LENGTH]> {
    value.try_into().map_err(|_| CryptoError::MalformedInput)
}

fn push_u16(output: &mut Vec<u8>, value: u16) {
    output.extend_from_slice(&value.to_be_bytes());
}

fn push_u32(output: &mut Vec<u8>, value: u32) {
    output.extend_from_slice(&value.to_be_bytes());
}

fn push_u64(output: &mut Vec<u8>, value: u64) {
    output.extend_from_slice(&value.to_be_bytes());
}

struct Reader<'a> {
    input: &'a [u8],
    position: usize,
}

impl<'a> Reader<'a> {
    const fn new(input: &'a [u8]) -> Self {
        Self { input, position: 0 }
    }

    fn take(&mut self, length: usize) -> CryptoResult<&'a [u8]> {
        let end = self
            .position
            .checked_add(length)
            .ok_or(CryptoError::MalformedInput)?;
        let value = self
            .input
            .get(self.position..end)
            .ok_or(CryptoError::MalformedInput)?;
        self.position = end;
        Ok(value)
    }

    fn array<const LENGTH: usize>(&mut self) -> CryptoResult<[u8; LENGTH]> {
        fixed(self.take(LENGTH)?)
    }

    fn u8(&mut self) -> CryptoResult<u8> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> CryptoResult<u16> {
        Ok(u16::from_be_bytes(self.array()?))
    }

    fn u32(&mut self) -> CryptoResult<u32> {
        Ok(u32::from_be_bytes(self.array()?))
    }

    fn sized_bytes(&mut self) -> CryptoResult<&'a [u8]> {
        let length = usize::try_from(self.u32()?)?;
        self.take(length)
    }

    fn remaining_bytes(&mut self) -> &'a [u8] {
        let value = &self.input[self.position..];
        self.position = self.input.len();
        value
    }

    fn u64(&mut self) -> CryptoResult<u64> {
        Ok(u64::from_be_bytes(self.array()?))
    }

    const fn is_finished(&self) -> bool {
        self.position == self.input.len()
    }
}

impl From<std::num::TryFromIntError> for CryptoError {
    fn from(_: std::num::TryFromIntError) -> Self {
        Self::InputTooLarge
    }
}

#[cfg(test)]
mod tests {
    use super::{
        BACKUP_BUCKET_BYTES, BACKUP_HEADER_BYTES, BACKUP_ITERATIONS, BACKUP_MEMORY_KIB,
        BACKUP_PARALLELISM, DEVICE_LABEL_BUCKET_BYTES, DEVICE_LOG_BUCKET_BYTES,
        DEVICE_LOG_INSPECTION_BYTES, INITIAL_CLASSICAL_ONE_TIME_PREKEYS,
        INITIAL_PQ_ONE_TIME_PREKEYS, SAFETY_FINGERPRINT_BYTES, SAFETY_MAGIC,
        USER_ATTESTATION_DOMAIN, VERIFY_ATTESTATION_MAGIC, VERIFY_BUNDLE_MAGIC,
        VERIFY_IDENTITY_MAGIC, VERIFY_LOG_MAGIC, attest_peer_master,
        create_device_log_record_with_provider, cross_sign_device, inspect_device_log_record,
        inspect_peer_device_log_record, open_device_label, parse_device_package,
        parse_identity_package, prepare_device_with_provider, prepare_first_identity,
        prepare_first_identity_with_provider, restore_identity_with_provider,
        rotate_recovery_secret_with_provider, safety_fingerprint, sanitize_identity_package,
        seal_device_label, verify_claimed_device_bundle, verify_published_identity,
        verify_user_attestation,
    };
    use crate::{
        device_signatures::{
            DeviceBundle, Ed25519Signature, PublicPrekey, RawUuid, verify_cross_signature,
        },
        error::CryptoError,
        provider::RustCryptoProvider,
        random::FixedRandomProvider,
    };
    use ed25519_dalek::SigningKey;

    const USER_ID: [u8; 16] = [
        0x6f, 0x0c, 0x2f, 0x5e, 0x8a, 0x41, 0x4c, 0x9e, 0x9a, 0x34, 0x1f, 0x3d, 0x8f, 0x2b, 0x7c,
        0x10,
    ];
    const DEVICE_ID: [u8; 16] = [
        0x9f, 0x1c, 0x6a, 0x2e, 0x3b, 0x7d, 0x4e, 0x0f, 0x8c, 0x15, 0x2a, 0x77, 0xd4, 0xb9, 0xe6,
        0x11,
    ];

    fn deterministic_provider(bytes: usize) -> RustCryptoProvider<FixedRandomProvider> {
        let values = (0..bytes)
            .map(|index| u8::try_from(index % 251).unwrap())
            .collect();
        RustCryptoProvider::new(FixedRandomProvider::new(values))
    }

    #[test]
    fn device_package_contains_required_hybrid_material_and_cross_signs() {
        let device_provider = deterministic_provider(80_000);
        let device = prepare_device_with_provider(&device_provider, &USER_ID).unwrap();
        let parsed_device = parse_device_package(&device).unwrap();
        let identity_provider = deterministic_provider(8_000);
        let identity = prepare_first_identity_with_provider(&identity_provider, &USER_ID).unwrap();
        let signature = cross_sign_device(&device, &identity, &DEVICE_ID, 1).unwrap();
        let parsed_identity = parse_identity_package(&identity).unwrap();
        let bundle = DeviceBundle {
            user_id: RawUuid::new(USER_ID),
            device_id: RawUuid::new(DEVICE_ID),
            ik_public: parsed_device.ik_public,
            spk_id: parsed_device.spk_id,
            spk_public: &parsed_device.spk_public,
            pq_signed_prekey: Some(PublicPrekey {
                id: parsed_device.pq_spk_id,
                public: &parsed_device.pq_spk_public,
            }),
            registration_id: parsed_device.registration_id,
            bundle_version: 1,
        };
        verify_cross_signature(
            &RustCryptoProvider::default(),
            &bundle,
            &parsed_identity.self_signing_public,
            &Ed25519Signature::try_from_bytes(&signature).unwrap(),
        )
        .unwrap();
        assert!(device.len() > 10_000);
        assert_eq!(INITIAL_CLASSICAL_ONE_TIME_PREKEYS, 8);
        assert_eq!(INITIAL_PQ_ONE_TIME_PREKEYS, 4);
    }

    #[test]
    fn backup_round_trip_wrong_secret_and_tamper_are_fail_closed() {
        let provider = deterministic_provider(16_000);
        let prepared = prepare_first_identity_with_provider(&provider, &USER_ID).unwrap();
        let parsed = parse_identity_package(&prepared).unwrap();
        assert_eq!(parsed.backup.len(), BACKUP_BUCKET_BYTES);
        assert!(!parsed.recovery_secret.is_empty());
        assert_eq!(
            u32::from_be_bytes(parsed.backup[8..12].try_into().unwrap()),
            BACKUP_MEMORY_KIB
        );
        assert_eq!(
            u32::from_be_bytes(parsed.backup[12..16].try_into().unwrap()),
            BACKUP_ITERATIONS
        );
        assert_eq!(
            u32::from_be_bytes(parsed.backup[16..20].try_into().unwrap()),
            BACKUP_PARALLELISM
        );

        let restored = restore_identity_with_provider(
            &RustCryptoProvider::default(),
            &USER_ID,
            parsed.recovery_secret,
            parsed.backup,
        )
        .unwrap();
        let restored = parse_identity_package(&restored).unwrap();
        assert_eq!(restored.master_public, parsed.master_public);
        assert_eq!(restored.self_signing_public, parsed.self_signing_public);
        assert!(restored.recovery_secret.is_empty());
        assert!(restored.backup.is_empty());

        let wrong = restore_identity_with_provider(
            &RustCryptoProvider::default(),
            &USER_ID,
            b"00000-00000-00000-00000-00000-00000-00000-00000-00000-00000-00000",
            parsed.backup,
        );
        assert_eq!(wrong.unwrap_err(), CryptoError::AuthenticationFailed);

        let mut tampered = parsed.backup.to_vec();
        tampered[BACKUP_HEADER_BYTES + 3] ^= 1;
        let tampered_result = restore_identity_with_provider(
            &RustCryptoProvider::default(),
            &USER_ID,
            parsed.recovery_secret,
            &tampered,
        );
        assert_eq!(
            tampered_result.unwrap_err(),
            CryptoError::AuthenticationFailed
        );
    }

    #[test]
    fn sanitizing_removes_one_time_display_material_but_keeps_signing_identity() {
        let provider = deterministic_provider(16_000);
        let prepared = prepare_first_identity_with_provider(&provider, &USER_ID).unwrap();
        let before = parse_identity_package(&prepared).unwrap();
        let sanitized = sanitize_identity_package(&prepared).unwrap();
        let after = parse_identity_package(&sanitized).unwrap();
        assert!(after.recovery_secret.is_empty());
        assert!(after.backup.is_empty());
        assert_eq!(after.master_public, before.master_public);
        assert_eq!(after.master_signature, before.master_signature);
        assert!(sanitized.len() < prepared.len());
    }

    #[test]
    fn rotating_the_recovery_secret_keeps_the_identity_and_retires_the_old_secret() {
        // The whole point of replacement: the account keeps the master key its
        // peers attested and its devices are cross-signed by, and only the
        // wrapping changes. A rotation that produced a new identity would
        // silently un-verify every contact.
        let provider = deterministic_provider(24_000);
        let prepared = prepare_first_identity_with_provider(&provider, &USER_ID).unwrap();
        let before = parse_identity_package(&prepared).unwrap();

        let rotated = rotate_recovery_secret_with_provider(&provider, &prepared).unwrap();
        let after = parse_identity_package(&rotated).unwrap();

        assert_eq!(after.master_public, before.master_public);
        assert_eq!(after.self_signing_public, before.self_signing_public);
        assert_eq!(after.master_signature, before.master_signature);
        assert_eq!(after.backup.len(), BACKUP_BUCKET_BYTES);
        assert_ne!(after.recovery_secret, before.recovery_secret);
        assert_ne!(after.backup, before.backup);

        // The new secret opens the new backup, and recovers the same keys.
        let restored = restore_identity_with_provider(
            &RustCryptoProvider::default(),
            &USER_ID,
            after.recovery_secret,
            after.backup,
        )
        .unwrap();
        let restored = parse_identity_package(&restored).unwrap();
        assert_eq!(restored.master_public, before.master_public);
        assert_eq!(restored.self_signing_public, before.self_signing_public);

        // And the retired one does not, which is what "invalidates the old
        // secret" means once the server has taken the higher version.
        let stale = restore_identity_with_provider(
            &RustCryptoProvider::default(),
            &USER_ID,
            before.recovery_secret,
            after.backup,
        );
        assert_eq!(stale.unwrap_err(), CryptoError::AuthenticationFailed);
    }

    #[test]
    fn rotation_refuses_a_package_with_no_identity_in_it() {
        let provider = deterministic_provider(24_000);
        let prepared = prepare_first_identity_with_provider(&provider, &USER_ID).unwrap();
        let mut malformed = prepared.clone();
        malformed[0] ^= 0xff;
        assert_eq!(
            rotate_recovery_secret_with_provider(&provider, &malformed).unwrap_err(),
            CryptoError::MalformedInput
        );
        assert_eq!(
            rotate_recovery_secret_with_provider(&provider, &[]).unwrap_err(),
            CryptoError::MalformedInput
        );

        // A package whose user id no longer matches the signature it carries is
        // refused before any new secret exists, so a substituted identity can
        // never be handed a fresh backup to be recovered from.
        let mut substituted = prepared.clone();
        substituted[9] ^= 0xff;
        assert_eq!(
            rotate_recovery_secret_with_provider(&provider, &substituted).unwrap_err(),
            CryptoError::AuthenticationFailed
        );

        // A sanitized package still carries the private identity, so it is the
        // ordinary input: a signed-in device holds exactly that and nothing
        // else once enrollment has finished.
        let sanitized = sanitize_identity_package(&prepared).unwrap();
        let rotated = rotate_recovery_secret_with_provider(&provider, &sanitized).unwrap();
        let after = parse_identity_package(&rotated).unwrap();
        assert!(!after.recovery_secret.is_empty());
        assert_eq!(after.backup.len(), BACKUP_BUCKET_BYTES);
    }

    #[test]
    fn signed_log_records_chain_and_reject_mutation() {
        let provider = deterministic_provider(16_000);
        let identity = prepare_first_identity_with_provider(&provider, &USER_ID).unwrap();
        let log_provider = deterministic_provider(512);
        let first = create_device_log_record_with_provider(
            &log_provider,
            &identity,
            &USER_ID,
            0,
            &[],
            b"canonical-live-set",
            1,
            20_302,
        )
        .unwrap();
        assert_eq!(first.len(), DEVICE_LOG_BUCKET_BYTES);
        let inspection = inspect_device_log_record(&identity, &USER_ID, &first).unwrap();
        assert_eq!(inspection.len(), DEVICE_LOG_INSPECTION_BYTES);
        assert_eq!(u64::from_be_bytes(inspection[..8].try_into().unwrap()), 0);
        assert_eq!(&inspection[8..40], &[0; 32]);

        let mut mutated = first;
        mutated[80] ^= 1;
        assert_eq!(
            inspect_device_log_record(&identity, &USER_ID, &mutated).unwrap_err(),
            CryptoError::AuthenticationFailed
        );
    }

    #[test]
    fn peer_identity_and_attestation_bind_the_exact_master_key() {
        let provider = deterministic_provider(16_000);
        let identity = prepare_first_identity_with_provider(&provider, &USER_ID).unwrap();
        let parsed = parse_identity_package(&identity).unwrap();
        let user_signing_public = SigningKey::from_bytes(&parsed.secrets.user_signing)
            .verifying_key()
            .to_bytes();
        let mut published = Vec::new();
        published.extend_from_slice(VERIFY_IDENTITY_MAGIC);
        published.extend_from_slice(&USER_ID);
        published.extend_from_slice(&parsed.master_public);
        published.extend_from_slice(&parsed.self_signing_public);
        published.extend_from_slice(&user_signing_public);
        published.extend_from_slice(&parsed.master_signature);
        verify_published_identity(&published).unwrap();

        let mut substituted = published.clone();
        substituted[8 + 16 + 32] ^= 1;
        assert_eq!(
            verify_published_identity(&substituted).unwrap_err(),
            CryptoError::AuthenticationFailed
        );

        let peer_user = DEVICE_ID;
        let peer_master = [91; 32];
        let signature = attest_peer_master(&identity, &peer_user, &peer_master).unwrap();
        let mut attestation = Vec::new();
        attestation.extend_from_slice(VERIFY_ATTESTATION_MAGIC);
        attestation.extend_from_slice(&USER_ID);
        attestation.extend_from_slice(&user_signing_public);
        attestation.extend_from_slice(&peer_user);
        attestation.extend_from_slice(&peer_master);
        attestation.extend_from_slice(&signature);
        verify_user_attestation(&attestation).unwrap();
        attestation[8 + 16 + 32 + 16] ^= 1;
        assert_eq!(
            verify_user_attestation(&attestation).unwrap_err(),
            CryptoError::AuthenticationFailed
        );
        assert_eq!(USER_ATTESTATION_DOMAIN, b"chat:v1:user-signing-attestation");
    }

    #[test]
    fn safety_fingerprint_is_symmetric_and_changes_with_either_master_key() {
        fn request(
            first_user: &[u8; 16],
            first_master: &[u8; 32],
            second_user: &[u8; 16],
            second_master: &[u8; 32],
        ) -> Vec<u8> {
            let mut value = Vec::new();
            value.extend_from_slice(SAFETY_MAGIC);
            value.extend_from_slice(first_user);
            value.extend_from_slice(first_master);
            value.extend_from_slice(second_user);
            value.extend_from_slice(second_master);
            value
        }

        let local_master = [31; 32];
        let peer_master = [47; 32];
        let forward =
            safety_fingerprint(&request(&USER_ID, &local_master, &DEVICE_ID, &peer_master))
                .unwrap();
        let reverse =
            safety_fingerprint(&request(&DEVICE_ID, &peer_master, &USER_ID, &local_master))
                .unwrap();
        assert_eq!(forward.len(), SAFETY_FINGERPRINT_BYTES);
        assert_eq!(forward, reverse);
        let changed =
            safety_fingerprint(&request(&USER_ID, &[32; 32], &DEVICE_ID, &peer_master)).unwrap();
        assert_ne!(forward, changed);
    }

    #[test]
    fn claimed_bundle_and_public_log_reject_server_substitution() {
        let device_provider = deterministic_provider(80_000);
        let device = prepare_device_with_provider(&device_provider, &USER_ID).unwrap();
        let parsed_device = parse_device_package(&device).unwrap();
        let identity_provider = deterministic_provider(16_000);
        let identity = prepare_first_identity_with_provider(&identity_provider, &USER_ID).unwrap();
        let parsed_identity = parse_identity_package(&identity).unwrap();
        let cross_signature = cross_sign_device(&device, &identity, &DEVICE_ID, 1).unwrap();

        let mut device_reader = super::Reader::new(&device);
        device_reader.take(8).unwrap();
        device_reader.take(16 + 4 + 4 + 4 + 2 + 2).unwrap();
        let ik_public = device_reader.take(64).unwrap();
        let spk_public = device_reader.take(32).unwrap();
        let spk_signature = device_reader.take(64).unwrap();
        let pq_public = device_reader.take(1184).unwrap();
        let pq_signature = device_reader.take(64).unwrap();

        let mut bundle = Vec::new();
        bundle.extend_from_slice(VERIFY_BUNDLE_MAGIC);
        bundle.extend_from_slice(&USER_ID);
        bundle.extend_from_slice(&DEVICE_ID);
        bundle.extend_from_slice(&parsed_identity.self_signing_public);
        bundle.extend_from_slice(ik_public);
        super::push_u32(&mut bundle, parsed_device.spk_id);
        super::push_u32(&mut bundle, u32::try_from(spk_public.len()).unwrap());
        bundle.extend_from_slice(spk_public);
        bundle.extend_from_slice(spk_signature);
        bundle.push(1);
        super::push_u32(&mut bundle, parsed_device.pq_spk_id);
        super::push_u32(&mut bundle, u32::try_from(pq_public.len()).unwrap());
        bundle.extend_from_slice(pq_public);
        bundle.extend_from_slice(pq_signature);
        super::push_u32(&mut bundle, parsed_device.registration_id);
        super::push_u32(&mut bundle, 1);
        bundle.extend_from_slice(&cross_signature);
        verify_claimed_device_bundle(&bundle).unwrap();
        let mut substituted = bundle.clone();
        substituted[8 + 16 + 16 + 32 + 10] ^= 1;
        assert!(verify_claimed_device_bundle(&substituted).is_err());

        let mut canonical_live_set = Vec::new();
        canonical_live_set.extend_from_slice(b"chat:v1:device-set");
        super::push_u32(&mut canonical_live_set, 1);
        canonical_live_set.extend_from_slice(&DEVICE_ID);
        super::framed(&mut canonical_live_set, ik_public).unwrap();
        super::push_u32(&mut canonical_live_set, parsed_device.registration_id);
        super::framed(&mut canonical_live_set, &cross_signature).unwrap();
        super::push_u32(&mut canonical_live_set, 1);
        let log = create_device_log_record_with_provider(
            &deterministic_provider(512),
            &identity,
            &USER_ID,
            0,
            &[],
            &canonical_live_set,
            1,
            20_302,
        )
        .unwrap();
        let mut log_request = Vec::new();
        log_request.extend_from_slice(VERIFY_LOG_MAGIC);
        log_request.extend_from_slice(&USER_ID);
        log_request.extend_from_slice(&parsed_identity.self_signing_public);
        log_request.push(1);
        super::push_u32(&mut log_request, 1);
        log_request.extend_from_slice(&DEVICE_ID);
        log_request.extend_from_slice(ik_public);
        super::push_u32(&mut log_request, parsed_device.registration_id);
        log_request.push(1);
        log_request.extend_from_slice(&cross_signature);
        super::push_u32(&mut log_request, 1);
        log_request.extend_from_slice(&log);
        inspect_peer_device_log_record(&log_request).unwrap();
        log_request[8 + 16 + 32 + 1 + 4 + 16 + 5] ^= 1;
        assert_eq!(
            inspect_peer_device_log_record(&log_request).unwrap_err(),
            CryptoError::AuthenticationFailed
        );
    }

    #[test]
    fn device_labels_are_account_private_device_bound_and_tamper_evident() {
        let identity = prepare_first_identity(&USER_ID).unwrap();
        let label = "Laptop – تهران".as_bytes();
        let sealed = seal_device_label(&identity, &USER_ID, &DEVICE_ID, label).unwrap();
        assert_eq!(sealed.len(), DEVICE_LABEL_BUCKET_BYTES);
        assert_eq!(
            open_device_label(&identity, &USER_ID, &DEVICE_ID, &sealed).unwrap(),
            label
        );

        let mut wrong_device = DEVICE_ID;
        wrong_device[15] ^= 1;
        assert!(open_device_label(&identity, &USER_ID, &wrong_device, &sealed).is_err());

        let mut tampered = sealed;
        tampered[50] ^= 1;
        assert!(open_device_label(&identity, &USER_ID, &DEVICE_ID, &tampered).is_err());
    }
}
