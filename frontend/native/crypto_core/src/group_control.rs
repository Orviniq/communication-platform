//! Version-1 signed control events for groups built on pairwise sessions.
//!
//! A group is a set of pairwise sessions (`backend/CLIENT_CONTRACT.md` §F). The
//! server holds no roster, so the roster exists only in its members' clients,
//! and every change to it is an event that one member's device signs and every
//! other member checks. This module owns that event's deterministic-CBOR
//! encoding, its Ed25519 signature under the device signing key, and the hash
//! that chains one accepted event to the next. Dart supplies and receives a
//! bounded projection frame; it never constructs or parses the CBOR and never
//! holds the key.

use minicbor::{decode::Decoder, encode::Encoder};

use crate::{
    application::{
        encode_key, peek, read_array_len, read_exact_bytes, read_exact_map, read_key, read_text,
        read_uint,
    },
    error::{CryptoError, CryptoResult},
    prekey_state::DeviceState,
    protocol::{Reader, push_frame, push_u16, push_u32, push_u64},
    provider::{CryptoProvider, ED25519_PUBLIC_BYTES, ED25519_SIGNATURE_BYTES},
    secret::SecretBytes,
};

pub(crate) const GROUP_CONTROL_VERSION: u8 = 1;
pub(crate) const MAX_GROUP_CONTROL_BYTES: usize = 16_384;
pub(crate) const GROUP_STATE_HASH_BYTES: usize = 32;

const SIGNATURE_DOMAIN: &[u8] = b"chat:v1:group-control";
const STATE_HASH_DOMAIN: &[u8] = b"chat:v1:group-control-state";

const KIND_CREATE: u8 = 1;
const KIND_ADD_MEMBER: u8 = 2;
const KIND_REMOVE_MEMBER: u8 = 3;
const KIND_CHANGE_ROLE: u8 = 4;
const KIND_RENAME: u8 = 5;

const ROLE_OWNER: u8 = 0;
const MAX_ROLE: u8 = 2;
const MAX_INVITATION_POLICY: u8 = 2;
const MAX_HISTORY_POLICY: u8 = 1;
const MAX_MEMBERS: usize = 50;
const MAX_NAME_BYTES: usize = 400;
const MAX_NAME_SCALARS: usize = 100;
const MAX_DESCRIPTION_BYTES: usize = 4_000;
const MAX_DESCRIPTION_SCALARS: usize = 1_000;
const MAX_CREATED_MS: u64 = 8_640_000_000_000_000;

