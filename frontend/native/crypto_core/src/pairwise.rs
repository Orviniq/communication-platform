//! Version-1 hybrid PQXDH and X25519 Double Ratchet transport.
//!
//! The byte profile is frozen by `docs/pairwise-transport-v1.md`. The public C
//! ABI exposes this module only through one bounded operation multiplexer.

#![allow(
    clippy::if_not_else,
    clippy::items_after_statements,
    clippy::large_enum_variant,
    clippy::large_types_passed_by_value,
    clippy::missing_errors_doc,
    clippy::redundant_closure_for_method_calls,
    clippy::single_match_else,
    clippy::too_many_arguments,
    clippy::too_many_lines,
    reason = "The frozen wire/state-machine code keeps security-relevant fields and branches adjacent for review; the C ABI exposes the shared payload-free CryptoError contract."
)]

use std::cmp::Ordering;

use subtle::ConstantTimeEq;
use zeroize::{Zeroize, Zeroizing};

use crate::{
    enrollment,
    error::{CryptoError, CryptoResult},
    group_control,
    prekey_state::{
        DeviceState, KEY_ID_MAX, commit_pending_upload, decode_device_state, encode_device_state,
        prepare_replenishment, prepare_rotation,
    },
    protocol::{Reader, hkdf_sha256, hmac_sha256, push_frame, push_u16, push_u32, reserve},
    provider::{
        CryptoProvider, ED25519_SIGNATURE_BYTES, MLKEM768_CIPHERTEXT_BYTES, MLKEM768_PUBLIC_BYTES,
        RustCryptoProvider, X25519_PUBLIC_BYTES, X25519_SECRET_BYTES, XCHACHA_ABYTES,
    },
    secret::{SecretBytes, SecretVec},
};

pub(crate) const OP_UPGRADE_DEVICE_STATE: u32 = 1;
pub(crate) const OP_PREPARE_REPLENISHMENT: u32 = 2;
pub(crate) const OP_COMMIT_PREKEY_UPLOAD: u32 = 3;
pub(crate) const OP_PREPARE_ROTATION: u32 = 4;
pub(crate) const OP_PRUNE_RETIRED: u32 = 5;
pub(crate) const OP_INITIATE: u32 = 10;
pub(crate) const OP_PROBE_INITIAL: u32 = 11;
pub(crate) const OP_ACCEPT_INITIAL: u32 = 12;
pub(crate) const OP_ENCRYPT: u32 = 13;
pub(crate) const OP_DECRYPT: u32 = 14;
pub(crate) const OP_CREATE_REPAIR: u32 = 15;
pub(crate) const OP_CONSUME_REPAIR: u32 = 16;
pub(crate) const OP_INSPECT_PUBLIC_HEADER: u32 = 17;
pub(crate) const OP_SEAL_GROUP_CONTROL: u32 = 18;
pub(crate) const OP_OPEN_GROUP_CONTROL: u32 = 19;
pub(crate) const PAIRWISE_MAX_IO_BYTES: usize = 2 * 1024 * 1024;

const REQUEST_MAGIC: &[u8; 8] = b"CPPWR001";
const OUTPUT_MAGIC: &[u8; 8] = b"CPPWO001";
const STATE_MAGIC: &[u8; 8] = b"CPRSV001";
const REPAIR_CONTROL_MAGIC: &[u8; 8] = b"CPRRV001";
const REPAIR_AUTH_MAGIC: &[u8; 8] = b"CPRAV001";
const PROBE_MAGIC: &[u8; 8] = b"CPPBV001";
const VERIFY_BUNDLE_MAGIC: &[u8; 8] = b"CPBRV001";
const SENDER_PROJECTION_MAGIC: &[u8; 8] = b"CPSAV001";

const PROTOCOL_VERSION: u8 = 1;
const SUITE: u8 = 1;
const HEADER_VERSION: u8 = 1;
const FLAG_INITIAL: u8 = 0x01;
const FLAG_CLASSICAL_ONE_TIME: u8 = 0x02;
const FLAG_PQ_ONE_TIME: u8 = 0x04;
const FLAG_REPAIR_REPLACEMENT: u8 = 0x08;
const KNOWN_HEADER_FLAGS: u8 =
    FLAG_INITIAL | FLAG_CLASSICAL_ONE_TIME | FLAG_PQ_ONE_TIME | FLAG_REPAIR_REPLACEMENT;
const ABSENT_PREKEY_ID: u32 = 0xffff_ffff;
const PURPOSE: &[u8] = b"pairwise-transport-v1";
const PQXDH_DOMAIN: &[u8] = b"chat:v1:pqxdh-x25519-mlkem768-sha256";
const SEALED_SENDER_DOMAIN: &[u8] = b"chat:v1:pqxdh-sealed-sender";
const INIT_AUTH_DOMAIN: &[u8] = b"chat:v1:pqxdh-init-auth";
const ROOT_DOMAIN: &[u8] = b"chat:v1:double-ratchet-root";
const AEAD_DOMAIN: &[u8] = b"chat:v1:double-ratchet-aead";
const STATE_AUTH_DOMAIN: &[u8] = b"chat:v1:pairwise-state-auth";
const REPAIR_DOMAIN: &[u8] = b"chat:v1:session-repair";

const SESSION_ID_BYTES: usize = 16;
const STATE_AUTH_TAG_BYTES: usize = 32;
const REGULAR_HEADER_BYTES: usize = 58;
const MAX_SKIPPED_PER_SESSION: usize = 2_000;
const MAX_SKIPPED_ACCOUNT: usize = 20_000;
const SENDER_BLOCK_WITHOUT_REPAIR_BYTES: usize = 170;
const SENDER_BLOCK_REPAIR_BYTES: usize = 218;
const REPAIR_CONTROL_BYTES: usize = 58;
const REPAIR_REASON_SKIPPED_LIMIT: u8 = 1;
const ALLOWED_BUCKETS: [usize; 5] = [1_024, 4_096, 16_384, 65_536, 262_144];

const OUTCOME_OK: u8 = 0;
const OUTCOME_REPAIR_REQUIRED: u8 = 1;
const ENVELOPE_KIND_REGULAR: u8 = 0;
const ENVELOPE_KIND_INITIAL: u8 = 1;

#[derive(Clone, Copy)]
struct OptionalClassicalPrekey {
    id: u32,
    public: [u8; X25519_PUBLIC_BYTES],
}

#[derive(Clone, Copy)]
struct OptionalPqPrekey {
    id: u32,
    public: [u8; MLKEM768_PUBLIC_BYTES],
}

struct PeerBundle {
    device_id: [u8; 16],
    ik_public: [u8; 64],
    signed_prekey_id: u32,
    signed_prekey_public: [u8; X25519_PUBLIC_BYTES],
    pq_signed_prekey_id: u32,
    pq_signed_prekey_public: [u8; MLKEM768_PUBLIC_BYTES],
}

impl PeerBundle {
    fn parse(input: &[u8]) -> CryptoResult<Self> {
        // Re-run every signature and cross-signature verification before using
        // any claimed key material.
        enrollment::verify_claimed_device_bundle(input)?;
        let mut reader = Reader::new(input);
        if reader.take(8)? != VERIFY_BUNDLE_MAGIC {
            return Err(CryptoError::MalformedInput);
        }
        let user_id: [u8; 16] = reader.array()?;
        let device_id = reader.array()?;
        let _self_signing_public = reader.take(32)?;
        let ik_public = reader.array()?;
        let signed_prekey_id = valid_key_id(reader.u32()?)?;
        let signed_prekey_public = fixed(reader.framed()?)?;
        let _signed_prekey_signature = reader.take(ED25519_SIGNATURE_BYTES)?;
        if !reader.boolean()? {
            // The generic verifier remains backward compatible with the
            // backend's classical fixture; pairwise setup never does.
            return Err(CryptoError::AuthenticationFailed);
        }
        let pq_signed_prekey_id = valid_key_id(reader.u32()?)?;
        let pq_signed_prekey_public = fixed(reader.framed()?)?;
        let _pq_signature = reader.take(ED25519_SIGNATURE_BYTES)?;
        let _registration_id = reader.u32()?;
        let bundle_version = reader.u32()?;
        let _cross_signature = reader.take(ED25519_SIGNATURE_BYTES)?;
        if !reader.is_finished() || is_zero(&user_id) || is_zero(&device_id) || bundle_version == 0
        {
            return Err(CryptoError::MalformedInput);
        }
        Ok(Self {
            device_id,
            ik_public,
            signed_prekey_id,
            signed_prekey_public,
            pq_signed_prekey_id,
            pq_signed_prekey_public,
        })
    }

    fn identity_public(&self) -> [u8; 32] {
        self.ik_public[32..].try_into().expect("fixed slice")
    }
}

struct AuthenticatedSenderProjection {
    user_id: [u8; 16],
    device_id: [u8; 16],
    ik_public: [u8; 64],
    registration_id: u32,
    bundle_version: u32,
}

impl AuthenticatedSenderProjection {
    fn parse(input: &[u8]) -> CryptoResult<Self> {
        let mut reader = Reader::new(input);
        if reader.take(8)? != SENDER_PROJECTION_MAGIC {
            return Err(CryptoError::MalformedInput);
        }
        let value = Self {
            user_id: reader.array()?,
            device_id: reader.array()?,
            ik_public: reader.array()?,
            registration_id: reader.u32()?,
            bundle_version: reader.u32()?,
        };
        if !reader.is_finished()
            || is_zero(&value.user_id)
            || is_zero(&value.device_id)
            || value.bundle_version == 0
        {
            return Err(CryptoError::MalformedInput);
        }
        Ok(value)
    }

    fn device_signing_public(&self) -> [u8; 32] {
        self.ik_public[..32].try_into().expect("fixed slice")
    }

    fn identity_public(&self) -> [u8; 32] {
        self.ik_public[32..].try_into().expect("fixed slice")
    }
}

struct InitialHeader {
    flags: u8,
    session_id: [u8; SESSION_ID_BYTES],
    ratchet_public: [u8; X25519_PUBLIC_BYTES],
    signed_prekey_id: u32,
    one_time_prekey_id: u32,
    pq_signed_prekey_id: u32,
    pq_one_time_prekey_id: u32,
    ephemeral_public: [u8; X25519_PUBLIC_BYTES],
    pq_signed_ciphertext: [u8; MLKEM768_CIPHERTEXT_BYTES],
    pq_one_time_ciphertext: Option<[u8; MLKEM768_CIPHERTEXT_BYTES]>,
    sender_seal: Vec<u8>,
}

struct RegularHeader {
    session_id: [u8; SESSION_ID_BYTES],
    ratchet_public: [u8; X25519_PUBLIC_BYTES],
    previous_chain_length: u32,
    message_number: u32,
}

enum RatchetHeader {
    Initial(InitialHeader),
    Regular(RegularHeader),
}

impl RatchetHeader {
    fn parse(encoded: &[u8]) -> CryptoResult<Self> {
        let mut reader = Reader::new(encoded);
        if reader.u8()? != HEADER_VERSION {
            return Err(CryptoError::UnsupportedVersion);
        }
        let flags = reader.u8()?;
        if flags & !KNOWN_HEADER_FLAGS != 0 {
            return Err(CryptoError::MalformedInput);
        }
        let session_id = reader.array()?;
        if is_zero(&session_id) {
            return Err(CryptoError::MalformedInput);
        }
        let ratchet_public = reader.array()?;
        let previous_chain_length = reader.u32()?;
        let message_number = reader.u32()?;
        if flags == 0 {
            if !reader.is_finished() {
                return Err(CryptoError::MalformedInput);
            }
            return Ok(Self::Regular(RegularHeader {
                session_id,
                ratchet_public,
                previous_chain_length,
                message_number,
            }));
        }
        if flags & FLAG_INITIAL == 0 {
            return Err(CryptoError::MalformedInput);
        }
        let signed_prekey_id = valid_key_id(reader.u32()?)?;
        let one_time_prekey_id = reader.u32()?;
        let pq_signed_prekey_id = valid_key_id(reader.u32()?)?;
        let pq_one_time_prekey_id = reader.u32()?;
        validate_optional_id(flags & FLAG_CLASSICAL_ONE_TIME != 0, one_time_prekey_id)?;
        validate_optional_id(flags & FLAG_PQ_ONE_TIME != 0, pq_one_time_prekey_id)?;
        if flags & FLAG_REPAIR_REPLACEMENT != 0 && flags & FLAG_INITIAL == 0 {
            return Err(CryptoError::MalformedInput);
        }
        let ephemeral_public = reader.array()?;
        let pq_signed_ciphertext = reader.array()?;
        let pq_one_time_ciphertext = if flags & FLAG_PQ_ONE_TIME != 0 {
            Some(reader.array()?)
        } else {
            None
        };
        let sender_seal_length = usize::from(reader.u16()?);
        let sender_seal = reader.take(sender_seal_length)?.to_vec();
        if !reader.is_finished()
            || previous_chain_length != 0
            || message_number != 0
            || sender_seal_length
                != if flags & FLAG_REPAIR_REPLACEMENT != 0 {
                    SENDER_BLOCK_REPAIR_BYTES + XCHACHA_ABYTES
                } else {
                    SENDER_BLOCK_WITHOUT_REPAIR_BYTES + XCHACHA_ABYTES
                }
        {
            return Err(CryptoError::MalformedInput);
        }
        Ok(Self::Initial(InitialHeader {
            flags,
            session_id,
            ratchet_public,
            signed_prekey_id,
            one_time_prekey_id,
            pq_signed_prekey_id,
            pq_one_time_prekey_id,
            ephemeral_public,
            pq_signed_ciphertext,
            pq_one_time_ciphertext,
            sender_seal,
        }))
    }
}

struct Envelope<'a> {
    header_bytes: &'a [u8],
    header: RatchetHeader,
    ciphertext: &'a [u8],
}

