//! Version-1 signed control events for voice rooms.
//!
//! A voice room is client state exactly as a group is (`backend/CLIENT_CONTRACT.md`
//! §N, server ADR-0021): the server holds no room, no roster and no name, so every
//! change to a room is an event that one member's device signs and every other
//! member checks (`docs/voice-signalling-v1.md`, Part 1). This module owns that
//! event's deterministic-CBOR encoding, its Ed25519 signature under the device
//! signing key, and the hash that chains one accepted event to the next. It is the
//! group's construction under the room's own two domains, so that an event of one
//! kind can never verify as the other. Dart supplies and receives a bounded
//! projection frame; it never constructs or parses the CBOR and never holds the key.

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

pub(crate) const ROOM_CONTROL_VERSION: u8 = 1;
pub(crate) const MAX_ROOM_CONTROL_BYTES: usize = 16_384;
pub(crate) const ROOM_STATE_HASH_BYTES: usize = 32;

const SIGNATURE_DOMAIN: &[u8] = b"chat:v1:room-control";
const STATE_HASH_DOMAIN: &[u8] = b"chat:v1:room-control-state";

const KIND_CREATE: u8 = 1;
const KIND_ADD_MEMBERS: u8 = 2;
const KIND_REMOVE_MEMBER: u8 = 3;
const KIND_RENAME: u8 = 4;
// Kind 5 is reserved, so that a later role operation cannot reuse a value, and it
// is refused like any kind this version does not define.

const MIN_CREATE_MEMBERS: usize = 2;
const MAX_MEMBERS: usize = 50;
const MAX_NAME_BYTES: usize = 400;
const MAX_NAME_SCALARS: usize = 100;
const MAX_CREATED_MS: u64 = 8_640_000_000_000_000;

#[derive(Clone, Debug, Eq, PartialEq)]
struct RoomControl {
    event_id: [u8; 16],
    room_id: [u8; 32],
    revision: u32,
    previous_state_hash: Option<[u8; ROOM_STATE_HASH_BYTES]>,
    signer_user_id: [u8; 16],
    signer_device_id: [u8; 16],
    created_ms: u64,
    body: ControlBody,
}

/// A room has no roles, no policies and no description, so every body names
/// accounts, a name, or both.
#[derive(Clone, Debug, Eq, PartialEq)]
enum ControlBody {
    Create {
        name: String,
        members: Vec<[u8; 16]>,
    },
    AddMembers {
        user_ids: Vec<[u8; 16]>,
    },
    RemoveMember {
        user_id: [u8; 16],
    },
    Rename {
        name: String,
    },
}

impl ControlBody {
    const fn kind(&self) -> u8 {
        match self {
            Self::Create { .. } => KIND_CREATE,
            Self::AddMembers { .. } => KIND_ADD_MEMBERS,
            Self::RemoveMember { .. } => KIND_REMOVE_MEMBER,
            Self::Rename { .. } => KIND_RENAME,
        }
    }
}

/// A locally originated event, ready to be carried to every member.
pub(crate) struct SealedRoomControl {
    pub(crate) canonical: Vec<u8>,
    pub(crate) signature: [u8; ED25519_SIGNATURE_BYTES],
    pub(crate) state_hash: [u8; ROOM_STATE_HASH_BYTES],
}

/// A received event whose signature verified and whose encoding is canonical.
pub(crate) struct OpenedRoomControl {
    pub(crate) projection: Vec<u8>,
    pub(crate) state_hash: [u8; ROOM_STATE_HASH_BYTES],
}