#[derive(Clone, Debug, Eq, PartialEq)]
struct GroupControl {
    event_id: [u8; 16],
    group_id: [u8; 32],
    revision: u32,
    previous_state_hash: Option<[u8; GROUP_STATE_HASH_BYTES]>,
    signer_user_id: [u8; 16],
    signer_device_id: [u8; 16],
    created_ms: u64,
    body: ControlBody,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum ControlBody {
    Create {
        name: String,
        description: String,
        invitation_policy: u8,
        history_policy: u8,
        members: Vec<Member>,
    },
    AddMember {
        user_ids: Vec<[u8; 16]>,
    },
    RemoveMember {
        user_id: [u8; 16],
    },
    ChangeRole {
        user_id: [u8; 16],
        role: u8,
    },
    Rename {
        name: String,
        description: String,
    },
}

impl ControlBody {
    const fn kind(&self) -> u8 {
        match self {
            Self::Create { .. } => KIND_CREATE,
            Self::AddMember { .. } => KIND_ADD_MEMBER,
            Self::RemoveMember { .. } => KIND_REMOVE_MEMBER,
            Self::ChangeRole { .. } => KIND_CHANGE_ROLE,
            Self::Rename { .. } => KIND_RENAME,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Member {
    user_id: [u8; 16],
    role: u8,
}

/// A locally originated event, ready to be carried to every member.
pub(crate) struct SealedGroupControl {
    pub(crate) canonical: Vec<u8>,
    pub(crate) signature: [u8; ED25519_SIGNATURE_BYTES],
    pub(crate) state_hash: [u8; GROUP_STATE_HASH_BYTES],
}

/// A received event whose signature verified and whose encoding is canonical.
pub(crate) struct OpenedGroupControl {
    pub(crate) projection: Vec<u8>,
    pub(crate) state_hash: [u8; GROUP_STATE_HASH_BYTES],
}

/// Encodes a projected event, signs it with this device's signing key, and
/// returns the hash the next event in the group must name as its predecessor.
///
/// The signer named inside the event must be the account this device state
/// belongs to. The device identifier cannot be checked here, because the
/// native device state does not carry it; the caller that knows it names it,
/// and every recipient checks it against the authenticated device list.
pub(crate) fn seal<P: CryptoProvider>(
    provider: &P,
    device: &DeviceState,
    projection: &[u8],
) -> CryptoResult<SealedGroupControl> {
    let control = decode_projection(projection)?;
    if control.signer_user_id != device.user_id {
        return Err(CryptoError::InvalidArgument);
    }
    let canonical = encode_control(&control)?;
    let signature = provider.ed25519_sign(
        &SecretBytes::new(device.device_signing_secret),
        &with_domain(SIGNATURE_DOMAIN, &canonical)?,
    )?;
    let state_hash = state_hash(provider, &canonical)?;
    Ok(SealedGroupControl {
        canonical,
        signature,
        state_hash,
    })
}

/// Verifies an event against the signing key of the device that claims it,
/// then decodes it.
///
/// The signature is checked before a byte of the CBOR is interpreted, so an
/// event nobody signed never reaches the decoder. A signed event must still be
/// canonical: decoding re-encodes it and refuses any difference, so one event
/// has exactly one byte string and one state hash on every device.
pub(crate) fn open<P: CryptoProvider>(
    provider: &P,
    signing_public: &[u8; ED25519_PUBLIC_BYTES],
    canonical: &[u8],
    signature: &[u8; ED25519_SIGNATURE_BYTES],
) -> CryptoResult<OpenedGroupControl> {
    if canonical.is_empty() {
        return Err(CryptoError::MalformedInput);
    }
    if canonical.len() > MAX_GROUP_CONTROL_BYTES {
        return Err(CryptoError::InputTooLarge);
    }
    provider.ed25519_verify(
        signing_public,
        &with_domain(SIGNATURE_DOMAIN, canonical)?,
        signature,
    )?;
    let control = decode_control(canonical)?;
    let mut projection = Vec::new();
    encode_projection(&control, &mut projection)?;
    Ok(OpenedGroupControl {
        projection,
        state_hash: state_hash(provider, canonical)?,
    })
}

fn with_domain(domain: &[u8], canonical: &[u8]) -> CryptoResult<Vec<u8>> {
    let mut output = Vec::new();
    output
        .try_reserve_exact(domain.len() + 4 + canonical.len())
        .map_err(|_| CryptoError::ResourceExhausted)?;
    output.extend_from_slice(domain);
    push_frame(&mut output, canonical)?;
    Ok(output)
}

/// The hash an event commits the group to.
///
/// Every event but the first names its predecessor's hash inside its signed
/// bytes, so this is a hash chain over the accepted transcript: two devices
/// holding the same hash at the same revision hold the same history.
fn state_hash<P: CryptoProvider>(
    provider: &P,
    canonical: &[u8],
) -> CryptoResult<[u8; GROUP_STATE_HASH_BYTES]> {
    provider.sha256(&with_domain(STATE_HASH_DOMAIN, canonical)?)
}

fn validate(control: &GroupControl) -> CryptoResult<()> {
    let first = control.revision == 1;
    if control.revision == 0
        || first != matches!(control.body, ControlBody::Create { .. })
        || first != control.previous_state_hash.is_none()
        || control.created_ms > MAX_CREATED_MS
        || control.event_id == [0; 16]
        || control.group_id == [0; 32]
        || control.signer_user_id == [0; 16]
        || control.signer_device_id == [0; 16]
    {
        return Err(CryptoError::MalformedInput);
    }
    match &control.body {
        ControlBody::Create {
            name,
            description,
            invitation_policy,
            history_policy,
            members,
        } => {
            validate_metadata(name, description)?;
            if members.len() > MAX_MEMBERS {
                return Err(CryptoError::InputTooLarge);
            }
            let owners = members
                .iter()
                .filter(|member| member.role == ROLE_OWNER)
                .count();
            if *invitation_policy > MAX_INVITATION_POLICY
                || *history_policy > MAX_HISTORY_POLICY
                || members.is_empty()
                || owners != 1
                || members.iter().any(|member| member.role > MAX_ROLE)
                || !members
                    .windows(2)
                    .all(|pair| pair[0].user_id < pair[1].user_id)
            {
                return Err(CryptoError::MalformedInput);
            }
        }
        ControlBody::AddMember { user_ids } => {
            if user_ids.len() >= MAX_MEMBERS {
                return Err(CryptoError::InputTooLarge);
            }
            if user_ids.is_empty() || !user_ids.windows(2).all(|pair| pair[0] < pair[1]) {
                return Err(CryptoError::MalformedInput);
            }
        }
        ControlBody::RemoveMember { .. } => {}
        ControlBody::ChangeRole { role, .. } => {
            if *role > MAX_ROLE {
                return Err(CryptoError::MalformedInput);
            }
        }
        ControlBody::Rename { name, description } => validate_metadata(name, description)?,
    }
    Ok(())
}

fn validate_metadata(name: &str, description: &str) -> CryptoResult<()> {
    if name.len() > MAX_NAME_BYTES
        || name.chars().count() > MAX_NAME_SCALARS
        || description.len() > MAX_DESCRIPTION_BYTES
        || description.chars().count() > MAX_DESCRIPTION_SCALARS
    {
        return Err(CryptoError::InputTooLarge);
    }
    if name.is_empty() {
        return Err(CryptoError::MalformedInput);
    }
    Ok(())
}

fn written<T, E>(result: Result<T, E>) -> CryptoResult<()> {
    result.map(|_| ()).map_err(|_| CryptoError::InternalFailure)
}

fn length(value: usize) -> CryptoResult<u64> {
    u64::try_from(value).map_err(|_| CryptoError::InputTooLarge)
}

fn encode_control(control: &GroupControl) -> CryptoResult<Vec<u8>> {
    let mut output = Vec::new();
    output
        .try_reserve_exact(256)
        .map_err(|_| CryptoError::ResourceExhausted)?;
    let mut encoder = Encoder::new(&mut output);
    written(encoder.map(10))?;
    encode_key(&mut encoder, 0)?;
    written(encoder.u8(GROUP_CONTROL_VERSION))?;
    encode_key(&mut encoder, 1)?;
    written(encoder.bytes(&control.event_id))?;
    encode_key(&mut encoder, 2)?;
    written(encoder.bytes(&control.group_id))?;
    encode_key(&mut encoder, 3)?;
    written(encoder.u32(control.revision))?;
    encode_key(&mut encoder, 4)?;
    match &control.previous_state_hash {
        Some(hash) => written(encoder.bytes(hash))?,
        None => written(encoder.null())?,
    }
    encode_key(&mut encoder, 5)?;
    written(encoder.bytes(&control.signer_user_id))?;
    encode_key(&mut encoder, 6)?;
    written(encoder.bytes(&control.signer_device_id))?;
    encode_key(&mut encoder, 7)?;
    written(encoder.u64(control.created_ms))?;
    encode_key(&mut encoder, 8)?;
    written(encoder.u8(control.body.kind()))?;
    encode_key(&mut encoder, 9)?;
    match &control.body {
        ControlBody::Create {
            name,
            description,
            invitation_policy,
            history_policy,
            members,
        } => {
            written(encoder.map(5))?;
            encode_key(&mut encoder, 0)?;
            written(encoder.str(name))?;
            encode_key(&mut encoder, 1)?;
            written(encoder.str(description))?;
            encode_key(&mut encoder, 2)?;
            written(encoder.u8(*invitation_policy))?;
            encode_key(&mut encoder, 3)?;
            written(encoder.u8(*history_policy))?;
            encode_key(&mut encoder, 4)?;
            written(encoder.array(length(members.len())?))?;
            for member in members {
                written(encoder.array(2))?;
                written(encoder.bytes(&member.user_id))?;
                written(encoder.u8(member.role))?;
            }
        }
        ControlBody::AddMember { user_ids } => {
            written(encoder.map(1))?;
            encode_key(&mut encoder, 0)?;
            written(encoder.array(length(user_ids.len())?))?;
            for user_id in user_ids {
                written(encoder.bytes(user_id))?;
            }
        }
        ControlBody::RemoveMember { user_id } => {
            written(encoder.map(1))?;
            encode_key(&mut encoder, 0)?;
            written(encoder.bytes(user_id))?;
        }
        ControlBody::ChangeRole { user_id, role } => {
            written(encoder.map(2))?;
            encode_key(&mut encoder, 0)?;
            written(encoder.bytes(user_id))?;
            encode_key(&mut encoder, 1)?;
            written(encoder.u8(*role))?;
        }
        ControlBody::Rename { name, description } => {
            written(encoder.map(2))?;
            encode_key(&mut encoder, 0)?;
            written(encoder.str(name))?;
            encode_key(&mut encoder, 1)?;
            written(encoder.str(description))?;
        }
    }
    if output.len() > MAX_GROUP_CONTROL_BYTES {
        return Err(CryptoError::InputTooLarge);
    }
    Ok(output)
}

fn decode_control(input: &[u8]) -> CryptoResult<GroupControl> {
    let mut decoder = Decoder::new(input);
    read_exact_map(&mut decoder, 10)?;
    read_key(&mut decoder, 0)?;
    if read_uint(&mut decoder)? != u64::from(GROUP_CONTROL_VERSION) {
        return Err(CryptoError::UnsupportedVersion);
    }
    read_key(&mut decoder, 1)?;
    let event_id = read_exact_bytes(&mut decoder)?;
    read_key(&mut decoder, 2)?;
    let group_id = read_exact_bytes(&mut decoder)?;
    read_key(&mut decoder, 3)?;
    let revision =
        u32::try_from(read_uint(&mut decoder)?).map_err(|_| CryptoError::MalformedInput)?;
    read_key(&mut decoder, 4)?;
    let previous_state_hash = if peek(&decoder)? == 0xf6 {
        decoder.null().map_err(|_| CryptoError::MalformedInput)?;
        None
    } else {
        Some(read_exact_bytes(&mut decoder)?)
    };
    read_key(&mut decoder, 5)?;
    let signer_user_id = read_exact_bytes(&mut decoder)?;
    read_key(&mut decoder, 6)?;
    let signer_device_id = read_exact_bytes(&mut decoder)?;
    read_key(&mut decoder, 7)?;
    let created_ms = read_uint(&mut decoder)?;
    read_key(&mut decoder, 8)?;
    let kind = small(read_uint(&mut decoder)?)?;
    read_key(&mut decoder, 9)?;
    let body = decode_body(kind, &mut decoder)?;
    if decoder.position() != input.len() {
        return Err(CryptoError::MalformedInput);
    }
    let control = GroupControl {
        event_id,
        group_id,
        revision,
        previous_state_hash,
        signer_user_id,
        signer_device_id,
        created_ms,
        body,
    };
    validate(&control)?;
    // The readers already refuse the non-canonical forms they can see; this
    // catches the rest, such as a smaller integer type than the encoder writes.
    if encode_control(&control)? != input {
        return Err(CryptoError::MalformedInput);
    }
    Ok(control)
}

fn decode_body(kind: u8, decoder: &mut Decoder<'_>) -> CryptoResult<ControlBody> {
    match kind {
        KIND_CREATE => {
            read_exact_map(decoder, 5)?;
            read_key(decoder, 0)?;
            let name = read_text(decoder, MAX_NAME_BYTES, MAX_NAME_SCALARS, true)?;
            read_key(decoder, 1)?;
            let description = read_text(
                decoder,
                MAX_DESCRIPTION_BYTES,
                MAX_DESCRIPTION_SCALARS,
                false,
            )?;
            read_key(decoder, 2)?;
            let invitation_policy = small(read_uint(decoder)?)?;
            read_key(decoder, 3)?;
            let history_policy = small(read_uint(decoder)?)?;
            read_key(decoder, 4)?;
            let count = read_array_len(decoder)?;
            if count > MAX_MEMBERS {
                return Err(CryptoError::InputTooLarge);
            }
            let mut members = Vec::new();
            members
                .try_reserve_exact(count)
                .map_err(|_| CryptoError::ResourceExhausted)?;
            for _ in 0..count {
                if read_array_len(decoder)? != 2 {
                    return Err(CryptoError::MalformedInput);
                }
                let user_id = read_exact_bytes(decoder)?;
                let role = small(read_uint(decoder)?)?;
                members.push(Member { user_id, role });
            }
            Ok(ControlBody::Create {
                name,
                description,
                invitation_policy,
                history_policy,
                members,
            })
        }
        KIND_ADD_MEMBER => {
            read_exact_map(decoder, 1)?;
            read_key(decoder, 0)?;
            let count = read_array_len(decoder)?;
            if count >= MAX_MEMBERS {
                return Err(CryptoError::InputTooLarge);
            }
            let mut user_ids = Vec::new();
            user_ids
                .try_reserve_exact(count)
                .map_err(|_| CryptoError::ResourceExhausted)?;
            for _ in 0..count {
                user_ids.push(read_exact_bytes(decoder)?);
            }
            Ok(ControlBody::AddMember { user_ids })
        }
        KIND_REMOVE_MEMBER => {
            read_exact_map(decoder, 1)?;
            read_key(decoder, 0)?;
            Ok(ControlBody::RemoveMember {
                user_id: read_exact_bytes(decoder)?,
            })
        }
        KIND_CHANGE_ROLE => {
            read_exact_map(decoder, 2)?;
            read_key(decoder, 0)?;
            let user_id = read_exact_bytes(decoder)?;
            read_key(decoder, 1)?;
            Ok(ControlBody::ChangeRole {
                user_id,
                role: small(read_uint(decoder)?)?,
            })
        }
        KIND_RENAME => {
            read_exact_map(decoder, 2)?;
            read_key(decoder, 0)?;
            let name = read_text(decoder, MAX_NAME_BYTES, MAX_NAME_SCALARS, true)?;
            read_key(decoder, 1)?;
            let description = read_text(
                decoder,
                MAX_DESCRIPTION_BYTES,
                MAX_DESCRIPTION_SCALARS,
                false,
            )?;
            Ok(ControlBody::Rename { name, description })
        }
        _ => Err(CryptoError::UnsupportedOperation),
    }
}

fn small(value: u64) -> CryptoResult<u8> {
    u8::try_from(value).map_err(|_| CryptoError::MalformedInput)
}

fn decode_projection(input: &[u8]) -> CryptoResult<GroupControl> {
    let mut reader = Reader::new(input);
    if reader.u8()? != GROUP_CONTROL_VERSION {
        return Err(CryptoError::UnsupportedVersion);
    }
    let event_id = reader.array()?;
    let group_id = reader.array()?;
    let revision = reader.u32()?;
    let previous_state_hash = match reader.u8()? {
        0 => None,
        1 => Some(reader.array()?),
        _ => return Err(CryptoError::MalformedInput),
    };
    let signer_user_id = reader.array()?;
    let signer_device_id = reader.array()?;
    let created_ms = reader.u64()?;
    let body = match reader.u8()? {
        KIND_CREATE => {
            let name = projection_text(&mut reader, MAX_NAME_BYTES, MAX_NAME_SCALARS)?;
            let description =
                projection_text(&mut reader, MAX_DESCRIPTION_BYTES, MAX_DESCRIPTION_SCALARS)?;
            let invitation_policy = reader.u8()?;
            let history_policy = reader.u8()?;
            let count = usize::from(reader.u16()?);
            if count > MAX_MEMBERS {
                return Err(CryptoError::InputTooLarge);
            }
            let mut members = Vec::new();
            members
                .try_reserve_exact(count)
                .map_err(|_| CryptoError::ResourceExhausted)?;
            for _ in 0..count {
                let user_id = reader.array()?;
                let role = reader.u8()?;
                members.push(Member { user_id, role });
            }
            ControlBody::Create {
                name,
                description,
                invitation_policy,
                history_policy,
                members,
            }
        }
        KIND_ADD_MEMBER => {
            let count = usize::from(reader.u16()?);
            if count >= MAX_MEMBERS {
                return Err(CryptoError::InputTooLarge);
            }
            let mut user_ids = Vec::new();
            user_ids
                .try_reserve_exact(count)
                .map_err(|_| CryptoError::ResourceExhausted)?;
            for _ in 0..count {
                user_ids.push(reader.array()?);
            }
            ControlBody::AddMember { user_ids }
        }
        KIND_REMOVE_MEMBER => ControlBody::RemoveMember {
            user_id: reader.array()?,
        },
        KIND_CHANGE_ROLE => ControlBody::ChangeRole {
            user_id: reader.array()?,
            role: reader.u8()?,
        },
        KIND_RENAME => ControlBody::Rename {
            name: projection_text(&mut reader, MAX_NAME_BYTES, MAX_NAME_SCALARS)?,
            description: projection_text(
                &mut reader,
                MAX_DESCRIPTION_BYTES,
                MAX_DESCRIPTION_SCALARS,
            )?,
        },
        _ => return Err(CryptoError::UnsupportedOperation),
    };
    if !reader.is_finished() {
        return Err(CryptoError::MalformedInput);
    }
    let control = GroupControl {
        event_id,
        group_id,
        revision,
        previous_state_hash,
        signer_user_id,
        signer_device_id,
        created_ms,
        body,
    };
    validate(&control)?;
    Ok(control)
}

fn projection_text(
    reader: &mut Reader<'_>,
    maximum_bytes: usize,
    maximum_scalars: usize,
) -> CryptoResult<String> {
    let bytes = reader.framed()?;
    if bytes.len() > maximum_bytes {
        return Err(CryptoError::InputTooLarge);
    }
    let text = std::str::from_utf8(bytes).map_err(|_| CryptoError::MalformedInput)?;
    if text.chars().count() > maximum_scalars {
        return Err(CryptoError::InputTooLarge);
    }
    Ok(text.to_owned())
}

fn projection_count(value: usize) -> CryptoResult<u16> {
    u16::try_from(value).map_err(|_| CryptoError::InputTooLarge)
}

fn encode_projection(control: &GroupControl, output: &mut Vec<u8>) -> CryptoResult<()> {
    output.push(GROUP_CONTROL_VERSION);
    output.extend_from_slice(&control.event_id);
    output.extend_from_slice(&control.group_id);
    push_u32(output, control.revision);
    match &control.previous_state_hash {
        Some(hash) => {
            output.push(1);
            output.extend_from_slice(hash);
        }
        None => output.push(0),
    }
    output.extend_from_slice(&control.signer_user_id);
    output.extend_from_slice(&control.signer_device_id);
    push_u64(output, control.created_ms);
    output.push(control.body.kind());
    match &control.body {
        ControlBody::Create {
            name,
            description,
            invitation_policy,
            history_policy,
            members,
        } => {
            push_frame(output, name.as_bytes())?;
            push_frame(output, description.as_bytes())?;
            output.push(*invitation_policy);
            output.push(*history_policy);
            push_u16(output, projection_count(members.len())?);
            for member in members {
                output.extend_from_slice(&member.user_id);
                output.push(member.role);
            }
        }
        ControlBody::AddMember { user_ids } => {
            push_u16(output, projection_count(user_ids.len())?);
            for user_id in user_ids {
                output.extend_from_slice(user_id);
            }
        }
        ControlBody::RemoveMember { user_id } => output.extend_from_slice(user_id),
        ControlBody::ChangeRole { user_id, role } => {
            output.extend_from_slice(user_id);
            output.push(*role);
        }
        ControlBody::Rename { name, description } => {
            push_frame(output, name.as_bytes())?;
            push_frame(output, description.as_bytes())?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        enrollment::prepare_device_with_provider,
        pairwise::{OP_OPEN_GROUP_CONTROL, OP_SEAL_GROUP_CONTROL, operation},
        prekey_state::decode_device_state,
        provider::RustCryptoProvider,
        random::FixedRandomProvider,
    };

    const DAY: u32 = 20_302;
    const USER: [u8; 16] = [0x11; 16];
    const DEVICE: [u8; 16] = [0x21; 16];
    const MEMBER: [u8; 16] = [0x31; 16];
    const CREATED_MS: u64 = 1_700_000_000_000;

    fn seeded(seed: u8, length: usize) -> Vec<u8> {
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

    fn device_package(seed: u8) -> Vec<u8> {
        prepare_device_with_provider(
            &RustCryptoProvider::new(FixedRandomProvider::new(seeded(seed, 20_000))),
            &USER,
        )
        .unwrap()
    }

    fn device(seed: u8) -> DeviceState {
        decode_device_state(&RustCryptoProvider::default(), &device_package(seed), DAY).unwrap()
    }

    fn header(output: &mut Vec<u8>, revision: u32, previous: Option<[u8; 32]>, kind: u8) {
        output.push(GROUP_CONTROL_VERSION);
        output.extend_from_slice(&[0x01; 16]);
        output.extend_from_slice(&[0x02; 32]);
        push_u32(output, revision);
        match previous {
            Some(hash) => {
                output.push(1);
                output.extend_from_slice(&hash);
            }
            None => output.push(0),
        }
        output.extend_from_slice(&USER);
        output.extend_from_slice(&DEVICE);
        push_u64(output, CREATED_MS);
        output.push(kind);
    }

    fn create_projection(members: &[([u8; 16], u8)]) -> Vec<u8> {
        let mut output = Vec::new();
        header(&mut output, 1, None, KIND_CREATE);
        push_frame(&mut output, "Team".as_bytes()).unwrap();
        push_frame(&mut output, "Weekly planning".as_bytes()).unwrap();
        output.push(1);
        output.push(0);
        push_u16(&mut output, u16::try_from(members.len()).unwrap());
        for (user_id, role) in members {
            output.extend_from_slice(user_id);
            output.push(*role);
        }
        output
    }

    fn rename_projection(revision: u32, previous: Option<[u8; 32]>, name: &str) -> Vec<u8> {
        let mut output = Vec::new();
        header(&mut output, revision, previous, KIND_RENAME);
        push_frame(&mut output, name.as_bytes()).unwrap();
        push_frame(&mut output, &[]).unwrap();
        output
    }

    fn add_projection(user_ids: &[[u8; 16]]) -> Vec<u8> {
        let mut output = Vec::new();
        header(&mut output, 2, Some([0x03; 32]), KIND_ADD_MEMBER);
        push_u16(&mut output, u16::try_from(user_ids.len()).unwrap());
        for user_id in user_ids {
            output.extend_from_slice(user_id);
        }
        output
    }

    fn golden_rename() -> Vec<u8> {
        let mut expected = vec![0xaa, 0x00, 0x01, 0x01, 0x50];
        expected.extend_from_slice(&[0x01; 16]);
        expected.extend_from_slice(&[0x02, 0x58, 0x20]);
        expected.extend_from_slice(&[0x02; 32]);
        expected.extend_from_slice(&[0x03, 0x02, 0x04, 0x58, 0x20]);
        expected.extend_from_slice(&[0x03; 32]);
        expected.extend_from_slice(&[0x05, 0x50]);
        expected.extend_from_slice(&USER);
        expected.extend_from_slice(&[0x06, 0x50]);
        expected.extend_from_slice(&DEVICE);
        expected.extend_from_slice(&[0x07, 0x1b, 0x00, 0x00, 0x01, 0x8b, 0xcf, 0xe5, 0x68, 0x00]);
        expected.extend_from_slice(&[0x08, 0x05, 0x09, 0xa2, 0x00, 0x64]);
        expected.extend_from_slice(b"Team");
        expected.extend_from_slice(&[0x01, 0x60]);
        expected
    }

    fn sign_raw(device: &DeviceState, message: &[u8]) -> [u8; 64] {
        RustCryptoProvider::default()
            .ed25519_sign(&SecretBytes::new(device.device_signing_secret), message)
            .unwrap()
    }

    #[test]
    fn a_sealed_event_opens_under_the_signing_device_key() {
        let provider = RustCryptoProvider::default();
        let device = device(3);
        let projection = create_projection(&[(USER, ROLE_OWNER), (MEMBER, 2)]);

        let sealed = seal(&provider, &device, &projection).unwrap();
        let opened = open(
            &provider,
            &device.device_signing_public,
            &sealed.canonical,
            &sealed.signature,
        )
        .unwrap();

        assert_eq!(opened.projection, projection);
        assert_eq!(opened.state_hash, sealed.state_hash);
        assert_eq!(
            sealed.state_hash,
            provider
                .sha256(&with_domain(STATE_HASH_DOMAIN, &sealed.canonical).unwrap())
                .unwrap()
        );
    }

    #[test]
    fn one_event_has_one_canonical_encoding_and_one_signature() {
        let provider = RustCryptoProvider::default();
        let device = device(3);
        let projection = rename_projection(2, Some([0x03; 32]), "Team");

        let first = seal(&provider, &device, &projection).unwrap();
        let second = seal(&provider, &device, &projection).unwrap();

        assert_eq!(first.canonical, golden_rename());
        assert_eq!(first.canonical, second.canonical);
        assert_eq!(first.signature, second.signature);
        assert_eq!(first.state_hash, second.state_hash);
    }

    #[test]
    fn a_changed_byte_fails_authentication() {
        let provider = RustCryptoProvider::default();
        let device = device(3);
        let sealed = seal(
            &provider,
            &device,
            &rename_projection(2, Some([0x03; 32]), "Team"),
        )
        .unwrap();
        let mut tampered = sealed.canonical.clone();
        let last = tampered.len() - 2;
        tampered[last] ^= 0x01;

        assert!(matches!(
            open(
                &provider,
                &device.device_signing_public,
                &tampered,
                &sealed.signature,
            ),
            Err(CryptoError::AuthenticationFailed)
        ));
    }

    #[test]
    fn another_device_key_fails_authentication() {
        let provider = RustCryptoProvider::default();
        let signer = device(3);
        let other = device(97);
        assert_ne!(signer.device_signing_public, other.device_signing_public);
        let sealed = seal(
            &provider,
            &signer,
            &rename_projection(2, Some([0x03; 32]), "Team"),
        )
        .unwrap();

        assert!(matches!(
            open(
                &provider,
                &other.device_signing_public,
                &sealed.canonical,
                &sealed.signature,
            ),
            Err(CryptoError::AuthenticationFailed)
        ));
    }

    #[test]
    fn the_signature_is_bound_to_its_domain() {
        let provider = RustCryptoProvider::default();
        let device = device(3);
        let canonical = golden_rename();
        let bare = sign_raw(&device, &canonical);
        let wrong_domain = sign_raw(
            &device,
            &with_domain(STATE_HASH_DOMAIN, &canonical).unwrap(),
        );

        for signature in [bare, wrong_domain] {
            assert!(matches!(
                open(
                    &provider,
                    &device.device_signing_public,
                    &canonical,
                    &signature,
                ),
                Err(CryptoError::AuthenticationFailed)
            ));
        }
    }

    #[test]
    fn a_signed_but_non_canonical_event_is_refused() {
        let provider = RustCryptoProvider::default();
        let device = device(3);
        let canonical = golden_rename();
        let position = canonical
            .windows(2)
            .position(|pair| pair == [0x03, 0x02])
            .unwrap();
        let mut padded = canonical[..=position].to_vec();
        padded.extend_from_slice(&[0x18, 0x02]);
        padded.extend_from_slice(&canonical[position + 2..]);
        let signature = sign_raw(&device, &with_domain(SIGNATURE_DOMAIN, &padded).unwrap());

        assert!(matches!(
            open(
                &provider,
                &device.device_signing_public,
                &padded,
                &signature,
            ),
            Err(CryptoError::MalformedInput)
        ));
    }

    #[test]
    fn structural_rules_are_enforced_before_signing() {
        let provider = RustCryptoProvider::default();
        let device = device(3);
        let mut create_at_two = create_projection(&[(USER, ROLE_OWNER)]);
        create_at_two[1 + 16 + 32..1 + 16 + 32 + 4].copy_from_slice(&2_u32.to_be_bytes());
        let cases: Vec<(Vec<u8>, CryptoError)> = vec![
            (create_at_two, CryptoError::MalformedInput),
            (
                rename_projection(1, None, "Team"),
                CryptoError::MalformedInput,
            ),
            (
                rename_projection(2, None, "Team"),
                CryptoError::MalformedInput,
            ),
            (
                rename_projection(2, Some([0x03; 32]), ""),
                CryptoError::MalformedInput,
            ),
            (
                rename_projection(2, Some([0x03; 32]), &"x".repeat(101)),
                CryptoError::InputTooLarge,
            ),
            (
                create_projection(&[(MEMBER, 2), (USER, ROLE_OWNER)]),
                CryptoError::MalformedInput,
            ),
            (
                create_projection(&[(USER, ROLE_OWNER), (MEMBER, ROLE_OWNER)]),
                CryptoError::MalformedInput,
            ),
            (
                create_projection(&[(USER, 1), (MEMBER, 2)]),
                CryptoError::MalformedInput,
            ),
            (
                create_projection(&[(USER, ROLE_OWNER), (MEMBER, 3)]),
                CryptoError::MalformedInput,
            ),
            (add_projection(&[]), CryptoError::MalformedInput),
            (
                add_projection(&[[0x41; 16], [0x40; 16]]),
                CryptoError::MalformedInput,
            ),
        ];
        for (projection, expected) in cases {
            assert_eq!(
                seal(&provider, &device, &projection).err(),
                Some(expected),
                "{projection:02x?}"
            );
        }

        let mut unknown_kind = Vec::new();
        header(&mut unknown_kind, 2, Some([0x03; 32]), 6);
        assert_eq!(
            seal(&provider, &device, &unknown_kind).err(),
            Some(CryptoError::UnsupportedOperation)
        );
        let mut trailing = rename_projection(2, Some([0x03; 32]), "Team");
        trailing.push(0);
        assert_eq!(
            seal(&provider, &device, &trailing).err(),
            Some(CryptoError::MalformedInput)
        );
    }

    #[test]
    fn a_device_signs_only_for_its_own_account() {
        let provider = RustCryptoProvider::default();
        let device = device(3);
        let mut projection = rename_projection(2, Some([0x03; 32]), "Team");
        let signer = 1 + 16 + 32 + 4 + 1 + 32;
        projection[signer..signer + 16].copy_from_slice(&MEMBER);

        assert_eq!(
            seal(&provider, &device, &projection).err(),
            Some(CryptoError::InvalidArgument)
        );
    }

    #[test]
    fn seal_and_open_frame_through_the_pairwise_multiplexer() {
        let package = device_package(3);
        let device = decode_device_state(&RustCryptoProvider::default(), &package, DAY).unwrap();
        let projection = create_projection(&[(USER, ROLE_OWNER), (MEMBER, 2)]);

        let mut seal_request = b"CPPWR001".to_vec();
        push_frame(&mut seal_request, &package).unwrap();
        push_u32(&mut seal_request, DAY);
        push_frame(&mut seal_request, &projection).unwrap();
        let sealed = operation(OP_SEAL_GROUP_CONTROL, &seal_request).unwrap();
        let mut reader = Reader::new(&sealed);
        assert_eq!(reader.take(8).unwrap(), b"CPPWO001");
        assert_eq!(u32::from(reader.u8().unwrap()), OP_SEAL_GROUP_CONTROL);
        assert_eq!(reader.u8().unwrap(), 0);
        let canonical = reader.framed().unwrap().to_vec();
        let signature: [u8; 64] = reader.array().unwrap();
        let state_hash: [u8; 32] = reader.array().unwrap();
        assert!(reader.is_finished());

        let mut open_request = b"CPPWR001".to_vec();
        open_request.extend_from_slice(&device.device_signing_public);
        push_frame(&mut open_request, &canonical).unwrap();
        open_request.extend_from_slice(&signature);
        let opened = operation(OP_OPEN_GROUP_CONTROL, &open_request).unwrap();
        let mut reader = Reader::new(&opened);
        assert_eq!(reader.take(8).unwrap(), b"CPPWO001");
        assert_eq!(u32::from(reader.u8().unwrap()), OP_OPEN_GROUP_CONTROL);
        assert_eq!(reader.u8().unwrap(), 0);
        assert_eq!(reader.framed().unwrap(), projection.as_slice());
        assert_eq!(reader.array::<32>().unwrap(), state_hash);
        assert!(reader.is_finished());
    }
}