impl<'a> Envelope<'a> {
    fn parse(input: &'a [u8]) -> CryptoResult<Self> {
        if !ALLOWED_BUCKETS.contains(&input.len()) {
            return Err(CryptoError::MalformedInput);
        }
        let mut reader = Reader::new(input);
        if reader.u8()? != PROTOCOL_VERSION || reader.u8()? != SUITE {
            return Err(CryptoError::UnsupportedVersion);
        }
        let header_len = usize::from(reader.u16()?);
        if header_len < REGULAR_HEADER_BYTES
            || header_len
                .checked_add(4 + XCHACHA_ABYTES + 4)
                .is_none_or(|minimum| minimum > input.len())
        {
            return Err(CryptoError::MalformedInput);
        }
        let header_bytes = reader.take(header_len)?;
        let ciphertext = reader.take(input.len() - reader.position())?;
        let header = RatchetHeader::parse(header_bytes)?;
        Ok(Self {
            header_bytes,
            header,
            ciphertext,
        })
    }
}

fn inspect_public_header(input: &[u8]) -> CryptoResult<(u8, [u8; SESSION_ID_BYTES])> {
    let envelope = Envelope::parse(input)?;
    Ok(match envelope.header {
        RatchetHeader::Initial(header) => (ENVELOPE_KIND_INITIAL, header.session_id),
        RatchetHeader::Regular(header) => (ENVELOPE_KIND_REGULAR, header.session_id),
    })
}

struct SkippedKey {
    ratchet_public: [u8; 32],
    message_number: u32,
    message_key: [u8; 32],
}

impl Drop for SkippedKey {
    fn drop(&mut self) {
        self.message_key.zeroize();
    }
}

struct RatchetState {
    session_id: [u8; 16],
    local_device_id: [u8; 16],
    remote_device_id: [u8; 16],
    initiator_device_id: [u8; 16],
    transcript_hash: [u8; 32],
    primary: bool,
    receive_only: bool,
    root_key: [u8; 32],
    sending_chain: Option<[u8; 32]>,
    receiving_chain: Option<[u8; 32]>,
    local_ratchet_secret: [u8; 32],
    local_ratchet_public: [u8; 32],
    remote_ratchet_public: [u8; 32],
    send_count: u32,
    receive_count: u32,
    previous_send_count: u32,
    skipped: Vec<SkippedKey>,
    issued_repair_token: Option<[u8; 32]>,
    received_repair_token: Option<[u8; 32]>,
}

impl Drop for RatchetState {
    fn drop(&mut self) {
        self.root_key.zeroize();
        if let Some(chain) = self.sending_chain.as_mut() {
            chain.zeroize();
        }
        if let Some(chain) = self.receiving_chain.as_mut() {
            chain.zeroize();
        }
        self.local_ratchet_secret.zeroize();
        if let Some(token) = self.issued_repair_token.as_mut() {
            token.zeroize();
        }
        if let Some(token) = self.received_repair_token.as_mut() {
            token.zeroize();
        }
    }
}

impl RatchetState {
    fn skipped_count(&self) -> u32 {
        u32::try_from(self.skipped.len()).expect("session bound is below u32")
    }

    fn encode(&self, device: &DeviceState) -> CryptoResult<Vec<u8>> {
        if self.skipped.len() > MAX_SKIPPED_PER_SESSION
            || self
                .skipped
                .windows(2)
                .any(|pair| skipped_order(&pair[0], &pair[1]) != Ordering::Less)
        {
            return Err(CryptoError::StateViolation);
        }
        let mut output = Vec::new();
        output.extend_from_slice(STATE_MAGIC);
        let flags = u8::from(self.primary) | (u8::from(self.receive_only) << 1);
        output.push(flags);
        output.extend_from_slice(&self.session_id);
        output.extend_from_slice(&self.local_device_id);
        output.extend_from_slice(&self.remote_device_id);
        output.extend_from_slice(&self.initiator_device_id);
        output.extend_from_slice(&self.transcript_hash);
        output.extend_from_slice(&self.root_key);
        encode_optional_secret(&mut output, self.sending_chain.as_ref());
        encode_optional_secret(&mut output, self.receiving_chain.as_ref());
        output.extend_from_slice(&self.local_ratchet_secret);
        output.extend_from_slice(&self.local_ratchet_public);
        output.extend_from_slice(&self.remote_ratchet_public);
        push_u32(&mut output, self.send_count);
        push_u32(&mut output, self.receive_count);
        push_u32(&mut output, self.previous_send_count);
        push_u16(
            &mut output,
            u16::try_from(self.skipped.len()).map_err(|_| CryptoError::ResourceExhausted)?,
        );
        for key in &self.skipped {
            output.extend_from_slice(&key.ratchet_public);
            push_u32(&mut output, key.message_number);
            output.extend_from_slice(&key.message_key);
        }
        encode_optional_secret(&mut output, self.issued_repair_token.as_ref());
        encode_optional_secret(&mut output, self.received_repair_token.as_ref());
        let auth_key = state_auth_key(&self.root_key, &device.identity_secret)?;
        let tag = hmac_sha256(auth_key.expose(), &output)?;
        output.extend_from_slice(&tag);
        Ok(output)
    }

    fn decode<P: CryptoProvider>(
        provider: &P,
        device: &DeviceState,
        input: &[u8],
    ) -> CryptoResult<Self> {
        const ROOT_OFFSET: usize = 8 + 1 + 16 * 4 + 32;
        if input.len() < ROOT_OFFSET + 32 + STATE_AUTH_TAG_BYTES
            || input.get(..8) != Some(STATE_MAGIC)
        {
            return Err(CryptoError::UnsupportedVersion);
        }
        let authenticated_len = input.len() - STATE_AUTH_TAG_BYTES;
        let root_key: [u8; 32] = fixed(
            input
                .get(ROOT_OFFSET..ROOT_OFFSET + 32)
                .ok_or(CryptoError::MalformedInput)?,
        )?;
        let auth_key = state_auth_key(&root_key, &device.identity_secret)?;
        let expected = hmac_sha256(auth_key.expose(), &input[..authenticated_len])?;
        if !bool::from(expected.ct_eq(&input[authenticated_len..])) {
            return Err(CryptoError::AuthenticationFailed);
        }
        let mut reader = Reader::new(&input[..authenticated_len]);
        if reader.take(8)? != STATE_MAGIC {
            return Err(CryptoError::UnsupportedVersion);
        }
        let flags = reader.u8()?;
        if flags & !0x03 != 0 {
            return Err(CryptoError::MalformedInput);
        }
        let session_id = reader.array()?;
        let local_device_id = reader.array()?;
        let remote_device_id = reader.array()?;
        let initiator_device_id = reader.array()?;
        let transcript_hash = reader.array()?;
        let decoded_root = reader.array()?;
        let sending_chain = decode_optional_secret(&mut reader)?;
        let receiving_chain = decode_optional_secret(&mut reader)?;
        let local_ratchet_secret = reader.array()?;
        let local_ratchet_public = reader.array()?;
        let remote_ratchet_public = reader.array()?;
        let send_count = reader.u32()?;
        let receive_count = reader.u32()?;
        let previous_send_count = reader.u32()?;
        let skipped_count = usize::from(reader.u16()?);
        if skipped_count > MAX_SKIPPED_PER_SESSION {
            return Err(CryptoError::ResourceExhausted);
        }
        let mut skipped = Vec::new();
        skipped
            .try_reserve_exact(skipped_count)
            .map_err(|_| CryptoError::ResourceExhausted)?;
        for _ in 0..skipped_count {
            skipped.push(SkippedKey {
                ratchet_public: reader.array()?,
                message_number: reader.u32()?,
                message_key: reader.array()?,
            });
        }
        let issued_repair_token = decode_optional_secret(&mut reader)?;
        let received_repair_token = decode_optional_secret(&mut reader)?;
        if !reader.is_finished()
            || decoded_root != root_key
            || skipped
                .windows(2)
                .any(|pair| skipped_order(&pair[0], &pair[1]) != Ordering::Less)
        {
            return Err(CryptoError::MalformedInput);
        }
        let state = Self {
            session_id,
            local_device_id,
            remote_device_id,
            initiator_device_id,
            transcript_hash,
            primary: flags & 1 != 0,
            receive_only: flags & 2 != 0,
            root_key,
            sending_chain,
            receiving_chain,
            local_ratchet_secret,
            local_ratchet_public,
            remote_ratchet_public,
            send_count,
            receive_count,
            previous_send_count,
            skipped,
            issued_repair_token,
            received_repair_token,
        };
        if is_zero(&state.session_id)
            || is_zero(&state.local_device_id)
            || is_zero(&state.remote_device_id)
            || state.local_device_id == state.remote_device_id
            || state.primary == state.receive_only
            || state.receive_only && state.sending_chain.is_some()
            || state.send_count > 0 && state.sending_chain.is_none()
            || state.receive_count > 0 && state.receiving_chain.is_none()
            || state.issued_repair_token.is_some() && state.received_repair_token.is_some()
            || provider.x25519_public(&SecretBytes::new(state.local_ratchet_secret))?
                != state.local_ratchet_public
        {
            return Err(CryptoError::StateViolation);
        }
        Ok(state)
    }
}

fn skipped_order(left: &SkippedKey, right: &SkippedKey) -> Ordering {
    left.ratchet_public
        .cmp(&right.ratchet_public)
        .then_with(|| left.message_number.cmp(&right.message_number))
}

fn encode_optional_secret(output: &mut Vec<u8>, value: Option<&[u8; 32]>) {
    match value {
        Some(bytes) => {
            output.push(1);
            output.extend_from_slice(bytes);
        }
        None => output.push(0),
    }
}

fn decode_optional_secret(reader: &mut Reader<'_>) -> CryptoResult<Option<[u8; 32]>> {
    if reader.boolean()? {
        Ok(Some(reader.array()?))
    } else {
        Ok(None)
    }
}

fn fixed<const N: usize>(value: &[u8]) -> CryptoResult<[u8; N]> {
    value.try_into().map_err(|_| CryptoError::MalformedInput)
}

fn is_zero(value: &[u8]) -> bool {
    value.iter().all(|byte| *byte == 0)
}

fn valid_key_id(id: u32) -> CryptoResult<u32> {
    if id > KEY_ID_MAX {
        Err(CryptoError::MalformedInput)
    } else {
        Ok(id)
    }
}

fn validate_optional_id(present: bool, id: u32) -> CryptoResult<()> {
    if (present && id > KEY_ID_MAX) || (!present && id != ABSENT_PREKEY_ID) {
        Err(CryptoError::MalformedInput)
    } else {
        Ok(())
    }
}

fn state_auth_key(
    root_key: &[u8; 32],
    device_identity_secret: &[u8; 32],
) -> CryptoResult<SecretBytes<32>> {
    Ok(SecretBytes::new(fixed(&hkdf_sha256(
        device_identity_secret,
        root_key,
        STATE_AUTH_DOMAIN,
        32,
    )?)?))
}

fn kdf_root(
    root_key: &[u8; 32],
    dh_output: &[u8; 32],
) -> CryptoResult<(SecretBytes<32>, SecretBytes<32>)> {
    let output = hkdf_sha256(root_key, dh_output, ROOT_DOMAIN, 64)?;
    Ok((
        SecretBytes::new(fixed(&output[..32])?),
        SecretBytes::new(fixed(&output[32..])?),
    ))
}

fn chain_step(chain_key: &[u8; 32]) -> CryptoResult<(SecretBytes<32>, SecretBytes<32>)> {
    let message_key = hmac_sha256(chain_key, &[0x01])?;
    let next_chain = hmac_sha256(chain_key, &[0x02])?;
    Ok((SecretBytes::new(message_key), SecretBytes::new(next_chain)))
}

fn aead_material(message_key: &[u8; 32]) -> CryptoResult<(SecretBytes<32>, [u8; 24])> {
    let material = hkdf_sha256(&[0; 32], message_key, AEAD_DOMAIN, 56)?;
    Ok((
        SecretBytes::new(fixed(&material[..32])?),
        fixed(&material[32..])?,
    ))
}

fn envelope_aad(recipient_device_id: &[u8; 16], header: &[u8]) -> CryptoResult<Vec<u8>> {
    let mut output = Vec::new();
    reserve(&mut output, PURPOSE.len() + 1 + 1 + 16 + 2 + header.len())?;
    output.extend_from_slice(PURPOSE);
    output.push(PROTOCOL_VERSION);
    output.push(SUITE);
    output.extend_from_slice(recipient_device_id);
    push_u16(
        &mut output,
        u16::try_from(header.len()).map_err(|_| CryptoError::InputTooLarge)?,
    );
    output.extend_from_slice(header);
    Ok(output)
}

fn sender_aad(
    recipient_device_id: &[u8; 16],
    header_prefix: &[u8],
    final_header_length: usize,
) -> CryptoResult<Vec<u8>> {
    let mut output = Vec::new();
    reserve(
        &mut output,
        1 + 1 + 2 + header_prefix.len() + 16 + PURPOSE.len(),
    )?;
    output.push(PROTOCOL_VERSION);
    output.push(SUITE);
    push_u16(
        &mut output,
        u16::try_from(final_header_length).map_err(|_| CryptoError::InputTooLarge)?,
    );
    output.extend_from_slice(header_prefix);
    output.extend_from_slice(recipient_device_id);
    output.extend_from_slice(PURPOSE);
    Ok(output)
}

fn init_signature_input(
    recipient_device_id: &[u8; 16],
    header_prefix: &[u8],
    sender_block_prefix: &[u8],
) -> CryptoResult<Vec<u8>> {
    let mut output = Vec::new();
    output.extend_from_slice(INIT_AUTH_DOMAIN);
    push_frame(&mut output, &[PROTOCOL_VERSION])?;
    push_frame(&mut output, &[SUITE])?;
    push_frame(&mut output, PURPOSE)?;
    push_frame(&mut output, recipient_device_id)?;
    push_frame(&mut output, header_prefix)?;
    push_frame(&mut output, sender_block_prefix)?;
    Ok(output)
}

