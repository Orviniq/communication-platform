//! Version-1 deterministic-CBOR application events and conversation identifiers.
//!
//! This module is the single wire-format owner. Dart supplies and receives a
//! bounded, versioned projection frame; it never constructs or parses CBOR.

use minicbor::{decode::Decoder, encode::Encoder};

use crate::{
    bounds::{MAX_CBOR_BYTES, MAX_CBOR_ITEMS},
    enrollment,
    error::{CryptoError, CryptoResult},
    protocol::{Reader, push_frame, push_u16, push_u32, push_u64, reserve},
    provider::{CryptoProvider, RustCryptoProvider},
};

pub const APPLICATION_MAX_IO_BYTES: usize = 262_144;
pub const APPLICATION_VERSION: u8 = 1;

const ENCODE_REQUEST_MAGIC: &[u8; 8] = b"CPAEV001";
const ENCODE_RESPONSE_MAGIC: &[u8; 8] = b"CPAOE001";
const DECODE_RESPONSE_MAGIC: &[u8; 8] = b"CPAOD001";
const RANDOM_RESPONSE_MAGIC: &[u8; 8] = b"CPAOG001";
const CONVERSATION_RESPONSE_MAGIC: &[u8; 8] = b"CPAOC001";
const DEVICE_CONTROL_MAGIC: &[u8; 8] = b"CPDCV001";
const DEVICE_CONTROL_ENCODE_RESPONSE_MAGIC: &[u8; 8] = b"CPDCO001";
const DEVICE_CONTROL_DECODE_RESPONSE_MAGIC: &[u8; 8] = b"CPDOD001";
const LABEL_SEAL_REQUEST_MAGIC: &[u8; 8] = b"CPLSE001";
const LABEL_SEAL_RESPONSE_MAGIC: &[u8; 8] = b"CPLSO001";
const LABEL_OPEN_REQUEST_MAGIC: &[u8; 8] = b"CPLOE001";
const LABEL_OPEN_RESPONSE_MAGIC: &[u8; 8] = b"CPLOO001";

const DM_CONVERSATION_DOMAIN: &[u8] = b"chat:v1:dm-conversation";
const SAVED_CONVERSATION_DOMAIN: &[u8] = b"chat:v1:saved-conversation";

const KIND_MESSAGE_CREATE: u16 = 1;
const KIND_MESSAGE_EDIT: u16 = 2;
const KIND_MESSAGE_DELETE: u16 = 3;
const KIND_REACTION_SET: u16 = 4;
const KIND_PIN_SET: u16 = 5;
const KIND_RECEIPT_DELIVERED: u16 = 6;
const KIND_RECEIPT_READ: u16 = 7;
const KIND_TYPING_SET: u16 = 8;