/// Encodes a projected event, signs it with this device's signing key, and
/// returns the hash the next event in the room must name as its predecessor.
///
/// The signer named inside the event must be the account this device state
/// belongs to. The device identifier cannot be checked here, because the native
/// device state does not carry it; the caller that knows it names it, and every
/// recipient checks it against the authenticated device list.
pub(crate) fn seal<P: CryptoProvider>(
    provider: &P,
    device: &DeviceState,
    projection: &[u8],
) -> CryptoResult<SealedRoomControl> {
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
    Ok(SealedRoomControl {
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
) -> CryptoResult<OpenedRoomControl> {
    if canonical.is_empty() {
        return Err(CryptoError::MalformedInput);
    }
    if canonical.len() > MAX_ROOM_CONTROL_BYTES {
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
    Ok(OpenedRoomControl {
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

/// The hash an event commits the room to.
///
/// Every event but the first names its predecessor's hash inside its signed
/// bytes, so this is a hash chain over the accepted transcript: two devices
/// holding the same hash at the same revision hold the same history.
fn state_hash<P: CryptoProvider>(
    provider: &P,
    canonical: &[u8],
) -> CryptoResult<[u8; ROOM_STATE_HASH_BYTES]> {
    provider.sha256(&with_domain(STATE_HASH_DOMAIN, canonical)?)
}

fn validate(control: &RoomControl) -> CryptoResult<()> {
    let first = control.revision == 1;
    if control.revision == 0
        || first != matches!(control.body, ControlBody::Create { .. })
        || first != control.previous_state_hash.is_none()
        || control.created_ms > MAX_CREATED_MS
        || control.event_id == [0; 16]
        || control.room_id == [0; 32]
        || control.signer_user_id == [0; 16]
        || control.signer_device_id == [0; 16]
    {
        return Err(CryptoError::MalformedInput);
    }
    match &control.body {
        ControlBody::Create { name, members } => {
            validate_name(name)?;
            if members.len() > MAX_MEMBERS {
                return Err(CryptoError::InputTooLarge);
            }
            // The creator is one of the members it names, and a room starts
            // with somebody to talk to.
            if members.len() < MIN_CREATE_MEMBERS
                || !ascending(members)
                || !members.contains(&control.signer_user_id)
            {
                return Err(CryptoError::MalformedInput);
            }
        }
        ControlBody::AddMembers { user_ids } => {
            // Whoever signs an add is already an active member, so at most one
            // fewer than the ceiling can join at once.
            if user_ids.len() >= MAX_MEMBERS {
                return Err(CryptoError::InputTooLarge);
            }
            if user_ids.is_empty() || !ascending(user_ids) {
                return Err(CryptoError::MalformedInput);
            }
        }
        ControlBody::RemoveMember { user_id } => {
            if *user_id == [0; 16] {
                return Err(CryptoError::MalformedInput);
            }
        }
        ControlBody::Rename { name } => validate_name(name)?,
    }
    Ok(())
}

/// Strictly ascending account ids, none of them zero: one order, one encoding.
fn ascending(user_ids: &[[u8; 16]]) -> bool {
    user_ids.iter().all(|user_id| *user_id != [0; 16])
        && user_ids.windows(2).all(|pair| pair[0] < pair[1])
}

fn validate_name(name: &str) -> CryptoResult<()> {
    if name.len() > MAX_NAME_BYTES || name.chars().count() > MAX_NAME_SCALARS {
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

fn encode_control(control: &RoomControl) -> CryptoResult<Vec<u8>> {
    let mut output = Vec::new();
    output
        .try_reserve_exact(256)
        .map_err(|_| CryptoError::ResourceExhausted)?;
    let mut encoder = Encoder::new(&mut output);
    written(encoder.map(10))?;
    encode_key(&mut encoder, 0)?;
    written(encoder.u8(ROOM_CONTROL_VERSION))?;
    encode_key(&mut encoder, 1)?;
    written(encoder.bytes(&control.event_id))?;
    encode_key(&mut encoder, 2)?;
    written(encoder.bytes(&control.room_id))?;
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
        ControlBody::Create { name, members } => {
            written(encoder.map(2))?;
            encode_key(&mut encoder, 0)?;
            written(encoder.str(name))?;
            encode_key(&mut encoder, 1)?;
            written(encoder.array(length(members.len())?))?;
            for user_id in members {
                written(encoder.bytes(user_id))?;
            }
        }
        ControlBody::AddMembers { user_ids } => {
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
        ControlBody::Rename { name } => {
            written(encoder.map(1))?;
            encode_key(&mut encoder, 0)?;
            written(encoder.str(name))?;
        }
    }
    if output.len() > MAX_ROOM_CONTROL_BYTES {
        return Err(CryptoError::InputTooLarge);
    }
    Ok(output)
}

fn decode_control(input: &[u8]) -> CryptoResult<RoomControl> {
    let mut decoder = Decoder::new(input);
    read_exact_map(&mut decoder, 10)?;
    read_key(&mut decoder, 0)?;
    if read_uint(&mut decoder)? != u64::from(ROOM_CONTROL_VERSION) {
        return Err(CryptoError::UnsupportedVersion);
    }
    read_key(&mut decoder, 1)?;
    let event_id = read_exact_bytes(&mut decoder)?;
    read_key(&mut decoder, 2)?;
    let room_id = read_exact_bytes(&mut decoder)?;
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
    let control = RoomControl {
        event_id,
        room_id,
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

fn decode_user_ids(decoder: &mut Decoder<'_>, maximum: usize) -> CryptoResult<Vec<[u8; 16]>> {
    let count = read_array_len(decoder)?;
    if count > maximum {
        return Err(CryptoError::InputTooLarge);
    }
    let mut user_ids = Vec::new();
    user_ids
        .try_reserve_exact(count)
        .map_err(|_| CryptoError::ResourceExhausted)?;
    for _ in 0..count {
        user_ids.push(read_exact_bytes(decoder)?);
    }
    Ok(user_ids)
}

fn decode_body(kind: u8, decoder: &mut Decoder<'_>) -> CryptoResult<ControlBody> {
    match kind {
        KIND_CREATE => {
            read_exact_map(decoder, 2)?;
            read_key(decoder, 0)?;
            let name = read_text(decoder, MAX_NAME_BYTES, MAX_NAME_SCALARS, true)?;
            read_key(decoder, 1)?;
            Ok(ControlBody::Create {
                name,
                members: decode_user_ids(decoder, MAX_MEMBERS)?,
            })
        }
        KIND_ADD_MEMBERS => {
            read_exact_map(decoder, 1)?;
            read_key(decoder, 0)?;
            Ok(ControlBody::AddMembers {
                user_ids: decode_user_ids(decoder, MAX_MEMBERS - 1)?,
            })
        }
        KIND_REMOVE_MEMBER => {
            read_exact_map(decoder, 1)?;
            read_key(decoder, 0)?;
            Ok(ControlBody::RemoveMember {
                user_id: read_exact_bytes(decoder)?,
            })
        }
        KIND_RENAME => {
            read_exact_map(decoder, 1)?;
            read_key(decoder, 0)?;
            Ok(ControlBody::Rename {
                name: read_text(decoder, MAX_NAME_BYTES, MAX_NAME_SCALARS, true)?,
            })
        }
        _ => Err(CryptoError::UnsupportedOperation),
    }
}

fn small(value: u64) -> CryptoResult<u8> {
    u8::try_from(value).map_err(|_| CryptoError::MalformedInput)
}

fn projection_user_ids(reader: &mut Reader<'_>, maximum: usize) -> CryptoResult<Vec<[u8; 16]>> {
    let count = usize::from(reader.u16()?);
    if count > maximum {
        return Err(CryptoError::InputTooLarge);
    }
    let mut user_ids = Vec::new();
    user_ids
        .try_reserve_exact(count)
        .map_err(|_| CryptoError::ResourceExhausted)?;
    for _ in 0..count {
        user_ids.push(reader.array()?);
    }
    Ok(user_ids)
}

fn decode_projection(input: &[u8]) -> CryptoResult<RoomControl> {
    let mut reader = Reader::new(input);
    if reader.u8()? != ROOM_CONTROL_VERSION {
        return Err(CryptoError::UnsupportedVersion);
    }
    let event_id = reader.array()?;
    let room_id = reader.array()?;
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
        KIND_CREATE => ControlBody::Create {
            name: projection_text(&mut reader)?,
            members: projection_user_ids(&mut reader, MAX_MEMBERS)?,
        },
        KIND_ADD_MEMBERS => ControlBody::AddMembers {
            user_ids: projection_user_ids(&mut reader, MAX_MEMBERS - 1)?,
        },
        KIND_REMOVE_MEMBER => ControlBody::RemoveMember {
            user_id: reader.array()?,
        },
        KIND_RENAME => ControlBody::Rename {
            name: projection_text(&mut reader)?,
        },
        _ => return Err(CryptoError::UnsupportedOperation),
    };
    if !reader.is_finished() {
        return Err(CryptoError::MalformedInput);
    }
    let control = RoomControl {
        event_id,
        room_id,
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

fn projection_text(reader: &mut Reader<'_>) -> CryptoResult<String> {
    let bytes = reader.framed()?;
    if bytes.len() > MAX_NAME_BYTES {
        return Err(CryptoError::InputTooLarge);
    }
    let text = std::str::from_utf8(bytes).map_err(|_| CryptoError::MalformedInput)?;
    if text.chars().count() > MAX_NAME_SCALARS {
        return Err(CryptoError::InputTooLarge);
    }
    Ok(text.to_owned())
}

fn projection_count(value: usize) -> CryptoResult<u16> {
    u16::try_from(value).map_err(|_| CryptoError::InputTooLarge)
}

fn push_user_ids(output: &mut Vec<u8>, user_ids: &[[u8; 16]]) -> CryptoResult<()> {
    push_u16(output, projection_count(user_ids.len())?);
    for user_id in user_ids {
        output.extend_from_slice(user_id);
    }
    Ok(())
}

fn encode_projection(control: &RoomControl, output: &mut Vec<u8>) -> CryptoResult<()> {
    output.push(ROOM_CONTROL_VERSION);
    output.extend_from_slice(&control.event_id);
    output.extend_from_slice(&control.room_id);
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
        ControlBody::Create { name, members } => {
            push_frame(output, name.as_bytes())?;
            push_user_ids(output, members)?;
        }
        ControlBody::AddMembers { user_ids } => push_user_ids(output, user_ids)?,
        ControlBody::RemoveMember { user_id } => output.extend_from_slice(user_id),
        ControlBody::Rename { name } => push_frame(output, name.as_bytes())?,
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        enrollment::prepare_device_with_provider,
        group_control,
        pairwise::{OP_OPEN_ROOM_CONTROL, OP_SEAL_ROOM_CONTROL, operation},
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
        output.push(ROOM_CONTROL_VERSION);
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

    fn with_user_ids(output: &mut Vec<u8>, user_ids: &[[u8; 16]]) {
        push_u16(output, u16::try_from(user_ids.len()).unwrap());
        for user_id in user_ids {
            output.extend_from_slice(user_id);
        }
    }

    fn create_projection(members: &[[u8; 16]]) -> Vec<u8> {
        let mut output = Vec::new();
        header(&mut output, 1, None, KIND_CREATE);
        push_frame(&mut output, "Standup".as_bytes()).unwrap();
        with_user_ids(&mut output, members);
        output
    }

    fn rename_projection(revision: u32, previous: Option<[u8; 32]>, name: &str) -> Vec<u8> {
        let mut output = Vec::new();
        header(&mut output, revision, previous, KIND_RENAME);
        push_frame(&mut output, name.as_bytes()).unwrap();
        output
    }

    fn add_projection(user_ids: &[[u8; 16]]) -> Vec<u8> {
        let mut output = Vec::new();
        header(&mut output, 2, Some([0x03; 32]), KIND_ADD_MEMBERS);
        with_user_ids(&mut output, user_ids);
        output
    }

    fn remove_projection(user_id: [u8; 16]) -> Vec<u8> {
        let mut output = Vec::new();
        header(&mut output, 2, Some([0x03; 32]), KIND_REMOVE_MEMBER);
        output.extend_from_slice(&user_id);
        output
    }

    fn numbered(count: usize) -> Vec<[u8; 16]> {
        (1..=count)
            .map(|index| {
                let mut user_id = [0x40; 16];
                user_id[15] = u8::try_from(index).unwrap();
                user_id
            })
            .collect()
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
        expected.extend_from_slice(&[0x08, 0x04, 0x09, 0xa1, 0x00, 0x64]);
        expected.extend_from_slice(b"Room");
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
        let projection = create_projection(&[USER, MEMBER]);

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
    fn every_operation_round_trips_through_its_projection() {
        let provider = RustCryptoProvider::default();
        let device = device(3);
        for projection in [
            create_projection(&[USER, MEMBER]),
            add_projection(&[[0x41; 16], [0x42; 16]]),
            remove_projection(MEMBER),
            remove_projection(USER),
            rename_projection(7, Some([0x03; 32]), "Weekly room"),
        ] {
            let sealed = seal(&provider, &device, &projection).unwrap();
            let opened = open(
                &provider,
                &device.device_signing_public,
                &sealed.canonical,
                &sealed.signature,
            )
            .unwrap();
            assert_eq!(opened.projection, projection);
        }
    }

    #[test]
    fn one_event_has_one_canonical_encoding_and_one_signature() {
        let provider = RustCryptoProvider::default();
        let device = device(3);
        let projection = rename_projection(2, Some([0x03; 32]), "Room");

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
            &rename_projection(2, Some([0x03; 32]), "Room"),
        )
        .unwrap();
        let mut tampered = sealed.canonical.clone();
        let last = tampered.len() - 2;
        tampered[last] ^= 0x01;
        let mut forged = sealed.signature;
        forged[0] ^= 0x01;

        assert!(matches!(
            open(
                &provider,
                &device.device_signing_public,
                &tampered,
                &sealed.signature,
            ),
            Err(CryptoError::AuthenticationFailed)
        ));
        assert!(matches!(
            open(
                &provider,
                &device.device_signing_public,
                &sealed.canonical,
                &forged,
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
            &rename_projection(2, Some([0x03; 32]), "Room"),
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
        let group_domain = sign_raw(
            &device,
            &with_domain(b"chat:v1:group-control", &canonical).unwrap(),
        );

        for signature in [bare, wrong_domain, group_domain] {
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
    fn a_room_event_never_opens_as_a_group_event() {
        let provider = RustCryptoProvider::default();
        let device = device(3);
        let sealed = seal(
            &provider,
            &device,
            &rename_projection(2, Some([0x03; 32]), "Room"),
        )
        .unwrap();

        assert!(matches!(
            group_control::open(
                &provider,
                &device.device_signing_public,
                &sealed.canonical,
                &sealed.signature,
            ),
            Err(CryptoError::AuthenticationFailed)
        ));
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
        let mut create_at_two = create_projection(&[USER, MEMBER]);
        create_at_two[1 + 16 + 32..1 + 16 + 32 + 4].copy_from_slice(&2_u32.to_be_bytes());
        let mut many = numbered(51);
        many[0] = USER;
        many.sort_unstable();
        let cases: Vec<(Vec<u8>, CryptoError)> = vec![
            (create_at_two, CryptoError::MalformedInput),
            (
                rename_projection(1, None, "Room"),
                CryptoError::MalformedInput,
            ),
            (
                rename_projection(2, None, "Room"),
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
            // A room of one, a creator the event does not name, an order
            // that is not ascending and a repeated member.
            (create_projection(&[USER]), CryptoError::MalformedInput),
            (
                create_projection(&[MEMBER, [0x32; 16]]),
                CryptoError::MalformedInput,
            ),
            (
                create_projection(&[MEMBER, USER]),
                CryptoError::MalformedInput,
            ),
            (
                create_projection(&[USER, USER]),
                CryptoError::MalformedInput,
            ),
            (
                create_projection(&[[0; 16], USER]),
                CryptoError::MalformedInput,
            ),
            (create_projection(&many), CryptoError::InputTooLarge),
            (add_projection(&[]), CryptoError::MalformedInput),
            (
                add_projection(&[[0x41; 16], [0x40; 16]]),
                CryptoError::MalformedInput,
            ),
            (add_projection(&numbered(50)), CryptoError::InputTooLarge),
            (remove_projection([0; 16]), CryptoError::MalformedInput),
        ];
        let mut largest = numbered(50);
        largest[0] = USER;
        largest.sort_unstable();
        assert!(seal(&provider, &device, &create_projection(&largest)).is_ok());
        for (projection, expected) in cases {
            assert_eq!(
                seal(&provider, &device, &projection).err(),
                Some(expected),
                "{projection:02x?}"
            );
        }

        // 5 is reserved for a later role operation, and 6 is unknown.
        for kind in [5, 6] {
            let mut unknown = Vec::new();
            header(&mut unknown, 2, Some([0x03; 32]), kind);
            assert_eq!(
                seal(&provider, &device, &unknown).err(),
                Some(CryptoError::UnsupportedOperation)
            );
        }
        let mut trailing = rename_projection(2, Some([0x03; 32]), "Room");
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
        let mut projection = rename_projection(2, Some([0x03; 32]), "Room");
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
        let projection = create_projection(&[USER, MEMBER]);

        let mut seal_request = b"CPPWR001".to_vec();
        push_frame(&mut seal_request, &package).unwrap();
        push_u32(&mut seal_request, DAY);
        push_frame(&mut seal_request, &projection).unwrap();
        let sealed = operation(OP_SEAL_ROOM_CONTROL, &seal_request).unwrap();
        let mut reader = Reader::new(&sealed);
        assert_eq!(reader.take(8).unwrap(), b"CPPWO001");
        assert_eq!(u32::from(reader.u8().unwrap()), OP_SEAL_ROOM_CONTROL);
        assert_eq!(reader.u8().unwrap(), 0);
        let canonical = reader.framed().unwrap().to_vec();
        let signature: [u8; 64] = reader.array().unwrap();
        let state_hash: [u8; 32] = reader.array().unwrap();
        assert!(reader.is_finished());

        let mut open_request = b"CPPWR001".to_vec();
        open_request.extend_from_slice(&device.device_signing_public);
        push_frame(&mut open_request, &canonical).unwrap();
        open_request.extend_from_slice(&signature);
        let opened = operation(OP_OPEN_ROOM_CONTROL, &open_request).unwrap();
        let mut reader = Reader::new(&opened);
        assert_eq!(reader.take(8).unwrap(), b"CPPWO001");
        assert_eq!(u32::from(reader.u8().unwrap()), OP_OPEN_ROOM_CONTROL);
        assert_eq!(reader.u8().unwrap(), 0);
        assert_eq!(reader.framed().unwrap(), projection.as_slice());
        assert_eq!(reader.array::<32>().unwrap(), state_hash);
        assert!(reader.is_finished());

        let mut forged_request = open_request.clone();
        let last = forged_request.len() - 1;
        forged_request[last] ^= 0x01;
        assert_eq!(
            operation(OP_OPEN_ROOM_CONTROL, &forged_request).err(),
            Some(CryptoError::AuthenticationFailed)
        );
    }
}