fn initial_header_prefix(
    flags: u8,
    session_id: &[u8; 16],
    ratchet_public: &[u8; 32],
    signed_prekey_id: u32,
    one_time_prekey_id: u32,
    pq_signed_prekey_id: u32,
    pq_one_time_prekey_id: u32,
    ephemeral_public: &[u8; 32],
    pq_signed_ciphertext: &[u8; MLKEM768_CIPHERTEXT_BYTES],
    pq_one_time_ciphertext: Option<&[u8; MLKEM768_CIPHERTEXT_BYTES]>,
) -> Vec<u8> {
    let mut output = Vec::new();
    output.push(HEADER_VERSION);
    output.push(flags);
    output.extend_from_slice(session_id);
    output.extend_from_slice(ratchet_public);
    push_u32(&mut output, 0);
    push_u32(&mut output, 0);
    push_u32(&mut output, signed_prekey_id);
    push_u32(&mut output, one_time_prekey_id);
    push_u32(&mut output, pq_signed_prekey_id);
    push_u32(&mut output, pq_one_time_prekey_id);
    output.extend_from_slice(ephemeral_public);
    output.extend_from_slice(pq_signed_ciphertext);
    if let Some(ciphertext) = pq_one_time_ciphertext {
        output.extend_from_slice(ciphertext);
    }
    output
}

fn regular_header_bytes(state: &RatchetState) -> Vec<u8> {
    let mut output = Vec::with_capacity(REGULAR_HEADER_BYTES);
    output.push(HEADER_VERSION);
    output.push(0);
    output.extend_from_slice(&state.session_id);
    output.extend_from_slice(&state.local_ratchet_public);
    push_u32(&mut output, state.previous_send_count);
    push_u32(&mut output, state.send_count);
    output
}

fn choose_bucket(header_len: usize, inner_len: usize) -> CryptoResult<usize> {
    let minimum = 4usize
        .checked_add(header_len)
        .and_then(|value| value.checked_add(XCHACHA_ABYTES + 4))
        .and_then(|value| value.checked_add(inner_len))
        .ok_or(CryptoError::InputTooLarge)?;
    ALLOWED_BUCKETS
        .iter()
        .copied()
        .find(|bucket| *bucket >= minimum)
        .ok_or(CryptoError::InputTooLarge)
}

fn encrypt_envelope<P: CryptoProvider>(
    provider: &P,
    recipient_device_id: &[u8; 16],
    header: &[u8],
    message_key: &[u8; 32],
    inner: &[u8],
) -> CryptoResult<Vec<u8>> {
    let bucket = choose_bucket(header.len(), inner.len())?;
    let plaintext_len = bucket
        .checked_sub(4 + header.len() + XCHACHA_ABYTES)
        .ok_or(CryptoError::InternalFailure)?;
    let mut plaintext = Zeroizing::new(Vec::new());
    plaintext
        .try_reserve_exact(plaintext_len)
        .map_err(|_| CryptoError::ResourceExhausted)?;
    plaintext.extend_from_slice(
        &u32::try_from(inner.len())
            .map_err(|_| CryptoError::InputTooLarge)?
            .to_be_bytes(),
    );
    plaintext.extend_from_slice(inner);
    plaintext.resize(plaintext_len, 0);
    provider.random_bytes(&mut plaintext[4 + inner.len()..])?;
    let (key, nonce) = aead_material(message_key)?;
    let aad = envelope_aad(recipient_device_id, header)?;
    let ciphertext =
        provider.xchacha20poly1305_encrypt(&key, &nonce, &SecretVec::input(&plaintext)?, &aad)?;
    let mut output = Vec::new();
    output.push(PROTOCOL_VERSION);
    output.push(SUITE);
    push_u16(
        &mut output,
        u16::try_from(header.len()).map_err(|_| CryptoError::InputTooLarge)?,
    );
    output.extend_from_slice(header);
    output.extend_from_slice(&ciphertext);
    if output.len() != bucket {
        return Err(CryptoError::InternalFailure);
    }
    Ok(output)
}

fn decrypt_envelope<P: CryptoProvider>(
    provider: &P,
    recipient_device_id: &[u8; 16],
    envelope: &Envelope<'_>,
    message_key: &[u8; 32],
) -> CryptoResult<Vec<u8>> {
    let (key, nonce) = aead_material(message_key)?;
    let aad = envelope_aad(recipient_device_id, envelope.header_bytes)?;
    let plaintext = provider.xchacha20poly1305_decrypt(&key, &nonce, envelope.ciphertext, &aad)?;
    if plaintext.expose().len() < 4 {
        return Err(CryptoError::AuthenticationFailed);
    }
    let real_len = usize::try_from(u32::from_be_bytes(fixed(&plaintext.expose()[..4])?))
        .map_err(|_| CryptoError::MalformedInput)?;
    let end = 4usize
        .checked_add(real_len)
        .ok_or(CryptoError::AuthenticationFailed)?;
    let inner = plaintext
        .expose()
        .get(4..end)
        .ok_or(CryptoError::AuthenticationFailed)?;
    Ok(inner.to_vec())
}

fn pqxdh_secret(ikm: &[u8]) -> CryptoResult<SecretBytes<32>> {
    Ok(SecretBytes::new(fixed(&hkdf_sha256(
        &[0; 32],
        ikm,
        PQXDH_DOMAIN,
        32,
    )?)?))
}

fn anonymous_material(ikm: &[u8]) -> CryptoResult<(SecretBytes<32>, [u8; 24])> {
    let material = hkdf_sha256(&[0; 32], ikm, SEALED_SENDER_DOMAIN, 56)?;
    Ok((
        SecretBytes::new(fixed(&material[..32])?),
        fixed(&material[32..])?,
    ))
}

fn device_probe_key(identity_secret: &[u8; 32]) -> CryptoResult<SecretBytes<32>> {
    Ok(SecretBytes::new(fixed(&hkdf_sha256(
        &[0; 32],
        identity_secret,
        SEALED_SENDER_DOMAIN,
        32,
    )?)?))
}

struct SenderBlock {
    sender_user_id: [u8; 16],
    sender_device_id: [u8; 16],
    sender_ik_public: [u8; 64],
    sender_registration_id: u32,
    sender_bundle_version: u32,
    repair: Option<([u8; 16], [u8; 32])>,
    init_signature: [u8; 64],
}

impl Drop for SenderBlock {
    fn drop(&mut self) {
        if let Some((_, token)) = self.repair.as_mut() {
            token.zeroize();
        }
    }
}

impl SenderBlock {
    fn prefix(
        state: &DeviceState,
        sender_device_id: &[u8; 16],
        repair: Option<([u8; 16], [u8; 32])>,
    ) -> Vec<u8> {
        let mut output = Vec::new();
        output.push(1);
        output.extend_from_slice(&state.user_id);
        output.extend_from_slice(sender_device_id);
        output.extend_from_slice(state.ik_public().as_bytes());
        push_u32(&mut output, state.registration_id);
        push_u32(&mut output, state.bundle_version);
        match repair {
            Some((old_session_id, token)) => {
                output.push(1);
                output.extend_from_slice(&old_session_id);
                output.extend_from_slice(&token);
            }
            None => output.push(0),
        }
        output
    }

    fn parse(input: &[u8]) -> CryptoResult<Self> {
        let mut reader = Reader::new(input);
        if reader.u8()? != 1 {
            return Err(CryptoError::UnsupportedVersion);
        }
        let sender_user_id = reader.array()?;
        let sender_device_id = reader.array()?;
        let sender_ik_public = reader.array()?;
        let sender_registration_id = reader.u32()?;
        let sender_bundle_version = reader.u32()?;
        let repair = if reader.boolean()? {
            Some((reader.array()?, reader.array()?))
        } else {
            None
        };
        let init_signature = reader.array()?;
        if !reader.is_finished()
            || sender_bundle_version == 0
            || input.len()
                != if repair.is_some() {
                    SENDER_BLOCK_REPAIR_BYTES
                } else {
                    SENDER_BLOCK_WITHOUT_REPAIR_BYTES
                }
        {
            return Err(CryptoError::MalformedInput);
        }
        Ok(Self {
            sender_user_id,
            sender_device_id,
            sender_ik_public,
            sender_registration_id,
            sender_bundle_version,
            repair,
            init_signature,
        })
    }

    fn prefix_bytes(&self) -> Zeroizing<Vec<u8>> {
        let mut output = Zeroizing::new(Vec::new());
        output.push(1);
        output.extend_from_slice(&self.sender_user_id);
        output.extend_from_slice(&self.sender_device_id);
        output.extend_from_slice(&self.sender_ik_public);
        push_u32(&mut output, self.sender_registration_id);
        push_u32(&mut output, self.sender_bundle_version);
        match self.repair {
            Some((old_session_id, token)) => {
                output.push(1);
                output.extend_from_slice(&old_session_id);
                output.extend_from_slice(&token);
            }
            None => output.push(0),
        }
        output
    }
}

struct ProbeResult {
    sender: SenderBlock,
    probe_token: [u8; 32],
}

impl Drop for ProbeResult {
    fn drop(&mut self) {
        self.probe_token.zeroize();
    }
}

struct InitialSecrets {
    dh3: [u8; 32],
    dh4: Option<[u8; 32]>,
    signed_pq: [u8; 32],
    one_time_pq: Option<[u8; 32]>,
}

impl Drop for InitialSecrets {
    fn drop(&mut self) {
        self.dh3.zeroize();
        if let Some(value) = self.dh4.as_mut() {
            value.zeroize();
        }
        self.signed_pq.zeroize();
        if let Some(value) = self.one_time_pq.as_mut() {
            value.zeroize();
        }
    }
}

impl InitialSecrets {
    fn anonymous_ikm(&self) -> Zeroizing<Vec<u8>> {
        let mut output = Zeroizing::new(Vec::new());
        output.extend_from_slice(&self.dh3);
        if let Some(dh4) = self.dh4 {
            output.extend_from_slice(&dh4);
        }
        output.extend_from_slice(&self.signed_pq);
        if let Some(one_time_pq) = self.one_time_pq {
            output.extend_from_slice(&one_time_pq);
        }
        output
    }
}

fn responder_initial_secrets<P: CryptoProvider>(
    provider: &P,
    device: &DeviceState,
    header: &InitialHeader,
) -> CryptoResult<InitialSecrets> {
    let signed_classical = device
        .signed_classical(header.signed_prekey_id)
        .ok_or(CryptoError::AuthenticationFailed)?;
    let signed_pq = device
        .signed_pq(header.pq_signed_prekey_id)
        .ok_or(CryptoError::AuthenticationFailed)?;
    let dh3 = provider.x25519_shared(
        &SecretBytes::new(signed_classical.secret),
        &header.ephemeral_public,
    )?;
    let dh4 = if header.flags & FLAG_CLASSICAL_ONE_TIME != 0 {
        let key = device
            .classical_one_time(header.one_time_prekey_id)
            .ok_or(CryptoError::AuthenticationFailed)?;
        Some(
            *provider
                .x25519_shared(&SecretBytes::new(key.secret), &header.ephemeral_public)?
                .expose(),
        )
    } else {
        None
    };
    let signed_pq_secret = provider.mlkem768_decapsulate(
        &SecretBytes::new(signed_pq.secret),
        &header.pq_signed_ciphertext,
    )?;
    let one_time_pq = if header.flags & FLAG_PQ_ONE_TIME != 0 {
        let key = device
            .pq_one_time(header.pq_one_time_prekey_id)
            .ok_or(CryptoError::AuthenticationFailed)?;
        let ciphertext = header
            .pq_one_time_ciphertext
            .as_ref()
            .ok_or(CryptoError::MalformedInput)?;
        Some(
            *provider
                .mlkem768_decapsulate(&SecretBytes::new(key.secret), ciphertext)?
                .expose(),
        )
    } else {
        None
    };
    Ok(InitialSecrets {
        dh3: *dh3.expose(),
        dh4,
        signed_pq: *signed_pq_secret.expose(),
        one_time_pq,
    })
}

fn probe_initial<P: CryptoProvider>(
    provider: &P,
    device: &DeviceState,
    recipient_device_id: &[u8; 16],
    envelope_bytes: &[u8],
) -> CryptoResult<ProbeResult> {
    let envelope = Envelope::parse(envelope_bytes)?;
    let RatchetHeader::Initial(header) = &envelope.header else {
        return Err(CryptoError::StateViolation);
    };
    let secrets = responder_initial_secrets(provider, device, header)?;
    let (key, nonce) = anonymous_material(&secrets.anonymous_ikm())?;
    let prefix_len = envelope
        .header_bytes
        .len()
        .checked_sub(2 + header.sender_seal.len())
        .ok_or(CryptoError::MalformedInput)?;
    let prefix = envelope
        .header_bytes
        .get(..prefix_len)
        .ok_or(CryptoError::MalformedInput)?;
    let aad = sender_aad(recipient_device_id, prefix, envelope.header_bytes.len())?;
    let plaintext = provider.xchacha20poly1305_decrypt(&key, &nonce, &header.sender_seal, &aad)?;
    let sender = SenderBlock::parse(plaintext.expose())?;
    if (header.flags & FLAG_REPAIR_REPLACEMENT != 0) != sender.repair.is_some() {
        return Err(CryptoError::AuthenticationFailed);
    }
    let envelope_hash = provider.sha256(envelope_bytes)?;
    let mut token_input = Vec::new();
    token_input.extend_from_slice(PROBE_MAGIC);
    token_input.extend_from_slice(recipient_device_id);
    token_input.extend_from_slice(&envelope_hash);
    token_input.extend_from_slice(plaintext.expose());
    let probe_key = device_probe_key(&device.identity_secret)?;
    let probe_token = hmac_sha256(probe_key.expose(), &token_input)?;
    Ok(ProbeResult {
        sender,
        probe_token,
    })
}

fn encode_probe_output(probe: &ProbeResult) -> Vec<u8> {
    let mut output = Vec::new();
    output.extend_from_slice(&probe.sender.sender_user_id);
    output.extend_from_slice(&probe.sender.sender_device_id);
    output.extend_from_slice(&probe.sender.sender_ik_public);
    push_u32(&mut output, probe.sender.sender_registration_id);
    push_u32(&mut output, probe.sender.sender_bundle_version);
    match probe.sender.repair.as_ref() {
        Some((old_session, _token)) => {
            output.push(1);
            output.extend_from_slice(old_session);
        }
        None => output.push(0),
    }
    output.extend_from_slice(&probe.probe_token);
    output
}