const MAX_REFERENCES: usize = 64;
const MAX_TEXT_BYTES: usize = 65_536;
const MAX_TEXT_SCALARS: usize = 16_384;
const MAX_QUOTE_BYTES: usize = 2_048;
const MAX_QUOTE_SCALARS: usize = 512;
const MAX_EMOJI_BYTES: usize = 64;
const MAX_APPLICATION_CBOR_DEPTH: usize = 16;
const MAX_APPLICATION_MAP_ENTRIES: usize = 64;
const MAX_DEVICE_GOSSIP_HEADS: usize = 32;
const MAX_HISTORY_BATCH_EVENTS: usize = 32;
const MAX_HISTORY_BATCH_BYTES: usize = 240 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
struct ApplicationEvent {
    version: u8,
    event_id: [u8; 16],
    conversation_id: [u8; 32],
    kind: u16,
    sender_user_id: [u8; 16],
    sender_device_id: [u8; 16],
    sender_counter: u64,
    created_ms: u64,
    references: Vec<[u8; 16]>,
    body: EventBody,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum EventBody {
    MessageCreate {
        message_id: [u8; 16],
        content_type: u8,
        text: String,
        reply_to: Option<[u8; 16]>,
        quote_fallback: Option<String>,
        attachments: Vec<AttachmentDescriptor>,
    },
    MessageEdit {
        target: [u8; 16],
        revision: u32,
        replacement: String,
    },
    MessageDelete {
        target: [u8; 16],
    },
    ReactionSet {
        target: [u8; 16],
        emoji: Option<String>,
    },
    PinSet {
        target: [u8; 16],
        pinned: bool,
    },
    Receipt {
        message_ids: Vec<[u8; 16]>,
    },
    TypingSet {
        is_typing: bool,
        expires_ms: u64,
    },
    Unsupported,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct AttachmentDescriptor {
    capability_id: String,
    key: [u8; 32],
    header: [u8; 66],
    stream_header: [u8; 24],
    encrypted_size: u64,
    bucket_size: u64,
    plaintext_size: u64,
    display_name: String,
    mime_type: String,
    media_kind: u8,
    width: u32,
    height: u32,
    caption: Option<String>,
    thumbnail: Option<Vec<u8>>,
}

pub fn operation(operation: u32, input: &[u8]) -> CryptoResult<Vec<u8>> {
    if input.len() > APPLICATION_MAX_IO_BYTES {
        return Err(CryptoError::InputTooLarge);
    }
    match operation {
        1 => encode_operation(input),
        2 => decode_operation(input),
        3 => random_event_id(input),
        4 => derive_dm_conversation_id(input),
        5 => derive_saved_conversation_id(input),
        6 => encode_device_control(input),
        7 => decode_device_control(input),
        8 => seal_device_label(input),
        9 => open_device_label(input),
        _ => Err(CryptoError::UnsupportedOperation),
    }
}

fn encode_device_control(input: &[u8]) -> CryptoResult<Vec<u8>> {
    validate_device_control(input)?;
    let mut output = Vec::with_capacity(DEVICE_CONTROL_ENCODE_RESPONSE_MAGIC.len() + input.len());
    output.extend_from_slice(DEVICE_CONTROL_ENCODE_RESPONSE_MAGIC);
    output.extend_from_slice(input);
    Ok(output)
}

fn decode_device_control(input: &[u8]) -> CryptoResult<Vec<u8>> {
    validate_device_control(input)?;
    let mut output = Vec::with_capacity(DEVICE_CONTROL_DECODE_RESPONSE_MAGIC.len() + input.len());
    output.extend_from_slice(DEVICE_CONTROL_DECODE_RESPONSE_MAGIC);
    output.extend_from_slice(input);
    Ok(output)
}

fn validate_device_control(input: &[u8]) -> CryptoResult<()> {
    let mut reader = Reader::new(input);
    reader.expect(DEVICE_CONTROL_MAGIC)?;
    if reader.u8()? != 1 {
        return Err(CryptoError::UnsupportedVersion);
    }
    let kind = reader.u8()?;
    let _event_id: [u8; 16] = reader.array()?;
    let _sender_user_id: [u8; 16] = reader.array()?;
    let _sender_device_id: [u8; 16] = reader.array()?;
    let target_device_id: [u8; 16] = reader.array()?;
    let transfer_id: [u8; 16] = reader.array()?;
    match kind {
        1 => {
            if target_device_id != [0; 16] || transfer_id != [0; 16] {
                return Err(CryptoError::MalformedInput);
            }
            let count = usize::from(reader.u8()?);
            if count == 0 || count > MAX_DEVICE_GOSSIP_HEADS {
                return Err(CryptoError::InputTooLarge);
            }
            let mut users = Vec::with_capacity(count);
            for _ in 0..count {
                let user: [u8; 16] = reader.array()?;
                let _sequence = reader.u64()?;
                let _hash: [u8; 32] = reader.array()?;
                users.push(user);
            }
            if has_duplicates(&users) {
                return Err(CryptoError::MalformedInput);
            }
        }
        2 | 4 => {
            if target_device_id == [0; 16] || transfer_id == [0; 16] {
                return Err(CryptoError::MalformedInput);
            }
            let _resume_or_confirmed_batch = reader.u32()?;
        }
        3 => {
            if target_device_id == [0; 16] || transfer_id == [0; 16] {
                return Err(CryptoError::MalformedInput);
            }
            let _batch_index = reader.u32()?;
            let _final_batch = reader.boolean()?;
            if reader.u8()? > 1 {
                return Err(CryptoError::MalformedInput);
            }
            let count = usize::from(reader.u16()?);
            if count == 0 || count > MAX_HISTORY_BATCH_EVENTS {
                return Err(CryptoError::InputTooLarge);
            }
            let mut total = 0_usize;
            for _ in 0..count {
                let bytes = reader.framed()?;
                total = total
                    .checked_add(bytes.len())
                    .ok_or(CryptoError::InputTooLarge)?;
                if total > MAX_HISTORY_BATCH_BYTES {
                    return Err(CryptoError::InputTooLarge);
                }
                let (event, unsupported_version) = decode_event(bytes)?;
                let event = event.ok_or(CryptoError::UnsupportedVersion)?;
                if unsupported_version.is_some()
                    || matches!(
                        &event.body,
                        EventBody::Unsupported | EventBody::TypingSet { .. }
                    )
                    || encode_event(&event)? != bytes
                {
                    return Err(CryptoError::MalformedInput);
                }
            }
        }
        5 => {
            if target_device_id == [0; 16] || transfer_id == [0; 16] || reader.u8()? > 2 {
                return Err(CryptoError::MalformedInput);
            }
        }
        _ => return Err(CryptoError::UnsupportedOperation),
    }
    if !reader.is_finished() {
        return Err(CryptoError::MalformedInput);
    }
    Ok(())
}

fn seal_device_label(input: &[u8]) -> CryptoResult<Vec<u8>> {
    let mut reader = Reader::new(input);
    reader.expect(LABEL_SEAL_REQUEST_MAGIC)?;
    let identity = reader.framed()?;
    let user_id = reader.take(16)?;
    let device_id = reader.take(16)?;
    let label = reader.framed()?;
    if !reader.is_finished() {
        return Err(CryptoError::MalformedInput);
    }
    let blob = enrollment::seal_device_label(identity, user_id, device_id, label)?;
    let mut output = Vec::with_capacity(LABEL_SEAL_RESPONSE_MAGIC.len() + blob.len());
    output.extend_from_slice(LABEL_SEAL_RESPONSE_MAGIC);
    output.extend_from_slice(&blob);
    Ok(output)
}

fn open_device_label(input: &[u8]) -> CryptoResult<Vec<u8>> {
    let mut reader = Reader::new(input);
    reader.expect(LABEL_OPEN_REQUEST_MAGIC)?;
    let identity = reader.framed()?;
    let user_id = reader.take(16)?;
    let device_id = reader.take(16)?;
    let blob = reader.framed()?;
    if !reader.is_finished() {
        return Err(CryptoError::MalformedInput);
    }
    let label = enrollment::open_device_label(identity, user_id, device_id, blob)?;
    let mut output = Vec::with_capacity(LABEL_OPEN_RESPONSE_MAGIC.len() + 4 + label.len());
    output.extend_from_slice(LABEL_OPEN_RESPONSE_MAGIC);
    push_frame(&mut output, &label)?;
    Ok(output)
}

fn encode_operation(input: &[u8]) -> CryptoResult<Vec<u8>> {
    let event = decode_projection_request(input)?;
    let encoded = encode_event(&event)?;
    let mut output = Vec::new();
    reserve(&mut output, ENCODE_RESPONSE_MAGIC.len() + encoded.len())?;
    output.extend_from_slice(ENCODE_RESPONSE_MAGIC);
    output.extend_from_slice(&encoded);
    Ok(output)
}

fn decode_operation(input: &[u8]) -> CryptoResult<Vec<u8>> {
    let (event, unsupported_version) = decode_event(input)?;
    let mut output = Vec::new();
    output.extend_from_slice(DECODE_RESPONSE_MAGIC);
    if let Some(version) = unsupported_version {
        output.push(2);
        output.push(version);
        return Ok(output);
    }
    let event = event.ok_or(CryptoError::InternalFailure)?;
    output.push(u8::from(matches!(&event.body, EventBody::Unsupported)));
    encode_projection(&event, &mut output)?;
    Ok(output)
}

fn random_event_id(input: &[u8]) -> CryptoResult<Vec<u8>> {
    if !input.is_empty() {
        return Err(CryptoError::InvalidArgument);
    }
    let mut event_id = [0_u8; 16];
    RustCryptoProvider::default().random_bytes(&mut event_id)?;
    let mut output = Vec::with_capacity(RANDOM_RESPONSE_MAGIC.len() + event_id.len());
    output.extend_from_slice(RANDOM_RESPONSE_MAGIC);
    output.extend_from_slice(&event_id);
    Ok(output)
}

fn derive_dm_conversation_id(input: &[u8]) -> CryptoResult<Vec<u8>> {
    let users: &[u8; 32] = input.try_into().map_err(|_| CryptoError::InvalidArgument)?;
    let (left, right) = users.split_at(16);
    if left == right {
        return Err(CryptoError::InvalidArgument);
    }
    let mut digest_input = Vec::new();
    reserve(
        &mut digest_input,
        DM_CONVERSATION_DOMAIN.len() + users.len(),
    )?;
    digest_input.extend_from_slice(DM_CONVERSATION_DOMAIN);
    if left < right {
        digest_input.extend_from_slice(left);
        digest_input.extend_from_slice(right);
    } else {
        digest_input.extend_from_slice(right);
        digest_input.extend_from_slice(left);
    }
    conversation_response(&RustCryptoProvider::default().sha256(&digest_input)?)
}

fn derive_saved_conversation_id(input: &[u8]) -> CryptoResult<Vec<u8>> {
    if input.len() != 16 {
        return Err(CryptoError::InvalidArgument);
    }
    let mut digest_input = Vec::new();
    reserve(
        &mut digest_input,
        SAVED_CONVERSATION_DOMAIN.len() + input.len(),
    )?;
    digest_input.extend_from_slice(SAVED_CONVERSATION_DOMAIN);
    digest_input.extend_from_slice(input);
    conversation_response(&RustCryptoProvider::default().sha256(&digest_input)?)
}

fn conversation_response(conversation_id: &[u8; 32]) -> CryptoResult<Vec<u8>> {
    let mut output = Vec::new();
    reserve(
        &mut output,
        CONVERSATION_RESPONSE_MAGIC.len() + conversation_id.len(),
    )?;
    output.extend_from_slice(CONVERSATION_RESPONSE_MAGIC);
    output.extend_from_slice(conversation_id);
    Ok(output)
}

fn decode_projection_request(input: &[u8]) -> CryptoResult<ApplicationEvent> {
    let mut reader = Reader::new(input);
    if reader.take(ENCODE_REQUEST_MAGIC.len())? != ENCODE_REQUEST_MAGIC {
        return Err(CryptoError::MalformedInput);
    }
    let version = reader.u8()?;
    if version != APPLICATION_VERSION {
        return Err(CryptoError::UnsupportedVersion);
    }
    let event_id = reader.array()?;
    let conversation_id = reader.array()?;
    let kind = reader.u16()?;
    let sender_user_id = reader.array()?;
    let sender_device_id = reader.array()?;
    let sender_counter = reader.u64()?;
    let created_ms = reader.u64()?;
    if sender_counter == 0 {
        return Err(CryptoError::MalformedInput);
    }
    let reference_count = usize::from(reader.u8()?);
    if reference_count > MAX_REFERENCES {
        return Err(CryptoError::InputTooLarge);
    }
    let mut references = Vec::new();
    references
        .try_reserve_exact(reference_count)
        .map_err(|_| CryptoError::ResourceExhausted)?;
    for _ in 0..reference_count {
        references.push(reader.array()?);
    }
    if has_duplicates(&references) {
        return Err(CryptoError::MalformedInput);
    }
    let body = decode_projection_body(kind, &mut reader)?;
    if !reader.is_finished() {
        return Err(CryptoError::MalformedInput);
    }
    Ok(ApplicationEvent {
        version,
        event_id,
        conversation_id,
        kind,
        sender_user_id,
        sender_device_id,
        sender_counter,
        created_ms,
        references,
        body,
    })
}

fn decode_projection_body(kind: u16, reader: &mut Reader<'_>) -> CryptoResult<EventBody> {
    match kind {
        KIND_MESSAGE_CREATE => {
            let message_id = reader.array()?;
            let content_type = reader.u8()?;
            if content_type > 2 {
                return Err(CryptoError::UnsupportedOperation);
            }
            let text = framed_text(reader, MAX_TEXT_BYTES, MAX_TEXT_SCALARS, content_type == 0)?;
            let reply_to = optional_id(reader)?;
            let quote_fallback = optional_text(reader, MAX_QUOTE_BYTES, MAX_QUOTE_SCALARS)?;
            let attachments = if content_type == 0 {
                Vec::new()
            } else {
                let count = usize::from(reader.u8()?);
                if count > 32 {
                    return Err(CryptoError::InputTooLarge);
                }
                let mut attachments = Vec::new();
                for _ in 0..count {
                    attachments.push(decode_projection_attachment(reader)?);
                }
                attachments
            };
            if content_type != 0 && attachments.is_empty() {
                return Err(CryptoError::MalformedInput);
            }
            Ok(EventBody::MessageCreate {
                message_id,
                content_type,
                text,
                reply_to,
                quote_fallback,
                attachments,
            })
        }
        KIND_MESSAGE_EDIT => {
            let target = reader.array()?;
            let revision = reader.u32()?;
            if revision == 0 {
                return Err(CryptoError::MalformedInput);
            }
            let replacement = framed_text(reader, MAX_TEXT_BYTES, MAX_TEXT_SCALARS, true)?;
            Ok(EventBody::MessageEdit {
                target,
                revision,
                replacement,
            })
        }
        KIND_MESSAGE_DELETE => Ok(EventBody::MessageDelete {
            target: reader.array()?,
        }),
        KIND_REACTION_SET => {
            let target = reader.array()?;
            let emoji = optional_text(reader, MAX_EMOJI_BYTES, MAX_EMOJI_BYTES)?;
            if emoji
                .as_deref()
                .is_some_and(|value| !is_single_emoji(value))
            {
                return Err(CryptoError::MalformedInput);
            }
            Ok(EventBody::ReactionSet { target, emoji })
        }
        KIND_PIN_SET => Ok(EventBody::PinSet {
            target: reader.array()?,
            pinned: reader.boolean()?,
        }),
        KIND_RECEIPT_DELIVERED | KIND_RECEIPT_READ => {
            let count = usize::from(reader.u8()?);
            if count == 0 || count > MAX_REFERENCES {
                return Err(CryptoError::MalformedInput);
            }
            let mut message_ids = Vec::new();
            message_ids
                .try_reserve_exact(count)
                .map_err(|_| CryptoError::ResourceExhausted)?;
            for _ in 0..count {
                message_ids.push(reader.array()?);
            }
            if has_duplicates(&message_ids) {
                return Err(CryptoError::MalformedInput);
            }
            Ok(EventBody::Receipt { message_ids })
        }
        KIND_TYPING_SET => Ok(EventBody::TypingSet {
            is_typing: reader.boolean()?,
            expires_ms: reader.u64()?,
        }),
        _ => Err(CryptoError::UnsupportedOperation),
    }
}

fn encode_event(event: &ApplicationEvent) -> CryptoResult<Vec<u8>> {
    let mut output = Vec::new();
    output
        .try_reserve_exact(512)
        .map_err(|_| CryptoError::ResourceExhausted)?;
    let mut encoder = Encoder::new(&mut output);
    encoder.map(10).map_err(|_| CryptoError::InternalFailure)?;
    encode_key(&mut encoder, 0)?;
    encoder
        .u8(event.version)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(&mut encoder, 1)?;
    encoder
        .bytes(&event.event_id)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(&mut encoder, 2)?;
    encoder
        .bytes(&event.conversation_id)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(&mut encoder, 3)?;
    encoder
        .u16(event.kind)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(&mut encoder, 4)?;
    encoder
        .bytes(&event.sender_user_id)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(&mut encoder, 5)?;
    encoder
        .bytes(&event.sender_device_id)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(&mut encoder, 6)?;
    encoder
        .u64(event.sender_counter)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(&mut encoder, 7)?;
    encoder
        .u64(event.created_ms)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(&mut encoder, 8)?;
    encoder
        .array(u64::try_from(event.references.len()).map_err(|_| CryptoError::InputTooLarge)?)
        .map_err(|_| CryptoError::InternalFailure)?;
    for reference in &event.references {
        encoder
            .bytes(reference)
            .map_err(|_| CryptoError::InternalFailure)?;
    }
    encode_key(&mut encoder, 9)?;
    encode_event_body(&mut encoder, &event.body)?;
    if output.len() > MAX_CBOR_BYTES || output.len() > APPLICATION_MAX_IO_BYTES {
        return Err(CryptoError::InputTooLarge);
    }
    Ok(output)
}

#[allow(clippy::too_many_lines)] // Keeping every canonical event shape in one encoder makes key ordering auditable.
fn encode_event_body(encoder: &mut Encoder<&mut Vec<u8>>, body: &EventBody) -> CryptoResult<()> {
    match body {
        EventBody::MessageCreate {
            message_id,
            content_type,
            text,
            reply_to,
            quote_fallback,
            attachments,
        } => {
            if (*content_type == 0) != attachments.is_empty() {
                return Err(CryptoError::MalformedInput);
            }
            encoder
                .map(if attachments.is_empty() { 5 } else { 6 })
                .map_err(|_| CryptoError::InternalFailure)?;
            encode_key(encoder, 0)?;
            encoder
                .bytes(message_id)
                .map_err(|_| CryptoError::InternalFailure)?;
            encode_key(encoder, 1)?;
            encoder
                .u8(*content_type)
                .map_err(|_| CryptoError::InternalFailure)?;
            encode_key(encoder, 2)?;
            encoder
                .str(text)
                .map_err(|_| CryptoError::InternalFailure)?;
            encode_key(encoder, 3)?;
            encode_optional_id(encoder, reply_to.as_ref())?;
            encode_key(encoder, 4)?;
            encode_optional_text(encoder, quote_fallback.as_deref())?;
            if !attachments.is_empty() {
                encode_key(encoder, 5)?;
                encoder
                    .array(
                        u64::try_from(attachments.len()).map_err(|_| CryptoError::InputTooLarge)?,
                    )
                    .map_err(|_| CryptoError::InternalFailure)?;
                for attachment in attachments {
                    encode_cbor_attachment(encoder, attachment)?;
                }
            }
        }
        EventBody::MessageEdit {
            target,
            revision,
            replacement,
        } => {
            encoder.map(3).map_err(|_| CryptoError::InternalFailure)?;
            encode_key(encoder, 0)?;
            encoder
                .bytes(target)
                .map_err(|_| CryptoError::InternalFailure)?;
            encode_key(encoder, 1)?;
            encoder
                .str(replacement)
                .map_err(|_| CryptoError::InternalFailure)?;
            encode_key(encoder, 2)?;
            encoder
                .u32(*revision)
                .map_err(|_| CryptoError::InternalFailure)?;
        }
        EventBody::MessageDelete { target } => {
            encoder.map(1).map_err(|_| CryptoError::InternalFailure)?;
            encode_key(encoder, 0)?;
            encoder
                .bytes(target)
                .map_err(|_| CryptoError::InternalFailure)?;
        }
        EventBody::ReactionSet { target, emoji } => {
            encoder.map(2).map_err(|_| CryptoError::InternalFailure)?;
            encode_key(encoder, 0)?;
            encoder
                .bytes(target)
                .map_err(|_| CryptoError::InternalFailure)?;
            encode_key(encoder, 1)?;
            encode_optional_text(encoder, emoji.as_deref())?;
        }
        EventBody::PinSet { target, pinned } => {
            encoder.map(2).map_err(|_| CryptoError::InternalFailure)?;
            encode_key(encoder, 0)?;
            encoder
                .bytes(target)
                .map_err(|_| CryptoError::InternalFailure)?;
            encode_key(encoder, 1)?;
            encoder
                .bool(*pinned)
                .map_err(|_| CryptoError::InternalFailure)?;
        }
        EventBody::Receipt { message_ids } => {
            encoder.map(1).map_err(|_| CryptoError::InternalFailure)?;
            encode_key(encoder, 0)?;
            encoder
                .array(u64::try_from(message_ids.len()).map_err(|_| CryptoError::InputTooLarge)?)
                .map_err(|_| CryptoError::InternalFailure)?;
            for message_id in message_ids {
                encoder
                    .bytes(message_id)
                    .map_err(|_| CryptoError::InternalFailure)?;
            }
        }
        EventBody::TypingSet {
            is_typing,
            expires_ms,
        } => {
            encoder.map(2).map_err(|_| CryptoError::InternalFailure)?;
            encode_key(encoder, 0)?;
            encoder
                .bool(*is_typing)
                .map_err(|_| CryptoError::InternalFailure)?;
            encode_key(encoder, 1)?;
            encoder
                .u64(*expires_ms)
                .map_err(|_| CryptoError::InternalFailure)?;
        }
        EventBody::Unsupported => return Err(CryptoError::UnsupportedOperation),
    }
    Ok(())
}

fn encode_cbor_attachment(
    encoder: &mut Encoder<&mut Vec<u8>>,
    attachment: &AttachmentDescriptor,
) -> CryptoResult<()> {
    encoder.map(14).map_err(|_| CryptoError::InternalFailure)?;
    encode_key(encoder, 0)?;
    encoder
        .str(&attachment.capability_id)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(encoder, 1)?;
    encoder
        .bytes(&attachment.key)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(encoder, 2)?;
    encoder
        .bytes(&attachment.header)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(encoder, 3)?;
    encoder
        .bytes(&attachment.stream_header)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(encoder, 4)?;
    encoder
        .u64(attachment.encrypted_size)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(encoder, 5)?;
    encoder
        .u64(attachment.bucket_size)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(encoder, 6)?;
    encoder
        .u64(attachment.plaintext_size)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(encoder, 7)?;
    encoder
        .str(&attachment.display_name)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(encoder, 8)?;
    encoder
        .str(&attachment.mime_type)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(encoder, 9)?;
    encoder
        .u8(attachment.media_kind)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(encoder, 10)?;
    encoder
        .u32(attachment.width)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(encoder, 11)?;
    encoder
        .u32(attachment.height)
        .map_err(|_| CryptoError::InternalFailure)?;
    encode_key(encoder, 12)?;
    encode_optional_text(encoder, attachment.caption.as_deref())?;
    encode_key(encoder, 13)?;
    encoder
        .bytes(attachment.thumbnail.as_deref().unwrap_or_default())
        .map_err(|_| CryptoError::InternalFailure)?;
    Ok(())
}

fn read_cbor_attachment(decoder: &mut Decoder<'_>) -> CryptoResult<AttachmentDescriptor> {
    read_exact_map(decoder, 14)?;
    read_key(decoder, 0)?;
    let capability_id = read_text(decoder, 43, 43, true)?;
    if !capability_id
        .as_bytes()
        .iter()
        .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_' || *byte == b'-')
    {
        return Err(CryptoError::MalformedInput);
    }
    read_key(decoder, 1)?;
    let key = read_exact_bytes(decoder)?;
    read_key(decoder, 2)?;
    let header = read_exact_bytes(decoder)?;
    read_key(decoder, 3)?;
    let stream_header = read_exact_bytes(decoder)?;
    read_key(decoder, 4)?;
    let encrypted_size = read_uint(decoder)?;
    read_key(decoder, 5)?;
    let bucket_size = read_uint(decoder)?;
    read_key(decoder, 6)?;
    let plaintext_size = read_uint(decoder)?;
    read_key(decoder, 7)?;
    let display_name = read_text(decoder, 128, 128, true)?;
    read_key(decoder, 8)?;
    let mime_type = read_text(decoder, 128, 128, true)?;
    read_key(decoder, 9)?;
    let media_kind = u8::try_from(read_uint(decoder)?).map_err(|_| CryptoError::MalformedInput)?;
    if media_kind > 1 {
        return Err(CryptoError::MalformedInput);
    }
    read_key(decoder, 10)?;
    let width = u32::try_from(read_uint(decoder)?).map_err(|_| CryptoError::MalformedInput)?;
    read_key(decoder, 11)?;
    let height = u32::try_from(read_uint(decoder)?).map_err(|_| CryptoError::MalformedInput)?;
    read_key(decoder, 12)?;
    let caption = read_nullable_text(decoder, MAX_TEXT_BYTES, MAX_TEXT_SCALARS)?;
    read_key(decoder, 13)?;
    let thumbnail = read_bytes(decoder)?;
    if thumbnail.len() > 65_536 {
        return Err(CryptoError::InputTooLarge);
    }
    Ok(AttachmentDescriptor {
        capability_id,
        key,
        header,
        stream_header,
        encrypted_size,
        bucket_size,
        plaintext_size,
        display_name,
        mime_type,
        media_kind,
        width,
        height,
        caption,
        thumbnail: if thumbnail.is_empty() {
            None
        } else {
            Some(thumbnail.to_vec())
        },
    })
}

fn decode_event(input: &[u8]) -> CryptoResult<(Option<ApplicationEvent>, Option<u8>)> {
    if input.is_empty() || input.len() > APPLICATION_MAX_IO_BYTES {
        return Err(if input.is_empty() {
            CryptoError::MalformedInput
        } else {
            CryptoError::InputTooLarge
        });
    }
    let mut decoder = Decoder::new(input);
    let field_count = read_map_len(&mut decoder)?;
    read_key(&mut decoder, 0)?;
    let version = read_uint(&mut decoder)?;
    let version = u8::try_from(version).map_err(|_| CryptoError::MalformedInput)?;
    if version != APPLICATION_VERSION {
        return Ok((None, Some(version)));
    }
    if field_count != 10 {
        return Err(CryptoError::MalformedInput);
    }
    read_key(&mut decoder, 1)?;
    let event_id = read_exact_bytes(&mut decoder)?;
    read_key(&mut decoder, 2)?;
    let conversation_id = read_exact_bytes(&mut decoder)?;
    read_key(&mut decoder, 3)?;
    let kind = u16::try_from(read_uint(&mut decoder)?).map_err(|_| CryptoError::MalformedInput)?;
    read_key(&mut decoder, 4)?;
    let sender_user_id = read_exact_bytes(&mut decoder)?;
    read_key(&mut decoder, 5)?;
    let sender_device_id = read_exact_bytes(&mut decoder)?;
    read_key(&mut decoder, 6)?;
    let sender_counter = read_uint(&mut decoder)?;
    if sender_counter == 0 {
        return Err(CryptoError::MalformedInput);
    }
    read_key(&mut decoder, 7)?;
    let created_ms = read_uint(&mut decoder)?;
    read_key(&mut decoder, 8)?;
    let reference_count = read_array_len(&mut decoder)?;
    if reference_count > MAX_REFERENCES {
        return Err(CryptoError::InputTooLarge);
    }
    let mut references = Vec::new();
    references
        .try_reserve_exact(reference_count)
        .map_err(|_| CryptoError::ResourceExhausted)?;
    for _ in 0..reference_count {
        references.push(read_exact_bytes(&mut decoder)?);
    }
    if has_duplicates(&references) {
        return Err(CryptoError::MalformedInput);
    }
    read_key(&mut decoder, 9)?;
    let body = if is_supported_kind(kind) {
        decode_cbor_body(kind, &mut decoder)?
    } else {
        validate_unknown_body(&mut decoder)?;
        EventBody::Unsupported
    };
    if decoder.position() != input.len() {
        return Err(CryptoError::MalformedInput);
    }
    Ok((
        Some(ApplicationEvent {
            version,
            event_id,
            conversation_id,
            kind,
            sender_user_id,
            sender_device_id,
            sender_counter,
            created_ms,
            references,
            body,
        }),
        None,
    ))
}

/// Validate an unknown kind structurally without interpreting its semantics.
///
/// Future bodies remain opaque, but still obey the application protocol's
/// deterministic-CBOR resource and canonical-encoding rules.
fn validate_unknown_body(decoder: &mut Decoder<'_>) -> CryptoResult<()> {
    if peek(decoder)? >> 5 != 5 {
        return Err(CryptoError::MalformedInput);
    }
    let mut item_count = 0_u32;
    validate_unknown_value(decoder, 2, &mut item_count)
}

fn validate_unknown_value(
    decoder: &mut Decoder<'_>,
    depth: usize,
    item_count: &mut u32,
) -> CryptoResult<()> {
    if depth > MAX_APPLICATION_CBOR_DEPTH {
        return Err(CryptoError::InputTooLarge);
    }
    *item_count = item_count
        .checked_add(1)
        .ok_or(CryptoError::InputTooLarge)?;
    if *item_count > MAX_CBOR_ITEMS {
        return Err(CryptoError::InputTooLarge);
    }

    match peek(decoder)? {
        first if first >> 5 == 0 => {
            read_uint(decoder)?;
        }
        first if first >> 5 == 2 => {
            read_bytes(decoder)?;
        }
        first if first >> 5 == 3 => {
            read_text(
                decoder,
                APPLICATION_MAX_IO_BYTES,
                APPLICATION_MAX_IO_BYTES,
                false,
            )?;
        }
        first if first >> 5 == 4 => {
            let length = read_array_len(decoder)?;
            let remaining = MAX_CBOR_ITEMS.saturating_sub(*item_count);
            if u32::try_from(length).map_or(true, |length| length > remaining) {
                return Err(CryptoError::InputTooLarge);
            }
            for _ in 0..length {
                validate_unknown_value(decoder, depth + 1, item_count)?;
            }
        }
        first if first >> 5 == 5 => {
            let length = read_map_len(decoder)?;
            if length > MAX_APPLICATION_MAP_ENTRIES {
                return Err(CryptoError::InputTooLarge);
            }
            let mut previous_key = None;
            for _ in 0..length {
                *item_count = item_count
                    .checked_add(1)
                    .ok_or(CryptoError::InputTooLarge)?;
                if *item_count > MAX_CBOR_ITEMS {
                    return Err(CryptoError::InputTooLarge);
                }
                let key = read_uint(decoder)?;
                if previous_key.is_some_and(|previous| key <= previous) {
                    return Err(CryptoError::MalformedInput);
                }
                previous_key = Some(key);
                validate_unknown_value(decoder, depth + 1, item_count)?;
            }
        }
        0xf4 | 0xf5 => {
            read_bool(decoder)?;
        }
        0xf6 => {
            decoder.null().map_err(|_| CryptoError::MalformedInput)?;
        }
        _ => return Err(CryptoError::MalformedInput),
    }
    Ok(())
}

#[allow(clippy::too_many_lines)]
fn decode_cbor_body(kind: u16, decoder: &mut Decoder<'_>) -> CryptoResult<EventBody> {
    match kind {
        KIND_MESSAGE_CREATE => {
            let map_len = read_map_len(decoder)?;
            if map_len != 5 && map_len != 6 {
                return Err(CryptoError::MalformedInput);
            }
            read_key(decoder, 0)?;
            let message_id = read_exact_bytes(decoder)?;
            read_key(decoder, 1)?;
            let content_type = read_uint(decoder)?;
            if content_type > 2 {
                return Err(CryptoError::UnsupportedOperation);
            }
            read_key(decoder, 2)?;
            let text = read_text(decoder, MAX_TEXT_BYTES, MAX_TEXT_SCALARS, content_type == 0)?;
            read_key(decoder, 3)?;
            let reply_to = read_nullable_id(decoder)?;
            read_key(decoder, 4)?;
            let quote_fallback = read_nullable_text(decoder, MAX_QUOTE_BYTES, MAX_QUOTE_SCALARS)?;
            let attachments = if map_len == 6 {
                read_key(decoder, 5)?;
                let count = read_array_len(decoder)?;
                if count > 32 {
                    return Err(CryptoError::InputTooLarge);
                }
                let mut attachments = Vec::new();
                for _ in 0..count {
                    attachments.push(read_cbor_attachment(decoder)?);
                }
                attachments
            } else {
                Vec::new()
            };
            if (content_type == 0) != attachments.is_empty() {
                return Err(CryptoError::MalformedInput);
            }
            Ok(EventBody::MessageCreate {
                message_id,
                content_type: u8::try_from(content_type)
                    .map_err(|_| CryptoError::MalformedInput)?,
                text,
                reply_to,
                quote_fallback,
                attachments,
            })
        }
        KIND_MESSAGE_EDIT => {
            read_exact_map(decoder, 3)?;
            read_key(decoder, 0)?;
            let target = read_exact_bytes(decoder)?;
            read_key(decoder, 1)?;
            let replacement = read_text(decoder, MAX_TEXT_BYTES, MAX_TEXT_SCALARS, true)?;
            read_key(decoder, 2)?;
            let revision =
                u32::try_from(read_uint(decoder)?).map_err(|_| CryptoError::MalformedInput)?;
            if revision == 0 {
                return Err(CryptoError::MalformedInput);
            }
            Ok(EventBody::MessageEdit {
                target,
                revision,
                replacement,
            })
        }
        KIND_MESSAGE_DELETE => {
            read_exact_map(decoder, 1)?;
            read_key(decoder, 0)?;
            Ok(EventBody::MessageDelete {
                target: read_exact_bytes(decoder)?,
            })
        }
        KIND_REACTION_SET => {
            read_exact_map(decoder, 2)?;
            read_key(decoder, 0)?;
            let target = read_exact_bytes(decoder)?;
            read_key(decoder, 1)?;
            let emoji = read_nullable_text(decoder, MAX_EMOJI_BYTES, MAX_EMOJI_BYTES)?;
            if emoji
                .as_deref()
                .is_some_and(|value| !is_single_emoji(value))
            {
                return Err(CryptoError::MalformedInput);
            }
            Ok(EventBody::ReactionSet { target, emoji })
        }
        KIND_PIN_SET => {
            read_exact_map(decoder, 2)?;
            read_key(decoder, 0)?;
            let target = read_exact_bytes(decoder)?;
            read_key(decoder, 1)?;
            Ok(EventBody::PinSet {
                target,
                pinned: read_bool(decoder)?,
            })
        }
        KIND_RECEIPT_DELIVERED | KIND_RECEIPT_READ => {
            read_exact_map(decoder, 1)?;
            read_key(decoder, 0)?;
            let count = read_array_len(decoder)?;
            if count == 0 || count > MAX_REFERENCES {
                return Err(CryptoError::MalformedInput);
            }
            let mut message_ids = Vec::new();
            message_ids
                .try_reserve_exact(count)
                .map_err(|_| CryptoError::ResourceExhausted)?;
            for _ in 0..count {
                message_ids.push(read_exact_bytes(decoder)?);
            }
            if has_duplicates(&message_ids) {
                return Err(CryptoError::MalformedInput);
            }
            Ok(EventBody::Receipt { message_ids })
        }
        KIND_TYPING_SET => {
            read_exact_map(decoder, 2)?;
            read_key(decoder, 0)?;
            let is_typing = read_bool(decoder)?;
            read_key(decoder, 1)?;
            Ok(EventBody::TypingSet {
                is_typing,
                expires_ms: read_uint(decoder)?,
            })
        }
        _ => Err(CryptoError::UnsupportedOperation),
    }
}

fn encode_projection(event: &ApplicationEvent, output: &mut Vec<u8>) -> CryptoResult<()> {
    output.push(event.version);
    output.extend_from_slice(&event.event_id);
    output.extend_from_slice(&event.conversation_id);
    push_u16(output, event.kind);
    output.extend_from_slice(&event.sender_user_id);
    output.extend_from_slice(&event.sender_device_id);
    push_u64(output, event.sender_counter);
    push_u64(output, event.created_ms);
    output.push(u8::try_from(event.references.len()).map_err(|_| CryptoError::InputTooLarge)?);
    for reference in &event.references {
        output.extend_from_slice(reference);
    }
    match &event.body {
        EventBody::MessageCreate {
            message_id,
            content_type,
            text,
            reply_to,
            quote_fallback,
            attachments,
        } => {
            output.extend_from_slice(message_id);
            output.push(*content_type);
            push_frame(output, text.as_bytes())?;
            push_optional_id(output, reply_to.as_ref());
            push_optional_text(output, quote_fallback.as_deref())?;
            if !attachments.is_empty() {
                output
                    .push(u8::try_from(attachments.len()).map_err(|_| CryptoError::InputTooLarge)?);
                for attachment in attachments {
                    push_projection_attachment(output, attachment)?;
                }
            }
        }
        EventBody::MessageEdit {
            target,
            revision,
            replacement,
        } => {
            output.extend_from_slice(target);
            push_u32(output, *revision);
            push_frame(output, replacement.as_bytes())?;
        }
        EventBody::MessageDelete { target } => output.extend_from_slice(target),
        EventBody::ReactionSet { target, emoji } => {
            output.extend_from_slice(target);
            push_optional_text(output, emoji.as_deref())?;
        }
        EventBody::PinSet { target, pinned } => {
            output.extend_from_slice(target);
            output.push(u8::from(*pinned));
        }
        EventBody::Receipt { message_ids } => {
            output.push(u8::try_from(message_ids.len()).map_err(|_| CryptoError::InputTooLarge)?);
            for message_id in message_ids {
                output.extend_from_slice(message_id);
            }
        }
        EventBody::TypingSet {
            is_typing,
            expires_ms,
        } => {
            output.push(u8::from(*is_typing));
            push_u64(output, *expires_ms);
        }
        EventBody::Unsupported => {}
    }
    if output.len() > APPLICATION_MAX_IO_BYTES {
        return Err(CryptoError::InputTooLarge);
    }
    Ok(())
}

pub(crate) fn encode_key(encoder: &mut Encoder<&mut Vec<u8>>, key: u8) -> CryptoResult<()> {
    encoder
        .u8(key)
        .map(|_| ())
        .map_err(|_| CryptoError::InternalFailure)
}

fn encode_optional_id(
    encoder: &mut Encoder<&mut Vec<u8>>,
    value: Option<&[u8; 16]>,
) -> CryptoResult<()> {
    match value {
        Some(value) => encoder
            .bytes(value)
            .map(|_| ())
            .map_err(|_| CryptoError::InternalFailure),
        None => encoder
            .null()
            .map(|_| ())
            .map_err(|_| CryptoError::InternalFailure),
    }
}

fn encode_optional_text(
    encoder: &mut Encoder<&mut Vec<u8>>,
    value: Option<&str>,
) -> CryptoResult<()> {
    match value {
        Some(value) => encoder
            .str(value)
            .map(|_| ())
            .map_err(|_| CryptoError::InternalFailure),
        None => encoder
            .null()
            .map(|_| ())
            .map_err(|_| CryptoError::InternalFailure),
    }
}

fn optional_id(reader: &mut Reader<'_>) -> CryptoResult<Option<[u8; 16]>> {
    match reader.u8()? {
        0 => Ok(None),
        1 => Ok(Some(reader.array()?)),
        _ => Err(CryptoError::MalformedInput),
    }
}

fn optional_text(
    reader: &mut Reader<'_>,
    maximum_bytes: usize,
    maximum_scalars: usize,
) -> CryptoResult<Option<String>> {
    match reader.u8()? {
        0 => Ok(None),
        1 => framed_text(reader, maximum_bytes, maximum_scalars, true).map(Some),
        _ => Err(CryptoError::MalformedInput),
    }
}

fn framed_text(
    reader: &mut Reader<'_>,
    maximum_bytes: usize,
    maximum_scalars: usize,
    require_non_empty: bool,
) -> CryptoResult<String> {
    let bytes = reader.framed()?;
    if bytes.len() > maximum_bytes || (require_non_empty && bytes.is_empty()) {
        return Err(if bytes.len() > maximum_bytes {
            CryptoError::InputTooLarge
        } else {
            CryptoError::MalformedInput
        });
    }
    let text = std::str::from_utf8(bytes).map_err(|_| CryptoError::MalformedInput)?;
    if text.chars().count() > maximum_scalars {
        return Err(CryptoError::InputTooLarge);
    }
    Ok(text.to_owned())
}

fn decode_projection_attachment(reader: &mut Reader<'_>) -> CryptoResult<AttachmentDescriptor> {
    let capability_id = framed_text(reader, 43, 43, true)?;
    if !capability_id
        .as_bytes()
        .iter()
        .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_' || *byte == b'-')
    {
        return Err(CryptoError::MalformedInput);
    }
    let key = reader.array()?;
    let header = reader.array()?;
    let stream_header = reader.array()?;
    let encrypted_size = reader.u64()?;
    let bucket_size = reader.u64()?;
    let plaintext_size = reader.u64()?;
    let display_name = framed_text(reader, 128, 128, true)?;
    let mime_type = framed_text(reader, 128, 128, true)?;
    let media_kind = reader.u8()?;
    if media_kind > 1 {
        return Err(CryptoError::MalformedInput);
    }
    let width = reader.u32()?;
    let height = reader.u32()?;
    let caption = optional_text(reader, MAX_TEXT_BYTES, MAX_TEXT_SCALARS)?;
    let thumbnail_length =
        usize::try_from(reader.u32()?).map_err(|_| CryptoError::InputTooLarge)?;
    if thumbnail_length > 65_536 {
        return Err(CryptoError::InputTooLarge);
    }
    let thumbnail = if thumbnail_length == 0 {
        None
    } else {
        Some(reader.take(thumbnail_length)?.to_vec())
    };
    Ok(AttachmentDescriptor {
        capability_id,
        key,
        header,
        stream_header,
        encrypted_size,
        bucket_size,
        plaintext_size,
        display_name,
        mime_type,
        media_kind,
        width,
        height,
        caption,
        thumbnail,
    })
}

fn push_projection_attachment(
    output: &mut Vec<u8>,
    attachment: &AttachmentDescriptor,
) -> CryptoResult<()> {
    push_frame(output, attachment.capability_id.as_bytes())?;
    output.extend_from_slice(&attachment.key);
    output.extend_from_slice(&attachment.header);
    output.extend_from_slice(&attachment.stream_header);
    push_u64(output, attachment.encrypted_size);
    push_u64(output, attachment.bucket_size);
    push_u64(output, attachment.plaintext_size);
    push_frame(output, attachment.display_name.as_bytes())?;
    push_frame(output, attachment.mime_type.as_bytes())?;
    output.push(attachment.media_kind);
    push_u32(output, attachment.width);
    push_u32(output, attachment.height);
    push_optional_text(output, attachment.caption.as_deref())?;
    let thumbnail = attachment.thumbnail.as_deref().unwrap_or_default();
    push_u32(
        output,
        u32::try_from(thumbnail.len()).map_err(|_| CryptoError::InputTooLarge)?,
    );
    output.extend_from_slice(thumbnail);
    Ok(())
}

fn push_optional_id(output: &mut Vec<u8>, value: Option<&[u8; 16]>) {
    match value {
        Some(value) => {
            output.push(1);
            output.extend_from_slice(value);
        }
        None => output.push(0),
    }
}

fn push_optional_text(output: &mut Vec<u8>, value: Option<&str>) -> CryptoResult<()> {
    if let Some(value) = value {
        output.push(1);
        push_frame(output, value.as_bytes())
    } else {
        output.push(0);
        Ok(())
    }
}

pub(crate) fn read_exact_map(decoder: &mut Decoder<'_>, expected: usize) -> CryptoResult<()> {
    if read_map_len(decoder)? != expected {
        return Err(CryptoError::MalformedInput);
    }
    Ok(())
}

pub(crate) fn read_map_len(decoder: &mut Decoder<'_>) -> CryptoResult<usize> {
    let first = peek(decoder)?;
    if first >> 5 != 5 || first & 0x1f == 0x1f {
        return Err(CryptoError::MalformedInput);
    }
    let length = decoder.map().map_err(|_| CryptoError::MalformedInput)?;
    let length = usize::try_from(length.ok_or(CryptoError::MalformedInput)?)
        .map_err(|_| CryptoError::InputTooLarge)?;
    if !canonical_length_header(first, length, 5) {
        return Err(CryptoError::MalformedInput);
    }
    Ok(length)
}

pub(crate) fn read_key(decoder: &mut Decoder<'_>, expected: u8) -> CryptoResult<()> {
    if read_uint(decoder)? != u64::from(expected) {
        return Err(CryptoError::MalformedInput);
    }
    Ok(())
}

pub(crate) fn read_uint(decoder: &mut Decoder<'_>) -> CryptoResult<u64> {
    let first = peek(decoder)?;
    if first >> 5 != 0 || first & 0x1f == 0x1f {
        return Err(CryptoError::MalformedInput);
    }
    let value = decoder.u64().map_err(|_| CryptoError::MalformedInput)?;
    let canonical = match value {
        0..=23 => first == u8::try_from(value).map_err(|_| CryptoError::MalformedInput)?,
        24..=0xff => first == 0x18,
        0x100..=0xffff => first == 0x19,
        0x1_0000..=0xffff_ffff => first == 0x1a,
        _ => first == 0x1b,
    };
    if !canonical {
        return Err(CryptoError::MalformedInput);
    }
    Ok(value)
}

pub(crate) fn read_array_len(decoder: &mut Decoder<'_>) -> CryptoResult<usize> {
    let first = peek(decoder)?;
    if first >> 5 != 4 || first & 0x1f == 0x1f {
        return Err(CryptoError::MalformedInput);
    }
    let length = decoder
        .array()
        .map_err(|_| CryptoError::MalformedInput)?
        .ok_or(CryptoError::MalformedInput)?;
    let length = usize::try_from(length).map_err(|_| CryptoError::InputTooLarge)?;
    let canonical = match length {
        0..=23 => first == 0x80 | u8::try_from(length).unwrap_or(u8::MAX),
        24..=0xff => first == 0x98,
        0x100..=0xffff => first == 0x99,
        0x1_0000..=0xffff_ffff => first == 0x9a,
        _ => first == 0x9b,
    };
    if !canonical {
        return Err(CryptoError::MalformedInput);
    }
    Ok(length)
}

pub(crate) fn read_exact_bytes<const LENGTH: usize>(
    decoder: &mut Decoder<'_>,
) -> CryptoResult<[u8; LENGTH]> {
    let bytes = read_bytes(decoder)?;
    bytes.try_into().map_err(|_| CryptoError::MalformedInput)
}

pub(crate) fn read_bytes<'a>(decoder: &mut Decoder<'a>) -> CryptoResult<&'a [u8]> {
    let first = peek(decoder)?;
    if first >> 5 != 2 || first & 0x1f == 0x1f {
        return Err(CryptoError::MalformedInput);
    }
    let bytes = decoder.bytes().map_err(|_| CryptoError::MalformedInput)?;
    if !canonical_length_header(first, bytes.len(), 2) {
        return Err(CryptoError::MalformedInput);
    }
    Ok(bytes)
}