fn verify_repair_authorization(
    device: &DeviceState,
    authorization: &[u8],
) -> CryptoResult<Option<([u8; 16], [u8; 32])>> {
    if authorization.is_empty() {
        return Ok(None);
    }
    let mut reader = Reader::new(authorization);
    if reader.take(8)? != REPAIR_AUTH_MAGIC {
        return Err(CryptoError::MalformedInput);
    }
    let old_session_id = reader.array()?;
    let token = reader.array()?;
    let supplied_tag: [u8; 32] = reader.array()?;
    if !reader.is_finished() {
        return Err(CryptoError::MalformedInput);
    }
    let mut authenticated = Vec::new();
    authenticated.extend_from_slice(REPAIR_DOMAIN);
    authenticated.extend_from_slice(&authorization[..authorization.len() - 32]);
    let probe_key = device_probe_key(&device.identity_secret)?;
    let expected = hmac_sha256(probe_key.expose(), &authenticated)?;
    if !bool::from(expected.ct_eq(&supplied_tag)) {
        return Err(CryptoError::AuthenticationFailed);
    }
    Ok(Some((old_session_id, token)))
}

#[allow(clippy::too_many_arguments)]
fn initiate<P: CryptoProvider>(
    provider: &P,
    device: &DeviceState,
    sender_device_id: [u8; 16],
    recipient_device_id: [u8; 16],
    peer: &PeerBundle,
    classical_one_time: Option<OptionalClassicalPrekey>,
    pq_one_time: Option<OptionalPqPrekey>,
    repair_authorization: &[u8],
    inner: &[u8],
    other_sessions_skipped: u32,
) -> CryptoResult<(RatchetState, Vec<u8>)> {
    if peer.device_id != recipient_device_id
        || sender_device_id == recipient_device_id
        || usize::try_from(other_sessions_skipped).map_err(|_| CryptoError::ResourceExhausted)?
            > MAX_SKIPPED_ACCOUNT
    {
        return Err(CryptoError::AuthenticationFailed);
    }
    let repair = verify_repair_authorization(device, repair_authorization)?;
    let mut ephemeral_secret = SecretBytes::<X25519_SECRET_BYTES>::zeroed();
    let mut ratchet_secret = SecretBytes::<X25519_SECRET_BYTES>::zeroed();
    provider.random_bytes(ephemeral_secret.expose_mut())?;
    provider.random_bytes(ratchet_secret.expose_mut())?;
    let ephemeral_public = provider.x25519_public(&ephemeral_secret)?;
    let ratchet_public = provider.x25519_public(&ratchet_secret)?;
    let dh1 = provider.x25519_shared(
        &SecretBytes::new(device.identity_secret),
        &peer.signed_prekey_public,
    )?;
    let dh2 = provider.x25519_shared(&ephemeral_secret, &peer.identity_public())?;
    let dh3 = provider.x25519_shared(&ephemeral_secret, &peer.signed_prekey_public)?;
    let dh4 = match classical_one_time {
        Some(key) => Some(provider.x25519_shared(&ephemeral_secret, &key.public)?),
        None => None,
    };
    let (pq_signed_ciphertext, pq_signed_secret) =
        provider.mlkem768_encapsulate(&peer.pq_signed_prekey_public)?;
    let (pq_one_time_ciphertext, pq_one_time_secret) = match pq_one_time {
        Some(key) => {
            let (ciphertext, secret) = provider.mlkem768_encapsulate(&key.public)?;
            (Some(ciphertext), Some(secret))
        }
        None => (None, None),
    };
    let mut pqxdh_ikm = Zeroizing::new(Vec::new());
    pqxdh_ikm.extend_from_slice(&[0xff; 32]);
    pqxdh_ikm.extend_from_slice(dh1.expose());
    pqxdh_ikm.extend_from_slice(dh2.expose());
    pqxdh_ikm.extend_from_slice(dh3.expose());
    if let Some(value) = &dh4 {
        pqxdh_ikm.extend_from_slice(value.expose());
    }
    pqxdh_ikm.extend_from_slice(pq_signed_secret.expose());
    if let Some(value) = &pq_one_time_secret {
        pqxdh_ikm.extend_from_slice(value.expose());
    }
    let shared_secret = pqxdh_secret(&pqxdh_ikm)?;
    let mut anonymous_ikm = Zeroizing::new(Vec::new());
    anonymous_ikm.extend_from_slice(dh3.expose());
    if let Some(value) = &dh4 {
        anonymous_ikm.extend_from_slice(value.expose());
    }
    anonymous_ikm.extend_from_slice(pq_signed_secret.expose());
    if let Some(value) = &pq_one_time_secret {
        anonymous_ikm.extend_from_slice(value.expose());
    }
    let (anonymous_key, anonymous_nonce) = anonymous_material(&anonymous_ikm)?;
    let mut session_id = [0u8; 16];
    provider.random_bytes(&mut session_id)?;
    if is_zero(&session_id) {
        return Err(CryptoError::EntropyUnavailable);
    }
    let mut flags = FLAG_INITIAL;
    if classical_one_time.is_some() {
        flags |= FLAG_CLASSICAL_ONE_TIME;
    }
    if pq_one_time.is_some() {
        flags |= FLAG_PQ_ONE_TIME;
    }
    if repair.is_some() {
        flags |= FLAG_REPAIR_REPLACEMENT;
    }
    let header_prefix = initial_header_prefix(
        flags,
        &session_id,
        &ratchet_public,
        peer.signed_prekey_id,
        classical_one_time.map_or(ABSENT_PREKEY_ID, |key| key.id),
        peer.pq_signed_prekey_id,
        pq_one_time.map_or(ABSENT_PREKEY_ID, |key| key.id),
        &ephemeral_public,
        &pq_signed_ciphertext,
        pq_one_time_ciphertext.as_ref(),
    );
    let sender_prefix = SenderBlock::prefix(device, &sender_device_id, repair);
    let signature_input =
        init_signature_input(&recipient_device_id, &header_prefix, &sender_prefix)?;
    let signature = provider.ed25519_sign(
        &SecretBytes::new(device.device_signing_secret),
        &signature_input,
    )?;
    let mut sender_plaintext = Zeroizing::new(sender_prefix);
    sender_plaintext.extend_from_slice(&signature);
    let final_header_length = header_prefix
        .len()
        .checked_add(2 + sender_plaintext.len() + XCHACHA_ABYTES)
        .ok_or(CryptoError::InputTooLarge)?;
    let sender_aad = sender_aad(&recipient_device_id, &header_prefix, final_header_length)?;
    let sender_seal = provider.xchacha20poly1305_encrypt(
        &anonymous_key,
        &anonymous_nonce,
        &SecretVec::input(&sender_plaintext)?,
        &sender_aad,
    )?;
    let mut header = header_prefix;
    push_u16(
        &mut header,
        u16::try_from(sender_seal.len()).map_err(|_| CryptoError::InputTooLarge)?,
    );
    header.extend_from_slice(&sender_seal);
    if header.len() != final_header_length {
        return Err(CryptoError::InternalFailure);
    }
    let ratchet_dh = provider.x25519_shared(&ratchet_secret, &peer.signed_prekey_public)?;
    let (root_key, sending_chain) = kdf_root(shared_secret.expose(), ratchet_dh.expose())?;
    let (message_key, next_chain) = chain_step(sending_chain.expose())?;
    let envelope = encrypt_envelope(
        provider,
        &recipient_device_id,
        &header,
        message_key.expose(),
        inner,
    )?;
    let transcript_hash = provider.sha256(&header)?;
    Ok((
        RatchetState {
            session_id,
            local_device_id: sender_device_id,
            remote_device_id: recipient_device_id,
            initiator_device_id: sender_device_id,
            transcript_hash,
            primary: true,
            receive_only: false,
            root_key: *root_key.expose(),
            sending_chain: Some(*next_chain.expose()),
            receiving_chain: None,
            local_ratchet_secret: *ratchet_secret.expose(),
            local_ratchet_public: ratchet_public,
            remote_ratchet_public: peer.signed_prekey_public,
            send_count: 1,
            receive_count: 0,
            previous_send_count: 0,
            skipped: Vec::new(),
            issued_repair_token: None,
            received_repair_token: None,
        },
        envelope,
    ))
}

struct AcceptedInitial {
    next_device_state: Vec<u8>,
    session: RatchetState,
    session_state: Vec<u8>,
    inner: Vec<u8>,
    replay_marker: [u8; 32],
    consumed_classical_id: u32,
    consumed_pq_id: u32,
    disposition: u8,
    updated_existing_state: Vec<u8>,
    replaced_session_id: Option<[u8; 16]>,
    referenced_signed_prekey_id: u32,
    referenced_pq_signed_prekey_id: u32,
}

struct EncryptedTransition {
    state: RatchetState,
    envelope: Vec<u8>,
}

struct DecryptedTransition {
    state: RatchetState,
    inner: Vec<u8>,
    replay_marker: [u8; 32],
    payload_kind: u8,
}

enum ReceiveOutcome {
    Prepared(DecryptedTransition),
    RepairRequired,
}

fn ratchet_encrypt<P: CryptoProvider>(
    provider: &P,
    mut state: RatchetState,
    recipient_device_id: [u8; 16],
    inner: &[u8],
    other_sessions_skipped: u32,
) -> CryptoResult<EncryptedTransition> {
    if state.receive_only
        || state.remote_device_id != recipient_device_id
        || usize::try_from(other_sessions_skipped)
            .map_err(|_| CryptoError::ResourceExhausted)?
            .saturating_add(state.skipped.len())
            > MAX_SKIPPED_ACCOUNT
    {
        return Err(CryptoError::StateViolation);
    }
    if state.sending_chain.is_none() {
        let mut new_secret = SecretBytes::<32>::zeroed();
        provider.random_bytes(new_secret.expose_mut())?;
        let new_public = provider.x25519_public(&new_secret)?;
        let dh = provider.x25519_shared(&new_secret, &state.remote_ratchet_public)?;
        let (new_root, new_chain) = kdf_root(&state.root_key, dh.expose())?;
        state.root_key.zeroize();
        state.local_ratchet_secret.zeroize();
        state.root_key = *new_root.expose();
        state.sending_chain = Some(*new_chain.expose());
        state.local_ratchet_secret = *new_secret.expose();
        state.local_ratchet_public = new_public;
        state.previous_send_count = state.send_count;
        state.send_count = 0;
    }
    let header = regular_header_bytes(&state);
    let chain = state
        .sending_chain
        .as_ref()
        .ok_or(CryptoError::StateViolation)?;
    let (message_key, next_chain) = chain_step(chain)?;
    let envelope = encrypt_envelope(
        provider,
        &recipient_device_id,
        &header,
        message_key.expose(),
        inner,
    )?;
    state.sending_chain = Some(*next_chain.expose());
    state.send_count = state
        .send_count
        .checked_add(1)
        .ok_or(CryptoError::StateViolation)?;
    Ok(EncryptedTransition { state, envelope })
}

fn projected_skip_within_bounds(
    state: &RatchetState,
    additional: usize,
    other_sessions_skipped: u32,
) -> CryptoResult<bool> {
    let projected_session = state
        .skipped
        .len()
        .checked_add(additional)
        .ok_or(CryptoError::ResourceExhausted)?;
    let other =
        usize::try_from(other_sessions_skipped).map_err(|_| CryptoError::ResourceExhausted)?;
    let projected_account = other
        .checked_add(projected_session)
        .ok_or(CryptoError::ResourceExhausted)?;
    Ok(projected_session <= MAX_SKIPPED_PER_SESSION && projected_account <= MAX_SKIPPED_ACCOUNT)
}

fn skip_receiving_keys(state: &mut RatchetState, until: u32) -> CryptoResult<()> {
    if until < state.receive_count {
        return Err(CryptoError::StateViolation);
    }
    while state.receive_count < until {
        let chain = state
            .receiving_chain
            .as_ref()
            .ok_or(CryptoError::StateViolation)?;
        let (message_key, next_chain) = chain_step(chain)?;
        state.skipped.push(SkippedKey {
            ratchet_public: state.remote_ratchet_public,
            message_number: state.receive_count,
            message_key: *message_key.expose(),
        });
        state.receiving_chain = Some(*next_chain.expose());
        state.receive_count = state
            .receive_count
            .checked_add(1)
            .ok_or(CryptoError::StateViolation)?;
    }
    state.skipped.sort_unstable_by(skipped_order);
    Ok(())
}

fn inspect_repair_control(state: &mut RatchetState, inner: &[u8]) -> CryptoResult<u8> {
    if !inner.starts_with(REPAIR_CONTROL_MAGIC) {
        return Ok(0);
    }
    if inner.len() != REPAIR_CONTROL_BYTES {
        return Err(CryptoError::MalformedInput);
    }
    let mut reader = Reader::new(inner);
    if reader.take(8)? != REPAIR_CONTROL_MAGIC || reader.u8()? != 1 {
        return Err(CryptoError::MalformedInput);
    }
    let old_session_id: [u8; 16] = reader.array()?;
    let token = reader.array()?;
    if reader.u8()? != REPAIR_REASON_SKIPPED_LIMIT || !reader.is_finished() {
        return Err(CryptoError::MalformedInput);
    }
    if old_session_id != state.session_id || state.received_repair_token.is_some() {
        return Err(CryptoError::StateViolation);
    }
    state.received_repair_token = Some(token);
    Ok(1)
}

fn ratchet_decrypt<P: CryptoProvider>(
    provider: &P,
    mut state: RatchetState,
    recipient_device_id: [u8; 16],
    envelope_bytes: &[u8],
    other_sessions_skipped: u32,
) -> CryptoResult<ReceiveOutcome> {
    if state.local_device_id != recipient_device_id {
        return Err(CryptoError::AuthenticationFailed);
    }
    let envelope = Envelope::parse(envelope_bytes)?;
    let RatchetHeader::Regular(header) = &envelope.header else {
        return Err(CryptoError::StateViolation);
    };
    if header.session_id != state.session_id {
        return Err(CryptoError::AuthenticationFailed);
    }
    if header.ratchet_public == state.remote_ratchet_public
        && header.message_number < state.receive_count
    {
        let position = state.skipped.iter().position(|key| {
            key.ratchet_public == header.ratchet_public
                && key.message_number == header.message_number
        });
        let Some(position) = position else {
            return Err(CryptoError::StateViolation);
        };
        let inner = decrypt_envelope(
            provider,
            &recipient_device_id,
            &envelope,
            &state.skipped[position].message_key,
        )?;
        state.skipped.remove(position);
        let payload_kind = inspect_repair_control(&mut state, &inner)?;
        return Ok(ReceiveOutcome::Prepared(DecryptedTransition {
            state,
            inner,
            replay_marker: provider.sha256(envelope_bytes)?,
            payload_kind,
        }));
    }

    if header.ratchet_public != state.remote_ratchet_public {
        if header.previous_chain_length < state.receive_count {
            return Err(CryptoError::StateViolation);
        }
        let old_gap = usize::try_from(header.previous_chain_length - state.receive_count)
            .map_err(|_| CryptoError::ResourceExhausted)?;
        let new_gap =
            usize::try_from(header.message_number).map_err(|_| CryptoError::ResourceExhausted)?;
        let additional = old_gap
            .checked_add(new_gap)
            .ok_or(CryptoError::ResourceExhausted)?;
        if !projected_skip_within_bounds(&state, additional, other_sessions_skipped)? {
            return Ok(ReceiveOutcome::RepairRequired);
        }
        skip_receiving_keys(&mut state, header.previous_chain_length)?;
        state.previous_send_count = state.send_count;
        state.send_count = 0;
        state.receive_count = 0;
        state.remote_ratchet_public = header.ratchet_public;
        let receiving_dh = provider.x25519_shared(
            &SecretBytes::new(state.local_ratchet_secret),
            &state.remote_ratchet_public,
        )?;
        let (root_after_receive, receiving_chain) =
            kdf_root(&state.root_key, receiving_dh.expose())?;
        let mut new_local_secret = SecretBytes::<32>::zeroed();
        provider.random_bytes(new_local_secret.expose_mut())?;
        let new_local_public = provider.x25519_public(&new_local_secret)?;
        let sending_dh = provider.x25519_shared(&new_local_secret, &state.remote_ratchet_public)?;
        let (root_after_send, sending_chain) =
            kdf_root(root_after_receive.expose(), sending_dh.expose())?;
        state.root_key.zeroize();
        state.local_ratchet_secret.zeroize();
        state.root_key = *root_after_send.expose();
        state.receiving_chain = Some(*receiving_chain.expose());
        state.sending_chain = Some(*sending_chain.expose());
        state.local_ratchet_secret = *new_local_secret.expose();
        state.local_ratchet_public = new_local_public;
    } else {
        if header.message_number < state.receive_count {
            return Err(CryptoError::StateViolation);
        }
        let gap = usize::try_from(header.message_number - state.receive_count)
            .map_err(|_| CryptoError::ResourceExhausted)?;
        if !projected_skip_within_bounds(&state, gap, other_sessions_skipped)? {
            return Ok(ReceiveOutcome::RepairRequired);
        }
    }

    skip_receiving_keys(&mut state, header.message_number)?;
    let chain = state
        .receiving_chain
        .as_ref()
        .ok_or(CryptoError::StateViolation)?;
    let (message_key, next_chain) = chain_step(chain)?;
    let inner = decrypt_envelope(
        provider,
        &recipient_device_id,
        &envelope,
        message_key.expose(),
    )?;
    state.receiving_chain = Some(*next_chain.expose());
    state.receive_count = state
        .receive_count
        .checked_add(1)
        .ok_or(CryptoError::StateViolation)?;
    let payload_kind = inspect_repair_control(&mut state, &inner)?;
    Ok(ReceiveOutcome::Prepared(DecryptedTransition {
        state,
        inner,
        replay_marker: provider.sha256(envelope_bytes)?,
        payload_kind,
    }))
}

fn create_repair<P: CryptoProvider>(
    provider: &P,
    mut state: RatchetState,
    recipient_device_id: [u8; 16],
    other_sessions_skipped: u32,
) -> CryptoResult<EncryptedTransition> {
    if state.issued_repair_token.is_some() {
        return Err(CryptoError::StateViolation);
    }
    let mut token = SecretBytes::<32>::zeroed();
    provider.random_bytes(token.expose_mut())?;
    let mut control = Zeroizing::new(Vec::with_capacity(REPAIR_CONTROL_BYTES));
    control.extend_from_slice(REPAIR_CONTROL_MAGIC);
    control.push(1);
    control.extend_from_slice(&state.session_id);
    control.extend_from_slice(token.expose());
    control.push(REPAIR_REASON_SKIPPED_LIMIT);
    if control.len() != REPAIR_CONTROL_BYTES {
        return Err(CryptoError::InternalFailure);
    }
    state.issued_repair_token = Some(*token.expose());
    ratchet_encrypt(
        provider,
        state,
        recipient_device_id,
        &control,
        other_sessions_skipped,
    )
}

fn consume_repair_authorization(
    device: &DeviceState,
    mut state: RatchetState,
) -> CryptoResult<(RatchetState, Vec<u8>)> {
    let token = SecretBytes::new(
        state
            .received_repair_token
            .take()
            .ok_or(CryptoError::StateViolation)?,
    );
    let mut authorization = Zeroizing::new(Vec::new());
    authorization.extend_from_slice(REPAIR_AUTH_MAGIC);
    authorization.extend_from_slice(&state.session_id);
    authorization.extend_from_slice(token.expose());
    let mut authenticated = Zeroizing::new(Vec::new());
    authenticated.extend_from_slice(REPAIR_DOMAIN);
    authenticated.extend_from_slice(&authorization);
    let probe_key = device_probe_key(&device.identity_secret)?;
    let tag = hmac_sha256(probe_key.expose(), &authenticated)?;
    authorization.extend_from_slice(&tag);
    Ok((state, authorization.to_vec()))
}

pub(crate) fn operation(operation: u32, input: &[u8]) -> CryptoResult<Vec<u8>> {
    if input.len() > PAIRWISE_MAX_IO_BYTES {
        return Err(CryptoError::InputTooLarge);
    }
    let output = operation_with_provider(&RustCryptoProvider::default(), operation, input)?;
    if output.len() > PAIRWISE_MAX_IO_BYTES {
        return Err(CryptoError::ResourceExhausted);
    }
    Ok(output)
}

pub(crate) fn operation_with_provider<P: CryptoProvider>(
    provider: &P,
    operation: u32,
    input: &[u8],
) -> CryptoResult<Vec<u8>> {
    let mut reader = Reader::new(input);
    if reader.take(8)? != REQUEST_MAGIC {
        return Err(CryptoError::MalformedInput);
    }
    match operation {
        OP_UPGRADE_DEVICE_STATE => operation_upgrade(provider, operation, &mut reader),
        OP_PREPARE_REPLENISHMENT => {
            operation_prepare_replenishment(provider, operation, &mut reader)
        }
        OP_COMMIT_PREKEY_UPLOAD => operation_commit_upload(provider, operation, &mut reader),
        OP_PREPARE_ROTATION => operation_prepare_rotation(provider, operation, &mut reader),
        OP_PRUNE_RETIRED => operation_prune(provider, operation, &mut reader),
        OP_INITIATE => operation_initiate(provider, operation, &mut reader),
        OP_PROBE_INITIAL => operation_probe(provider, operation, &mut reader),
        OP_ACCEPT_INITIAL => operation_accept(provider, operation, &mut reader),
        OP_ENCRYPT => operation_encrypt(provider, operation, &mut reader),
        OP_DECRYPT => operation_decrypt(provider, operation, &mut reader),
        OP_CREATE_REPAIR => operation_create_repair(provider, operation, &mut reader),
        OP_CONSUME_REPAIR => operation_consume_repair(provider, operation, &mut reader),
        OP_INSPECT_PUBLIC_HEADER => operation_inspect_public_header(operation, &mut reader),
        OP_SEAL_GROUP_CONTROL => operation_seal_group_control(provider, operation, &mut reader),
        OP_OPEN_GROUP_CONTROL => operation_open_group_control(provider, operation, &mut reader),
        _ => Err(CryptoError::UnsupportedOperation),
    }
}

/// Signs one group control event with this device's signing key.
///
/// It lives behind the pairwise multiplexer because the key lives in the
/// pairwise device state, and the caller never sees either.
fn operation_seal_group_control<P: CryptoProvider>(
    provider: &P,
    operation: u32,
    reader: &mut Reader<'_>,
) -> CryptoResult<Vec<u8>> {
    let device_bytes = reader.framed()?;
    let migration_day = reader.u32()?;
    let projection = reader.framed()?;
    finish(reader)?;
    let device = decode_device_state(provider, device_bytes, migration_day)?;
    let sealed = group_control::seal(provider, &device, projection)?;
    let mut output = output_prefix(operation, OUTCOME_OK)?;
    push_frame(&mut output, &sealed.canonical)?;
    output.extend_from_slice(&sealed.signature);
    output.extend_from_slice(&sealed.state_hash);
    Ok(output)
}

/// Verifies one group control event under the device signing key its caller
/// authenticated for the claimed signer, then returns its projection.
fn operation_open_group_control<P: CryptoProvider>(
    provider: &P,
    operation: u32,
    reader: &mut Reader<'_>,
) -> CryptoResult<Vec<u8>> {
    let signing_public = reader.array()?;
    let canonical = reader.framed()?;
    let signature: [u8; ED25519_SIGNATURE_BYTES] = reader.array()?;
    finish(reader)?;
    let opened = group_control::open(provider, &signing_public, canonical, &signature)?;
    let mut output = output_prefix(operation, OUTCOME_OK)?;
    push_frame(&mut output, &opened.projection)?;
    output.extend_from_slice(&opened.state_hash);
    Ok(output)
}

fn operation_inspect_public_header(
    operation: u32,
    reader: &mut Reader<'_>,
) -> CryptoResult<Vec<u8>> {
    let envelope = reader.framed()?;
    finish(reader)?;
    let (kind, session_id) = inspect_public_header(envelope)?;
    let mut output = output_prefix(operation, OUTCOME_OK)?;
    output.push(kind);
    output.extend_from_slice(&session_id);
    Ok(output)
}

fn output_prefix(operation: u32, outcome: u8) -> CryptoResult<Vec<u8>> {
    let operation = u8::try_from(operation).map_err(|_| CryptoError::UnsupportedOperation)?;
    let mut output = Vec::new();
    output.extend_from_slice(OUTPUT_MAGIC);
    output.push(operation);
    output.push(outcome);
    Ok(output)
}

fn finish(reader: &Reader<'_>) -> CryptoResult<()> {
    if reader.is_finished() {
        Ok(())
    } else {
        Err(CryptoError::MalformedInput)
    }
}

fn append_device_summary(output: &mut Vec<u8>, state: &DeviceState) -> CryptoResult<()> {
    push_u16(
        output,
        u16::try_from(state.classical_one_time.len())
            .map_err(|_| CryptoError::ResourceExhausted)?,
    );
    push_u16(
        output,
        u16::try_from(state.pq_one_time.len()).map_err(|_| CryptoError::ResourceExhausted)?,
    );
    push_u32(output, state.bundle_version);
    // Classical and PQ signed prekeys rotate atomically and therefore always
    // have the same creation day. Returning the native value lets persistence
    // reconcile legacy/default metadata without inventing a second clock.
    if state.current_classical.created_day != state.current_pq.created_day {
        return Err(CryptoError::StateViolation);
    }
    push_u32(output, state.current_classical.created_day);
    Ok(())
}

fn operation_upgrade<P: CryptoProvider>(
    provider: &P,
    operation: u32,
    reader: &mut Reader<'_>,
) -> CryptoResult<Vec<u8>> {
    let encoded = reader.framed()?;
    let migration_day = reader.u32()?;
    finish(reader)?;
    let state = decode_device_state(provider, encoded, migration_day)?;
    let next = encode_device_state(&state)?;
    let mut output = output_prefix(operation, OUTCOME_OK)?;
    push_frame(&mut output, &next)?;
    append_device_summary(&mut output, &state)?;
    Ok(output)
}

fn operation_prepare_replenishment<P: CryptoProvider>(
    provider: &P,
    operation: u32,
    reader: &mut Reader<'_>,
) -> CryptoResult<Vec<u8>> {
    let encoded = reader.framed()?;
    let migration_day = reader.u32()?;
    let server_classical = reader.u16()?;
    let server_pq = reader.u16()?;
    let target_classical = reader.u16()?;
    let target_pq = reader.u16()?;
    finish(reader)?;
    let mut state = decode_device_state(provider, encoded, migration_day)?;
    if state
        .pending
        .as_ref()
        .is_some_and(|pending| pending.is_rotation())
    {
        return Err(CryptoError::StateViolation);
    }
    let (batch_id, projection) = prepare_replenishment(
        provider,
        &mut state,
        server_classical,
        server_pq,
        target_classical,
        target_pq,
    )?;
    let next = encode_device_state(&state)?;
    let mut output = output_prefix(operation, OUTCOME_OK)?;
    push_frame(&mut output, &next)?;
    output.extend_from_slice(&batch_id);
    push_frame(&mut output, &projection)?;
    push_u16(
        &mut output,
        u16::try_from(state.classical_one_time.len())
            .map_err(|_| CryptoError::ResourceExhausted)?,
    );
    push_u16(
        &mut output,
        u16::try_from(state.pq_one_time.len()).map_err(|_| CryptoError::ResourceExhausted)?,
    );
    push_u32(&mut output, state.current_classical.created_day);
    Ok(output)
}