pub(crate) fn read_text(
    decoder: &mut Decoder<'_>,
    maximum_bytes: usize,
    maximum_scalars: usize,
    require_non_empty: bool,
) -> CryptoResult<String> {
    let first = peek(decoder)?;
    if first >> 5 != 3 || first & 0x1f == 0x1f {
        return Err(CryptoError::MalformedInput);
    }
    let text = decoder.str().map_err(|_| CryptoError::MalformedInput)?;
    if !canonical_length_header(first, text.len(), 3) {
        return Err(CryptoError::MalformedInput);
    }
    if text.len() > maximum_bytes || text.chars().count() > maximum_scalars {
        return Err(CryptoError::InputTooLarge);
    }
    if require_non_empty && text.is_empty() {
        return Err(CryptoError::MalformedInput);
    }
    Ok(text.to_owned())
}

fn read_nullable_id(decoder: &mut Decoder<'_>) -> CryptoResult<Option<[u8; 16]>> {
    if peek(decoder)? == 0xf6 {
        decoder.null().map_err(|_| CryptoError::MalformedInput)?;
        Ok(None)
    } else {
        read_exact_bytes(decoder).map(Some)
    }
}

fn read_nullable_text(
    decoder: &mut Decoder<'_>,
    maximum_bytes: usize,
    maximum_scalars: usize,
) -> CryptoResult<Option<String>> {
    if peek(decoder)? == 0xf6 {
        decoder.null().map_err(|_| CryptoError::MalformedInput)?;
        Ok(None)
    } else {
        read_text(decoder, maximum_bytes, maximum_scalars, true).map(Some)
    }
}

fn read_bool(decoder: &mut Decoder<'_>) -> CryptoResult<bool> {
    match peek(decoder)? {
        0xf4 => {
            decoder.bool().map_err(|_| CryptoError::MalformedInput)?;
            Ok(false)
        }
        0xf5 => {
            decoder.bool().map_err(|_| CryptoError::MalformedInput)?;
            Ok(true)
        }
        _ => Err(CryptoError::MalformedInput),
    }
}

pub(crate) fn peek(decoder: &Decoder<'_>) -> CryptoResult<u8> {
    decoder
        .input()
        .get(decoder.position())
        .copied()
        .ok_or(CryptoError::MalformedInput)
}

pub(crate) fn canonical_length_header(first: u8, length: usize, major: u8) -> bool {
    match length {
        0..=23 => first == (major << 5) | u8::try_from(length).unwrap_or(u8::MAX),
        24..=0xff => first == (major << 5) | 0x18,
        0x100..=0xffff => first == (major << 5) | 0x19,
        0x1_0000..=0xffff_ffff => first == (major << 5) | 0x1a,
        _ => first == (major << 5) | 0x1b,
    }
}

fn has_duplicates(values: &[[u8; 16]]) -> bool {
    values
        .iter()
        .enumerate()
        .any(|(index, value)| values[..index].contains(value))
}