fn operation_commit_upload<P: CryptoProvider>(
    provider: &P,
    operation: u32,
    reader: &mut Reader<'_>,
) -> CryptoResult<Vec<u8>> {
    let encoded = reader.framed()?;
    let migration_day = reader.u32()?;
    let batch_id = reader.array()?;
    let log_appended = reader.boolean()?;
    finish(reader)?;
    let mut state = decode_device_state(provider, encoded, migration_day)?;
    if state
        .pending
        .as_ref()
        .is_some_and(|pending| pending.is_rotation())
        && !log_appended
    {
        return Err(CryptoError::StateViolation);
    }
    commit_pending_upload(&mut state, &batch_id)?;
    let next = encode_device_state(&state)?;
    let mut output = output_prefix(operation, OUTCOME_OK)?;
    push_frame(&mut output, &next)?;
    append_device_summary(&mut output, &state)?;
    Ok(output)
}

fn operation_prepare_rotation<P: CryptoProvider>(
    provider: &P,
    operation: u32,
    reader: &mut Reader<'_>,
) -> CryptoResult<Vec<u8>> {
    let encoded = reader.framed()?;
    let migration_day = reader.u32()?;
    let identity_package = reader.framed()?;
    let device_id = reader.array()?;
    let coarse_day = reader.u32()?;
    finish(reader)?;
    let mut state = decode_device_state(provider, encoded, migration_day)?;
    if state
        .pending
        .as_ref()
        .is_some_and(|pending| !pending.is_rotation())
    {
        return Err(CryptoError::StateViolation);
    }
    let (batch_id, projection) = prepare_rotation(
        provider,
        &mut state,
        identity_package,
        device_id,
        coarse_day,
    )?;
    let next = encode_device_state(&state)?;
    let mut output = output_prefix(operation, OUTCOME_OK)?;
    push_frame(&mut output, &next)?;
    output.extend_from_slice(&batch_id);
    push_frame(&mut output, &projection)?;
    push_u32(&mut output, state.bundle_version);
    push_u32(&mut output, state.current_classical.created_day);
    Ok(output)
}

fn operation_prune<P: CryptoProvider>(
    provider: &P,
    operation: u32,
    reader: &mut Reader<'_>,
) -> CryptoResult<Vec<u8>> {
    let encoded = reader.framed()?;
    let migration_day = reader.u32()?;
    let coarse_day = reader.u32()?;
    finish(reader)?;
    let mut state = decode_device_state(provider, encoded, migration_day)?;
    let erased: Vec<(u32, u32)> = state
        .retired
        .iter()
        .filter(|pair| coarse_day > pair.retain_through_day)
        .map(|pair| (pair.classical.id, pair.pq.id))
        .collect();
    state.prune_retired(coarse_day);
    let next = encode_device_state(&state)?;
    let mut output = output_prefix(operation, OUTCOME_OK)?;
    push_frame(&mut output, &next)?;
    append_device_summary(&mut output, &state)?;
    output.push(u8::try_from(erased.len()).map_err(|_| CryptoError::ResourceExhausted)?);
    for (spk_id, pq_spk_id) in erased {
        push_u32(&mut output, spk_id);
        push_u32(&mut output, pq_spk_id);
    }
    Ok(output)
}

fn parse_optional_classical(
    reader: &mut Reader<'_>,
) -> CryptoResult<Option<OptionalClassicalPrekey>> {
    if reader.boolean()? {
        Ok(Some(OptionalClassicalPrekey {
            id: valid_key_id(reader.u32()?)?,
            public: reader.array()?,
        }))
    } else {
        Ok(None)
    }
}

fn parse_optional_pq(reader: &mut Reader<'_>) -> CryptoResult<Option<OptionalPqPrekey>> {
    if reader.boolean()? {
        Ok(Some(OptionalPqPrekey {
            id: valid_key_id(reader.u32()?)?,
            public: reader.array()?,
        }))
    } else {
        Ok(None)
    }
}

fn operation_initiate<P: CryptoProvider>(
    provider: &P,
    operation: u32,
    reader: &mut Reader<'_>,
) -> CryptoResult<Vec<u8>> {
    let device_bytes = reader.framed()?;
    let migration_day = reader.u32()?;
    let sender_device_id = reader.array()?;
    let recipient_device_id = reader.array()?;
    let bundle_bytes = reader.framed()?;
    let classical = parse_optional_classical(reader)?;
    let pq = parse_optional_pq(reader)?;
    let repair_authorization = reader.framed()?;
    let inner = reader.framed()?;
    let other_sessions_skipped = reader.u32()?;
    finish(reader)?;
    let device = decode_device_state(provider, device_bytes, migration_day)?;
    let peer = PeerBundle::parse(bundle_bytes)?;
    let (state, envelope) = initiate(
        provider,
        &device,
        sender_device_id,
        recipient_device_id,
        &peer,
        classical,
        pq,
        repair_authorization,
        inner,
        other_sessions_skipped,
    )?;
    let encoded_state = state.encode(&device)?;
    let mut output = output_prefix(operation, OUTCOME_OK)?;
    push_frame(&mut output, &encoded_state)?;
    push_u32(&mut output, state.skipped_count());
    push_frame(&mut output, &envelope)?;
    output.extend_from_slice(&state.session_id);
    output.push(u8::from(
        sender_device_id.as_slice() > recipient_device_id.as_slice(),
    ));
    Ok(output)
}

fn operation_probe<P: CryptoProvider>(
    provider: &P,
    operation: u32,
    reader: &mut Reader<'_>,
) -> CryptoResult<Vec<u8>> {
    let device_bytes = reader.framed()?;
    let migration_day = reader.u32()?;
    let recipient_device_id = reader.array()?;
    let envelope = reader.framed()?;
    finish(reader)?;
    let device = decode_device_state(provider, device_bytes, migration_day)?;
    let probe = probe_initial(provider, &device, &recipient_device_id, envelope)?;
    let mut output = output_prefix(operation, OUTCOME_OK)?;
    output.extend_from_slice(&encode_probe_output(&probe));
    Ok(output)
}

fn operation_accept<P: CryptoProvider>(
    provider: &P,
    operation: u32,
    reader: &mut Reader<'_>,
) -> CryptoResult<Vec<u8>> {
    let device_bytes = reader.framed()?;
    let migration_day = reader.u32()?;
    let recipient_device_id = reader.array()?;
    let envelope = reader.framed()?;
    let probe_token = reader.array()?;
    let sender_projection_bytes = reader.framed()?;
    let existing_primary_state = reader.framed()?;
    let replaced_state = reader.framed()?;
    let other_sessions_skipped = reader.u32()?;
    finish(reader)?;
    if usize::try_from(other_sessions_skipped).map_err(|_| CryptoError::ResourceExhausted)?
        > MAX_SKIPPED_ACCOUNT
    {
        return Err(CryptoError::ResourceExhausted);
    }
    let device = decode_device_state(provider, device_bytes, migration_day)?;
    let sender = AuthenticatedSenderProjection::parse(sender_projection_bytes)?;
    let accepted = accept_initial(
        provider,
        device,
        recipient_device_id,
        envelope,
        probe_token,
        &sender,
        existing_primary_state,
        replaced_state,
    )?;
    let mut output = output_prefix(operation, OUTCOME_OK)?;
    push_frame(&mut output, &accepted.next_device_state)?;
    push_frame(&mut output, &accepted.session_state)?;
    push_u32(&mut output, accepted.session.skipped_count());
    push_frame(&mut output, &accepted.inner)?;
    output.extend_from_slice(&accepted.replay_marker);
    push_u32(&mut output, accepted.consumed_classical_id);
    push_u32(&mut output, accepted.consumed_pq_id);
    output.push(accepted.disposition);
    push_frame(&mut output, &accepted.updated_existing_state)?;
    match accepted.replaced_session_id {
        Some(session_id) => {
            output.push(1);
            output.extend_from_slice(&session_id);
        }
        None => output.push(0),
    }
    output.extend_from_slice(&accepted.session.session_id);
    push_u32(&mut output, accepted.referenced_signed_prekey_id);
    push_u32(&mut output, accepted.referenced_pq_signed_prekey_id);
    Ok(output)
}

fn operation_encrypt<P: CryptoProvider>(
    provider: &P,
    operation: u32,
    reader: &mut Reader<'_>,
) -> CryptoResult<Vec<u8>> {
    let device_bytes = reader.framed()?;
    let migration_day = reader.u32()?;
    let recipient_device_id = reader.array()?;
    let state_bytes = reader.framed()?;
    let inner = reader.framed()?;
    let other_sessions_skipped = reader.u32()?;
    finish(reader)?;
    let device = decode_device_state(provider, device_bytes, migration_day)?;
    let state = RatchetState::decode(provider, &device, state_bytes)?;
    let transition = ratchet_encrypt(
        provider,
        state,
        recipient_device_id,
        inner,
        other_sessions_skipped,
    )?;
    let encoded_state = transition.state.encode(&device)?;
    let mut output = output_prefix(operation, OUTCOME_OK)?;
    push_frame(&mut output, &encoded_state)?;
    push_u32(&mut output, transition.state.skipped_count());
    push_frame(&mut output, &transition.envelope)?;
    output.extend_from_slice(&transition.state.session_id);
    Ok(output)
}

fn operation_decrypt<P: CryptoProvider>(
    provider: &P,
    operation: u32,
    reader: &mut Reader<'_>,
) -> CryptoResult<Vec<u8>> {
    let device_bytes = reader.framed()?;
    let migration_day = reader.u32()?;
    let recipient_device_id = reader.array()?;
    let state_bytes = reader.framed()?;
    let envelope = reader.framed()?;
    let other_sessions_skipped = reader.u32()?;
    finish(reader)?;
    let device = decode_device_state(provider, device_bytes, migration_day)?;
    let state = RatchetState::decode(provider, &device, state_bytes)?;
    match ratchet_decrypt(
        provider,
        state,
        recipient_device_id,
        envelope,
        other_sessions_skipped,
    )? {
        ReceiveOutcome::RepairRequired => {
            let mut output = output_prefix(operation, OUTCOME_REPAIR_REQUIRED)?;
            output.push(REPAIR_REASON_SKIPPED_LIMIT);
            Ok(output)
        }
        ReceiveOutcome::Prepared(transition) => {
            let encoded_state = transition.state.encode(&device)?;
            let mut output = output_prefix(operation, OUTCOME_OK)?;
            push_frame(&mut output, &encoded_state)?;
            push_u32(&mut output, transition.state.skipped_count());
            push_frame(&mut output, &transition.inner)?;
            output.extend_from_slice(&transition.replay_marker);
            output.push(transition.payload_kind);
            output.extend_from_slice(&transition.state.session_id);
            push_u32(&mut output, ABSENT_PREKEY_ID);
            push_u32(&mut output, ABSENT_PREKEY_ID);
            Ok(output)
        }
    }
}

fn operation_create_repair<P: CryptoProvider>(
    provider: &P,
    operation: u32,
    reader: &mut Reader<'_>,
) -> CryptoResult<Vec<u8>> {
    let device_bytes = reader.framed()?;
    let migration_day = reader.u32()?;
    let recipient_device_id = reader.array()?;
    let state_bytes = reader.framed()?;
    let other_sessions_skipped = reader.u32()?;
    finish(reader)?;
    let device = decode_device_state(provider, device_bytes, migration_day)?;
    let state = RatchetState::decode(provider, &device, state_bytes)?;
    let transition = create_repair(provider, state, recipient_device_id, other_sessions_skipped)?;
    let encoded_state = transition.state.encode(&device)?;
    let mut output = output_prefix(operation, OUTCOME_OK)?;
    push_frame(&mut output, &encoded_state)?;
    push_u32(&mut output, transition.state.skipped_count());
    push_frame(&mut output, &transition.envelope)?;
    output.extend_from_slice(&transition.state.session_id);
    Ok(output)
}

fn operation_consume_repair<P: CryptoProvider>(
    provider: &P,
    operation: u32,
    reader: &mut Reader<'_>,
) -> CryptoResult<Vec<u8>> {
    let device_bytes = reader.framed()?;
    let migration_day = reader.u32()?;
    let state_bytes = reader.framed()?;
    finish(reader)?;
    let device = decode_device_state(provider, device_bytes, migration_day)?;
    let state = RatchetState::decode(provider, &device, state_bytes)?;
    let (state, authorization) = consume_repair_authorization(&device, state)?;
    let encoded_state = state.encode(&device)?;
    let mut output = output_prefix(operation, OUTCOME_OK)?;
    push_frame(&mut output, &encoded_state)?;
    push_u32(&mut output, state.skipped_count());
    push_frame(&mut output, &authorization)?;
    output.extend_from_slice(&state.session_id);
    Ok(output)
}