fn is_supported_kind(kind: u16) -> bool {
    matches!(
        kind,
        KIND_MESSAGE_CREATE
            | KIND_MESSAGE_EDIT
            | KIND_MESSAGE_DELETE
            | KIND_REACTION_SET
            | KIND_PIN_SET
            | KIND_RECEIPT_DELIVERED
            | KIND_RECEIPT_READ
            | KIND_TYPING_SET
    )
}

/// Conservative version-1 emoji cluster validation without locale data.
///
/// It accepts one emoji base (or a two-regional-indicator flag), optional
/// variation/modifier code points, and ZWJ-joined emoji bases. Combining text
/// marks and multiple unjoined bases are rejected, which also rejects
/// non-normalized text masquerading as a reaction.
fn is_single_emoji(value: &str) -> bool {
    let scalars: Vec<char> = value.chars().collect();
    if scalars.is_empty() || value.len() > MAX_EMOJI_BYTES {
        return false;
    }
    if scalars.len() == 2 && scalars.iter().all(|scalar| is_regional_indicator(*scalar)) {
        return true;
    }
    if scalars.last() == Some(&'\u{20e3}') {
        return matches!(scalars.first(), Some('0'..='9' | '#' | '*'))
            && scalars[1..scalars.len() - 1]
                .iter()
                .all(|scalar| *scalar == '\u{fe0f}');
    }
    let mut expect_base = true;
    let mut saw_base = false;
    for scalar in scalars {
        if scalar == '\u{200d}' {
            if expect_base || !saw_base {
                return false;
            }
            expect_base = true;
        } else if is_emoji_modifier(scalar) || scalar == '\u{fe0f}' {
            if expect_base || !saw_base {
                return false;
            }
        } else if is_emoji_base(scalar) {
            if !expect_base && saw_base {
                return false;
            }
            saw_base = true;
            expect_base = false;
        } else {
            return false;
        }
    }
    saw_base && !expect_base
}

fn is_regional_indicator(value: char) -> bool {
    ('\u{1f1e6}'..='\u{1f1ff}').contains(&value)
}

fn is_emoji_modifier(value: char) -> bool {
    ('\u{1f3fb}'..='\u{1f3ff}').contains(&value)
}

fn is_emoji_base(value: char) -> bool {
    let scalar = u32::from(value);
    matches!(
        scalar,
        0x00a9
            | 0x00ae
            | 0x203c
            | 0x2049
            | 0x2122
            | 0x2139
            | 0x2194..=0x21ff
            | 0x2300..=0x23ff
            | 0x2460..=0x24ff
            | 0x25a0..=0x27bf
            | 0x2934..=0x2935
            | 0x2b00..=0x2bff
            | 0x3030
            | 0x303d
            | 0x3297
            | 0x3299
            | 0x1f000..=0x1f02f
            | 0x1f0a0..=0x1f0ff
            | 0x1f170..=0x1f251
            | 0x1f300..=0x1faff
    )
}

#[cfg(test)]
mod tests {
    use super::{
        APPLICATION_VERSION, ApplicationEvent, CONVERSATION_RESPONSE_MAGIC, DECODE_RESPONSE_MAGIC,
        DEVICE_CONTROL_DECODE_RESPONSE_MAGIC, DEVICE_CONTROL_MAGIC, ENCODE_REQUEST_MAGIC,
        ENCODE_RESPONSE_MAGIC, EventBody, KIND_MESSAGE_CREATE, KIND_MESSAGE_EDIT,
        KIND_REACTION_SET, decode_event, encode_event, operation,
    };
    use crate::{
        error::CryptoError,
        protocol::{push_frame, push_u16, push_u32, push_u64},
    };