#[allow(clippy::too_many_arguments)]
fn accept_initial<P: CryptoProvider>(
    provider: &P,
    mut device: DeviceState,
    recipient_device_id: [u8; 16],
    envelope_bytes: &[u8],
    supplied_probe_token: [u8; 32],
    sender: &AuthenticatedSenderProjection,
    existing_primary_state_bytes: &[u8],
    replaced_state_bytes: &[u8],
) -> CryptoResult<AcceptedInitial> {
    let probe = probe_initial(provider, &device, &recipient_device_id, envelope_bytes)?;
    if !bool::from(probe.probe_token.ct_eq(&supplied_probe_token))
        || probe.sender.sender_user_id != sender.user_id
        || probe.sender.sender_device_id != sender.device_id
        || probe.sender.sender_ik_public != sender.ik_public
        || probe.sender.sender_registration_id != sender.registration_id
        // The sender may have atomically rotated after this envelope was
        // queued. Its signed-prekeys are not used for receive authentication;
        // the authenticated live-set IK and the init signature are. Accept an
        // older nonzero sender version, but never a claimed future version.
        || probe.sender.sender_bundle_version > sender.bundle_version
        || sender.device_id == recipient_device_id
    {
        return Err(CryptoError::AuthenticationFailed);
    }
    let envelope = Envelope::parse(envelope_bytes)?;
    let RatchetHeader::Initial(header) = &envelope.header else {
        return Err(CryptoError::StateViolation);
    };
    let prefix_len = envelope
        .header_bytes
        .len()
        .checked_sub(2 + header.sender_seal.len())
        .ok_or(CryptoError::MalformedInput)?;
    let header_prefix = &envelope.header_bytes[..prefix_len];
    let sender_prefix = probe.sender.prefix_bytes();
    let signature_input =
        init_signature_input(&recipient_device_id, header_prefix, &sender_prefix)?;
    provider.ed25519_verify(
        &sender.device_signing_public(),
        &signature_input,
        &probe.sender.init_signature,
    )?;

    let replaced_session_id = match probe.sender.repair.as_ref() {
        Some((old_session_id, repair_token)) => {
            if replaced_state_bytes.is_empty() || !existing_primary_state_bytes.is_empty() {
                return Err(CryptoError::StateViolation);
            }
            let old_state = RatchetState::decode(provider, &device, replaced_state_bytes)?;
            if old_state.session_id != *old_session_id
                || old_state.local_device_id != recipient_device_id
                || old_state.remote_device_id != sender.device_id
                || old_state.issued_repair_token.as_ref() != Some(repair_token)
            {
                return Err(CryptoError::AuthenticationFailed);
            }
            Some(*old_session_id)
        }
        None => {
            if !replaced_state_bytes.is_empty() {
                return Err(CryptoError::StateViolation);
            }
            None
        }
    };

    let mut existing_primary = if existing_primary_state_bytes.is_empty() {
        None
    } else {
        if probe.sender.repair.is_some() {
            return Err(CryptoError::StateViolation);
        }
        let existing = RatchetState::decode(provider, &device, existing_primary_state_bytes)?;
        if existing.local_device_id != recipient_device_id
            || existing.remote_device_id != sender.device_id
            || existing.initiator_device_id != recipient_device_id
            || !existing.primary
            || existing.receive_only
        {
            return Err(CryptoError::StateViolation);
        }
        Some(existing)
    };

    let signed_classical = device
        .signed_classical(header.signed_prekey_id)
        .ok_or(CryptoError::AuthenticationFailed)?;
    let initial_secrets = responder_initial_secrets(provider, &device, header)?;
    let dh1 = provider.x25519_shared(
        &SecretBytes::new(signed_classical.secret),
        &sender.identity_public(),
    )?;
    let dh2 = provider.x25519_shared(
        &SecretBytes::new(device.identity_secret),
        &header.ephemeral_public,
    )?;
    let mut pqxdh_ikm = Zeroizing::new(Vec::new());
    pqxdh_ikm.extend_from_slice(&[0xff; 32]);
    pqxdh_ikm.extend_from_slice(dh1.expose());
    pqxdh_ikm.extend_from_slice(dh2.expose());
    pqxdh_ikm.extend_from_slice(&initial_secrets.dh3);
    if let Some(dh4) = initial_secrets.dh4 {
        pqxdh_ikm.extend_from_slice(&dh4);
    }
    pqxdh_ikm.extend_from_slice(&initial_secrets.signed_pq);
    if let Some(one_time_pq) = initial_secrets.one_time_pq {
        pqxdh_ikm.extend_from_slice(&one_time_pq);
    }
    let shared_secret = pqxdh_secret(&pqxdh_ikm)?;
    let ratchet_dh = provider.x25519_shared(
        &SecretBytes::new(signed_classical.secret),
        &header.ratchet_public,
    )?;
    let (root_key, receiving_chain) = kdf_root(shared_secret.expose(), ratchet_dh.expose())?;
    let (message_key, next_receiving_chain) = chain_step(receiving_chain.expose())?;
    let inner = decrypt_envelope(
        provider,
        &recipient_device_id,
        &envelope,
        message_key.expose(),
    )?;
    let transcript_hash = provider.sha256(envelope.header_bytes)?;
    let incoming_wins = probe.sender.repair.is_some()
        || existing_primary.is_none()
        || sender.device_id.as_slice() < recipient_device_id.as_slice();
    let disposition = u8::from(!incoming_wins);
    let updated_existing_state = if incoming_wins {
        if let Some(existing) = existing_primary.as_mut() {
            if let Some(chain) = existing.sending_chain.as_mut() {
                chain.zeroize();
            }
            existing.sending_chain = None;
            existing.primary = false;
            existing.receive_only = true;
            existing.encode(&device)?
        } else {
            Vec::new()
        }
    } else {
        Vec::new()
    };
    let session = RatchetState {
        session_id: header.session_id,
        local_device_id: recipient_device_id,
        remote_device_id: sender.device_id,
        initiator_device_id: sender.device_id,
        transcript_hash,
        primary: incoming_wins,
        receive_only: !incoming_wins,
        root_key: *root_key.expose(),
        sending_chain: None,
        receiving_chain: Some(*next_receiving_chain.expose()),
        local_ratchet_secret: signed_classical.secret,
        local_ratchet_public: signed_classical.public,
        remote_ratchet_public: header.ratchet_public,
        send_count: 0,
        receive_count: 1,
        previous_send_count: 0,
        skipped: Vec::new(),
        issued_repair_token: None,
        received_repair_token: None,
    };
    let consumed_classical_id = if header.flags & FLAG_CLASSICAL_ONE_TIME != 0 {
        device.consume_classical_one_time(header.one_time_prekey_id)?;
        header.one_time_prekey_id
    } else {
        ABSENT_PREKEY_ID
    };
    let consumed_pq_id = if header.flags & FLAG_PQ_ONE_TIME != 0 {
        device.consume_pq_one_time(header.pq_one_time_prekey_id)?;
        header.pq_one_time_prekey_id
    } else {
        ABSENT_PREKEY_ID
    };
    let session_state = session.encode(&device)?;
    let next_device_state = encode_device_state(&device)?;
    Ok(AcceptedInitial {
        next_device_state,
        session,
        session_state,
        inner,
        replay_marker: provider.sha256(envelope_bytes)?,
        consumed_classical_id,
        consumed_pq_id,
        disposition,
        updated_existing_state,
        replaced_session_id,
        referenced_signed_prekey_id: header.signed_prekey_id,
        referenced_pq_signed_prekey_id: header.pq_signed_prekey_id,
    })
}

#[cfg(test)]
mod tests {
    use ed25519_dalek::SigningKey;

    use super::*;
    use crate::{
        device_signatures::{
            DeviceBundle, IkPublic, PublicPrekey, RawUuid, encode_cross_signature,
        },
        enrollment::prepare_device_with_provider,
        random::FixedRandomProvider,
    };

    const DAY: u32 = 20_302;
    const ALICE_USER: [u8; 16] = [0x11; 16];
    const ALICE_DEVICE: [u8; 16] = [0x21; 16];
    const BOB_USER: [u8; 16] = [0x31; 16];
    const BOB_DEVICE: [u8; 16] = [0x41; 16];

    fn bytes(seed: u8, length: usize) -> Vec<u8> {
        (0..length)
            .map(|index| {
                seed.wrapping_add(
                    u8::try_from(index % 251)
                        .expect("modulo is byte sized")
                        .wrapping_mul(17),
                )
            })
            .collect()
    }

    fn fixed_provider(seed: u8, length: usize) -> RustCryptoProvider<FixedRandomProvider> {
        RustCryptoProvider::new(FixedRandomProvider::new(bytes(seed, length)))
    }

    struct PublicDevice {
        user_id: [u8; 16],
        registration_id: u32,
        ik_public: [u8; 64],
        spk_id: u32,
        spk_public: [u8; 32],
        spk_signature: [u8; 64],
        pq_spk_id: u32,
        pq_spk_public: [u8; MLKEM768_PUBLIC_BYTES],
        pq_spk_signature: [u8; 64],
    }

    fn public_device(package: &[u8]) -> PublicDevice {
        let mut reader = Reader::new(package);
        assert_eq!(reader.take(8).unwrap(), b"CPDVV001");
        let user_id = reader.array().unwrap();
        let registration_id = reader.u32().unwrap();
        let spk_id = reader.u32().unwrap();
        let pq_spk_id = reader.u32().unwrap();
        let _classical_count = reader.u16().unwrap();
        let _pq_count = reader.u16().unwrap();
        PublicDevice {
            user_id,
            registration_id,
            ik_public: reader.array().unwrap(),
            spk_id,
            spk_public: reader.array().unwrap(),
            spk_signature: reader.array().unwrap(),
            pq_spk_id,
            pq_spk_public: reader.array().unwrap(),
            pq_spk_signature: reader.array().unwrap(),
        }
    }

    fn claimed_bundle(
        package: &[u8],
        device_id: [u8; 16],
        self_signing_secret: [u8; 32],
        include_pq: bool,
    ) -> Vec<u8> {
        let public = public_device(package);
        let provider = RustCryptoProvider::default();
        let self_signing_public = SigningKey::from_bytes(&self_signing_secret)
            .verifying_key()
            .to_bytes();
        let ik = IkPublic::try_from_bytes(&public.ik_public).unwrap();
        let cross_bytes = encode_cross_signature(&DeviceBundle {
            user_id: RawUuid::new(public.user_id),
            device_id: RawUuid::new(device_id),
            ik_public: ik,
            spk_id: public.spk_id,
            spk_public: &public.spk_public,
            pq_signed_prekey: include_pq.then_some(PublicPrekey {
                id: public.pq_spk_id,
                public: &public.pq_spk_public,
            }),
            registration_id: public.registration_id,
            bundle_version: 1,
        })
        .unwrap();
        let cross_signature = provider
            .ed25519_sign(&SecretBytes::new(self_signing_secret), &cross_bytes)
            .unwrap();
        let mut output = Vec::new();
        output.extend_from_slice(VERIFY_BUNDLE_MAGIC);
        output.extend_from_slice(&public.user_id);
        output.extend_from_slice(&device_id);
        output.extend_from_slice(&self_signing_public);
        output.extend_from_slice(&public.ik_public);
        push_u32(&mut output, public.spk_id);
        push_frame(&mut output, &public.spk_public).unwrap();
        output.extend_from_slice(&public.spk_signature);
        output.push(u8::from(include_pq));
        if include_pq {
            push_u32(&mut output, public.pq_spk_id);
            push_frame(&mut output, &public.pq_spk_public).unwrap();
            output.extend_from_slice(&public.pq_spk_signature);
        }
        push_u32(&mut output, public.registration_id);
        push_u32(&mut output, 1);
        output.extend_from_slice(&cross_signature);
        output
    }

    fn sender_projection(device: &DeviceState, device_id: &[u8; 16]) -> Vec<u8> {
        sender_projection_at_version(device, device_id, device.bundle_version)
    }

    fn sender_projection_at_version(
        device: &DeviceState,
        device_id: &[u8; 16],
        bundle_version: u32,
    ) -> Vec<u8> {
        let mut output = Vec::new();
        output.extend_from_slice(SENDER_PROJECTION_MAGIC);
        output.extend_from_slice(&device.user_id);
        output.extend_from_slice(device_id);
        output.extend_from_slice(device.ik_public().as_bytes());
        push_u32(&mut output, device.registration_id);
        push_u32(&mut output, bundle_version);
        output
    }

    fn devices() -> (Vec<u8>, DeviceState, Vec<u8>, DeviceState) {
        let alice_package =
            prepare_device_with_provider(&fixed_provider(3, 20_000), &ALICE_USER).unwrap();
        let bob_package =
            prepare_device_with_provider(&fixed_provider(97, 20_000), &BOB_USER).unwrap();
        let provider = RustCryptoProvider::default();
        let alice = decode_device_state(&provider, &alice_package, DAY).unwrap();
        let bob = decode_device_state(&provider, &bob_package, DAY).unwrap();
        (alice_package, alice, bob_package, bob)
    }