    fn create_projection() -> Vec<u8> {
        let mut input = Vec::new();
        input.extend_from_slice(ENCODE_REQUEST_MAGIC);
        input.push(APPLICATION_VERSION);
        input.extend_from_slice(&[0x01; 16]);
        input.extend_from_slice(&[0x02; 32]);
        push_u16(&mut input, KIND_MESSAGE_CREATE);
        input.extend_from_slice(&[0x03; 16]);
        input.extend_from_slice(&[0x04; 16]);
        push_u64(&mut input, 1);
        push_u64(&mut input, 1_700_000_000_000);
        input.push(1);
        input.extend_from_slice(&[0x05; 16]);
        input.extend_from_slice(&[0x06; 16]);
        input.push(0);
        push_frame(&mut input, "hello".as_bytes()).unwrap();
        input.push(1);
        input.extend_from_slice(&[0x07; 16]);
        input.push(1);
        push_frame(&mut input, "quoted".as_bytes()).unwrap();
        input
    }

    #[test]
    fn golden_create_bytes_are_stable_and_round_trip() {
        let encoded = operation(1, &create_projection()).unwrap();
        assert_eq!(&encoded[..8], ENCODE_RESPONSE_MAGIC);
        let cbor = &encoded[8..];
        assert_eq!(
            hex(cbor),
            include_str!("../fixtures/application_v1_message_create.hex").trim()
        );
        let decoded = operation(2, cbor).unwrap();
        assert_eq!(&decoded[..8], DECODE_RESPONSE_MAGIC);
        assert_eq!(decoded[8], 0);
        assert_eq!(&decoded[9..], &create_projection()[8..]);
    }