    #[test]
    fn mandatory_signed_pq_and_optional_one_time_material_round_trip() {
        let (alice_package, alice, bob_package, bob) = devices();
        let bob_bundle_bytes = claimed_bundle(&bob_package, BOB_DEVICE, [0x52; 32], true);
        let bob_bundle = PeerBundle::parse(&bob_bundle_bytes).unwrap();
        let classical = bob
            .classical_one_time
            .first()
            .map(|key| OptionalClassicalPrekey {
                id: key.id,
                public: key.public,
            });
        let pq = bob.pq_one_time.first().map(|key| OptionalPqPrekey {
            id: key.id,
            public: key.public,
        });
        let (alice_session, initial) = initiate(
            &fixed_provider(13, 100_000),
            &alice,
            ALICE_DEVICE,
            BOB_DEVICE,
            &bob_bundle,
            classical,
            pq,
            &[],
            b"first opaque payload",
            0,
        )
        .unwrap();
        let session_id = alice_session.session_id;
        assert_eq!(initial.len(), 4096);
        assert_eq!(
            inspect_public_header(&initial).unwrap(),
            (ENVELOPE_KIND_INITIAL, session_id)
        );
        assert!(
            !initial
                .windows(ALICE_USER.len())
                .any(|window| window == ALICE_USER)
        );
        assert!(
            !initial
                .windows(ALICE_DEVICE.len())
                .any(|window| window == ALICE_DEVICE)
        );

        let provider = RustCryptoProvider::default();
        let probe = probe_initial(&provider, &bob, &BOB_DEVICE, &initial).unwrap();
        assert_eq!(probe.sender.sender_user_id, ALICE_USER);
        assert_eq!(probe.sender.sender_device_id, ALICE_DEVICE);
        let accepted = accept_initial(
            &provider,
            bob,
            BOB_DEVICE,
            &initial,
            probe.probe_token,
            // This live-set projection is newer than the queued initial. The
            // stable device IK/signature authenticates the delayed message.
            &AuthenticatedSenderProjection::parse(&sender_projection_at_version(
                &alice,
                &ALICE_DEVICE,
                alice.bundle_version + 1,
            ))
            .unwrap(),
            &[],
            &[],
        )
        .unwrap();
        assert_eq!(accepted.inner, b"first opaque payload");
        assert_eq!(accepted.session.root_key, alice_session.root_key);
        assert_eq!(
            accepted.session.receiving_chain,
            alice_session.sending_chain
        );
        assert_eq!(accepted.consumed_classical_id, classical.unwrap().id);
        assert_eq!(accepted.consumed_pq_id, pq.unwrap().id);
        assert_eq!(accepted.replay_marker, provider.sha256(&initial).unwrap());

        let next_bob = decode_device_state(&provider, &accepted.next_device_state, DAY).unwrap();
        assert!(
            next_bob
                .classical_one_time(accepted.consumed_classical_id)
                .is_none()
        );
        assert!(next_bob.pq_one_time(accepted.consumed_pq_id).is_none());

        // Bob's first reply creates his sending ratchet. Alice authenticates
        // the new ratchet and advances both root directions.
        let reply = ratchet_encrypt(
            &fixed_provider(29, 20_000),
            accepted.session,
            ALICE_DEVICE,
            b"reply",
            0,
        )
        .unwrap();
        let ReceiveOutcome::Prepared(opened) = ratchet_decrypt(
            &fixed_provider(47, 20_000),
            alice_session,
            ALICE_DEVICE,
            &reply.envelope,
            0,
        )
        .unwrap() else {
            panic!("ordinary reply requested repair");
        };
        assert_eq!(opened.inner, b"reply");
        assert_eq!(
            inspect_public_header(&reply.envelope).unwrap(),
            (ENVELOPE_KIND_REGULAR, session_id)
        );

        let mut inspect_request = Vec::new();
        inspect_request.extend_from_slice(REQUEST_MAGIC);
        push_frame(&mut inspect_request, &reply.envelope).unwrap();
        let inspect_output = operation_with_provider(
            &RustCryptoProvider::default(),
            OP_INSPECT_PUBLIC_HEADER,
            &inspect_request,
        )
        .unwrap();
        assert_eq!(&inspect_output[..10], b"CPPWO001\x11\x00");
        assert_eq!(inspect_output[10], ENVELOPE_KIND_REGULAR);
        assert_eq!(&inspect_output[11..], &session_id);

        // Recipient, purpose, and ratchet-header mutations are authenticated.
        let alice_state_snapshot = opened.state.encode(&alice).unwrap();
        let snapshot = RatchetState::decode(&provider, &alice, &alice_state_snapshot).unwrap();
        assert!(matches!(
            ratchet_decrypt(
                &fixed_provider(47, 20_000),
                snapshot,
                BOB_DEVICE,
                &reply.envelope,
                0,
            ),
            Err(CryptoError::AuthenticationFailed)
        ));

        let _ = alice_package;
    }

    #[test]
    fn missing_signed_pq_has_no_classical_fallback() {
        let (_alice_package, _alice, bob_package, _bob) = devices();
        let classical_only = claimed_bundle(&bob_package, BOB_DEVICE, [0x52; 32], false);
        assert!(matches!(
            PeerBundle::parse(&classical_only),
            Err(CryptoError::AuthenticationFailed)
        ));
    }

    #[test]
    fn zero_registration_id_is_canonical_and_supported() {
        let mut package =
            prepare_device_with_provider(&fixed_provider(61, 20_000), &BOB_USER).unwrap();
        package[24..28].copy_from_slice(&0u32.to_be_bytes());
        let provider = RustCryptoProvider::default();
        let state = decode_device_state(&provider, &package, DAY).unwrap();
        assert_eq!(state.registration_id, 0);
        let bundle = claimed_bundle(&package, BOB_DEVICE, [0x62; 32], true);
        assert!(PeerBundle::parse(&bundle).is_ok());
        let projection = sender_projection(&state, &BOB_DEVICE);
        assert_eq!(
            AuthenticatedSenderProjection::parse(&projection)
                .unwrap()
                .registration_id,
            0
        );
    }

    #[test]
    fn state_mac_is_bound_to_the_device_secret_and_replay_fails() {
        let (_alice_package, alice, bob_package, bob) = devices();
        let bundle =
            PeerBundle::parse(&claimed_bundle(&bob_package, BOB_DEVICE, [0x52; 32], true)).unwrap();
        let (state, _) = initiate(
            &fixed_provider(71, 50_000),
            &alice,
            ALICE_DEVICE,
            BOB_DEVICE,
            &bundle,
            None,
            None,
            &[],
            b"state",
            0,
        )
        .unwrap();
        let encoded = state.encode(&alice).unwrap();
        let provider = RustCryptoProvider::default();
        assert!(RatchetState::decode(&provider, &alice, &encoded).is_ok());
        assert!(matches!(
            RatchetState::decode(&provider, &bob, &encoded),
            Err(CryptoError::AuthenticationFailed)
        ));

        // Recompute the obsolete root-only MAC after changing the root. It is
        // still rejected because the actual key also requires Alice's device
        // identity secret.
        let mut forged = encoded.clone();
        const ROOT_OFFSET: usize = 8 + 1 + 16 * 4 + 32;
        forged[ROOT_OFFSET] ^= 1;
        let forged_root: [u8; 32] = forged[ROOT_OFFSET..ROOT_OFFSET + 32].try_into().unwrap();
        let obsolete_key = hkdf_sha256(&[0; 32], &forged_root, STATE_AUTH_DOMAIN, 32).unwrap();
        let authenticated_len = forged.len() - 32;
        let obsolete_tag = hmac_sha256(&obsolete_key, &forged[..authenticated_len]).unwrap();
        forged[authenticated_len..].copy_from_slice(&obsolete_tag);
        assert!(matches!(
            RatchetState::decode(&provider, &alice, &forged),
            Err(CryptoError::AuthenticationFailed)
        ));
    }

    #[test]
    fn skipped_limits_return_typed_repair_without_a_transition() {
        let (_alice_package, alice, bob_package, bob) = devices();
        let bundle =
            PeerBundle::parse(&claimed_bundle(&bob_package, BOB_DEVICE, [0x52; 32], true)).unwrap();
        let (mut state, _) = initiate(
            &fixed_provider(83, 50_000),
            &alice,
            ALICE_DEVICE,
            BOB_DEVICE,
            &bundle,
            None,
            None,
            &[],
            b"limit",
            0,
        )
        .unwrap();
        // Model an established receiving chain and a regular message 2,001
        // positions ahead. The bound is checked before AEAD or allocation.
        state.receiving_chain = Some([0x44; 32]);
        state.receive_count = 1;
        state.remote_ratchet_public = bob.current_classical.public;
        let mut header = Vec::new();
        header.push(HEADER_VERSION);
        header.push(0);
        header.extend_from_slice(&state.session_id);
        header.extend_from_slice(&state.remote_ratchet_public);
        push_u32(&mut header, 0);
        push_u32(&mut header, 2_002);
        let mut envelope = Vec::new();
        envelope.push(PROTOCOL_VERSION);
        envelope.push(SUITE);
        push_u16(&mut envelope, u16::try_from(header.len()).unwrap());
        envelope.extend_from_slice(&header);
        envelope.resize(1_024, 0);
        assert!(matches!(
            ratchet_decrypt(
                &fixed_provider(91, 20_000),
                state,
                ALICE_DEVICE,
                &envelope,
                0,
            )
            .unwrap(),
            ReceiveOutcome::RepairRequired
        ));
    }

    fn vector_hex(value: &serde_json::Value, field: &str) -> Vec<u8> {
        let encoded = value[field].as_str().expect("vector field is a string");
        assert_eq!(encoded.len() % 2, 0, "hex must contain whole bytes");
        encoded
            .as_bytes()
            .chunks_exact(2)
            .map(|pair| {
                u8::from_str_radix(std::str::from_utf8(pair).expect("vector hex is ASCII"), 16)
                    .expect("vector hex is valid")
            })
            .collect()
    }

    fn vector_array<const N: usize>(value: &serde_json::Value, field: &str) -> [u8; N] {
        vector_hex(value, field)
            .try_into()
            .unwrap_or_else(|bytes: Vec<u8>| {
                panic!("{field} has {} bytes, expected {N}", bytes.len())
            })
    }

    #[test]
    fn checked_in_project_vectors_pin_hybrid_composition_and_ratchet_kdfs() {
        let vectors: serde_json::Value =
            serde_json::from_str(include_str!("../vectors/pairwise-v1.json")).unwrap();
        assert_eq!(vectors["profile"], "pairwise-transport-v1");

        let composition = &vectors["composition"];
        let dh1 = vector_array::<32>(composition, "dh1");
        let dh2 = vector_array::<32>(composition, "dh2");
        let dh3 = vector_array::<32>(composition, "dh3");
        let dh4 = vector_array::<32>(composition, "dh4");
        let signed_pq = vector_array::<32>(composition, "signed_pq_shared_secret");
        let one_time_pq = vector_array::<32>(composition, "one_time_pq_shared_secret");
        let cases = composition["cases"].as_array().expect("cases are an array");
        assert_eq!(cases.len(), 4);
        for case in cases {
            let has_classical = case["classical_one_time"]
                .as_bool()
                .expect("classical flag is a bool");
            let has_pq = case["pq_one_time"].as_bool().expect("PQ flag is a bool");
            let mut pqxdh_ikm = vec![0xff; 32];
            pqxdh_ikm.extend_from_slice(&dh1);
            pqxdh_ikm.extend_from_slice(&dh2);
            pqxdh_ikm.extend_from_slice(&dh3);
            if has_classical {
                pqxdh_ikm.extend_from_slice(&dh4);
            }
            pqxdh_ikm.extend_from_slice(&signed_pq);
            if has_pq {
                pqxdh_ikm.extend_from_slice(&one_time_pq);
            }
            assert_eq!(
                pqxdh_secret(&pqxdh_ikm).unwrap().expose().as_slice(),
                vector_hex(case, "session_key")
            );

            let mut anonymous_ikm = dh3.to_vec();
            if has_classical {
                anonymous_ikm.extend_from_slice(&dh4);
            }
            anonymous_ikm.extend_from_slice(&signed_pq);
            if has_pq {
                anonymous_ikm.extend_from_slice(&one_time_pq);
            }
            let (key, nonce) = anonymous_material(&anonymous_ikm).unwrap();
            let mut material = key.expose().to_vec();
            material.extend_from_slice(&nonce);
            assert_eq!(material, vector_hex(case, "anonymous_sender_material"));
        }

        let ratchet = &vectors["ratchet_transition"];
        let root = vector_array::<32>(ratchet, "root_key");
        let dh = vector_array::<32>(ratchet, "dh_output");
        let (next_root, chain) = kdf_root(&root, &dh).unwrap();
        assert_eq!(
            next_root.expose(),
            &vector_array::<32>(ratchet, "next_root_key")
        );
        assert_eq!(chain.expose(), &vector_array::<32>(ratchet, "chain_key"));
        let (message, next_chain) = chain_step(chain.expose()).unwrap();
        assert_eq!(
            message.expose(),
            &vector_array::<32>(ratchet, "message_key")
        );
        assert_eq!(
            next_chain.expose(),
            &vector_array::<32>(ratchet, "next_chain_key")
        );
        let (aead_key, aead_nonce) = aead_material(message.expose()).unwrap();
        let mut aead = aead_key.expose().to_vec();
        aead.extend_from_slice(&aead_nonce);
        assert_eq!(aead, vector_hex(ratchet, "aead_material"));
        assert_eq!(
            state_auth_key(
                &root,
                &vector_array::<32>(ratchet, "device_identity_secret")
            )
            .unwrap()
            .expose(),
            &vector_array::<32>(ratchet, "device_bound_state_auth_key")
        );
    }

    #[test]
    fn pairwise_mux_bound_represents_every_frozen_profile_maximum() {
        const CLASSICAL_SIGNED_BYTES: usize = 4 + 4 + 32 + 64 + 32;
        const PQ_SIGNED_BYTES: usize = 4 + 4 + 1_184 + 64 + 2_400;
        const RETIRED_PAIR_BYTES: usize = 4 + CLASSICAL_SIGNED_BYTES + PQ_SIGNED_BYTES;
        const CLASSICAL_OTPK_BYTES: usize = 4 + 32 + 32;
        const PQ_OTPK_BYTES: usize = 4 + 1_184 + 2_400;
        const MAX_UPLOAD_PROJECTION: usize =
            8 + 16 + 1 + 4 + 2 + 200 * (4 + 32) + 2 + 100 * (4 + 1_184);
        const MAX_DEVICE_STATE: usize = 8
            + 16
            + 4 * 4
            + 32 * 4
            + CLASSICAL_SIGNED_BYTES
            + PQ_SIGNED_BYTES
            + 64
            + 1
            + 3 * RETIRED_PAIR_BYTES
            + 2
            + 400 * CLASSICAL_OTPK_BYTES
            + 2
            + 240 * PQ_OTPK_BYTES
            + 1
            + 1
            + 16
            + 4
            + MAX_UPLOAD_PROJECTION
            + 32;
        const MAX_SESSION_STATE: usize =
            8 + 1 + 16 * 4 + 32 * 2 + 33 * 2 + 32 * 3 + 4 * 3 + 2 + 2_000 * 68 + 33 * 2 + 32;
        const MAX_REGULAR_INNER: usize = 262_144 - 4 - REGULAR_HEADER_BYTES - 16 - 4;
        const MAX_ACCEPT_RESPONSE: usize = 10
            + 4
            + MAX_DEVICE_STATE
            + 4
            + MAX_SESSION_STATE
            + 4
            + 4
            + MAX_REGULAR_INNER
            + 32
            + 8
            + 1
            + 4
            + MAX_SESSION_STATE
            + 1
            + 16
            + 8;
        const {
            assert!(MAX_DEVICE_STATE == 1_029_824);
            assert!(MAX_ACCEPT_RESPONSE > crate::bounds::MAX_INPUT_BYTES);
            assert!(MAX_ACCEPT_RESPONSE < PAIRWISE_MAX_IO_BYTES);
        }
        assert_eq!(
            operation(OP_UPGRADE_DEVICE_STATE, &vec![0; PAIRWISE_MAX_IO_BYTES + 1]),
            Err(CryptoError::InputTooLarge)
        );
    }
}