    #[test]
    fn rejects_noncanonical_duplicate_and_invalid_mutations() {
        let encoded = operation(1, &create_projection()).unwrap();
        let cbor = &encoded[8..];
        let mut noncanonical_version = cbor.to_vec();
        noncanonical_version.splice(2..3, [0x18, 0x01]);
        assert_eq!(
            operation(2, &noncanonical_version),
            Err(CryptoError::MalformedInput)
        );

        let mut bad_edit = create_projection();
        bad_edit[57..59].copy_from_slice(&KIND_MESSAGE_EDIT.to_be_bytes());
        assert!(operation(1, &bad_edit).is_err());

        let mut bad_reaction = create_projection();
        bad_reaction[57..59].copy_from_slice(&KIND_REACTION_SET.to_be_bytes());
        assert!(operation(1, &bad_reaction).is_err());
    }

    #[test]
    fn retains_unknown_kind_and_unknown_version_without_body_interpretation() {
        let encoded = operation(1, &create_projection()).unwrap();
        let mut unknown_kind = encoded[8..].to_vec();
        let kind_offset = unknown_kind
            .windows(3)
            .position(|window| window == [0x03, 0x01, 0x04])
            .unwrap()
            + 1;
        unknown_kind[kind_offset] = 23;
        let decoded = operation(2, &unknown_kind).unwrap();
        assert_eq!(decoded[8], 1);

        let body_offset = unknown_kind
            .windows(3)
            .rposition(|window| window == [0xa5, 0x00, 0x50])
            .unwrap();
        let mut indefinite_unknown_body = unknown_kind.clone();
        indefinite_unknown_body[body_offset] = 0xbf;
        assert_eq!(
            operation(2, &indefinite_unknown_body),
            Err(CryptoError::MalformedInput)
        );

        let mut future = encoded[8..].to_vec();
        future[2] = 2;
        let decoded = operation(2, &future).unwrap();
        assert_eq!(&decoded[..8], DECODE_RESPONSE_MAGIC);
        assert_eq!(&decoded[8..], &[2, 2]);

        let minimal_future = operation(2, &[0xa1, 0x00, 0x02]).unwrap();
        assert_eq!(&minimal_future[8..], &[2, 2]);
    }

    #[test]
    fn generated_supported_events_round_trip_as_canonical_bytes() {
        let mut state = 0x4d59_5df4_d0f3_3173_u64;
        for index in 1_u64..=512 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            let event = ApplicationEvent {
                version: APPLICATION_VERSION,
                event_id: [u8::try_from(index & 0xff).unwrap(); 16],
                conversation_id: [u8::try_from((index + 1) & 0xff).unwrap(); 32],
                kind: KIND_MESSAGE_CREATE,
                sender_user_id: [u8::try_from((index + 2) & 0xff).unwrap(); 16],
                sender_device_id: [u8::try_from((index + 3) & 0xff).unwrap(); 16],
                sender_counter: state | 1,
                created_ms: state.rotate_left(11),
                references: vec![[u8::try_from((index + 4) & 0xff).unwrap(); 16]],
                body: EventBody::MessageCreate {
                    message_id: [u8::try_from((index + 5) & 0xff).unwrap(); 16],
                    content_type: 0,
                    text: format!("property-{index}-{}", state & 0xffff),
                    reply_to: Some([u8::try_from((index + 4) & 0xff).unwrap(); 16]),
                    quote_fallback: if index % 2 == 0 {
                        Some(format!("quote-{index}"))
                    } else {
                        None
                    },
                    attachments: Vec::new(),
                },
            };
            let encoded = encode_event(&event).unwrap();
            let (decoded, unsupported_version) = decode_event(&encoded).unwrap();
            assert_eq!(unsupported_version, None);
            assert_eq!(decoded, Some(event));
            assert_eq!(encode_event(decoded.as_ref().unwrap()).unwrap(), encoded);
        }
    }

    #[test]
    fn device_control_batches_are_bounded_canonical_and_tamper_evident() {
        let encoded = operation(1, &create_projection()).unwrap();
        let canonical = &encoded[8..];
        let mut control = Vec::new();
        control.extend_from_slice(DEVICE_CONTROL_MAGIC);
        control.push(1);
        control.push(3);
        control.extend_from_slice(&[1; 16]);
        control.extend_from_slice(&[2; 16]);
        control.extend_from_slice(&[3; 16]);
        control.extend_from_slice(&[4; 16]);
        control.extend_from_slice(&[5; 16]);
        push_u32(&mut control, 0);
        control.push(1);
        control.push(0);
        push_u16(&mut control, 1);
        push_frame(&mut control, canonical).unwrap();

        let decoded = operation(7, &control).unwrap();
        assert_eq!(&decoded[..8], DEVICE_CONTROL_DECODE_RESPONSE_MAGIC);
        assert_eq!(&decoded[8..], control);

        let mut tampered = control.clone();
        tampered.push(0);
        assert_eq!(operation(7, &tampered), Err(CryptoError::MalformedInput));

        let mut oversized = control;
        oversized[96] = 0;
        oversized[97] = 33;
        assert_eq!(operation(7, &oversized), Err(CryptoError::InputTooLarge));
    }

    #[test]
    fn conversation_ids_are_domain_separated_and_order_independent() {
        let mut forward = [0_u8; 32];
        forward[..16].fill(1);
        forward[16..].fill(2);
        let mut reverse = [0_u8; 32];
        reverse[..16].fill(2);
        reverse[16..].fill(1);
        let left = operation(4, &forward).unwrap();
        let right = operation(4, &reverse).unwrap();
        assert_eq!(&left[..8], CONVERSATION_RESPONSE_MAGIC);
        assert_eq!(left, right);
        let saved = operation(5, &[1; 16]).unwrap();
        assert_ne!(left[8..], saved[8..]);
    }

    fn hex(bytes: &[u8]) -> String {
        use std::fmt::Write as _;

        let mut output = String::with_capacity(bytes.len() * 2);
        for byte in bytes {
            write!(&mut output, "{byte:02x}").unwrap();
        }
        output
    }
}
