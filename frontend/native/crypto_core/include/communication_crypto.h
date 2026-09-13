#ifndef COMMUNICATION_CRYPTO_H
#define COMMUNICATION_CRYPTO_H

#include <stdint.h>

/* The pairwise operation mux carries padded envelopes and authenticated
 * device state, so it has a larger frozen bound than the other v1 entrypoints. */
#define CP_CRYPTO_V1_PAIRWISE_MAX_IO_BYTES UINT32_C(2097152)
#define CP_CRYPTO_V1_PAIRWISE_OP_INSPECT_PUBLIC_HEADER UINT32_C(17)
#define CP_CRYPTO_V1_ENVELOPE_KIND_REGULAR UINT8_C(0)
#define CP_CRYPTO_V1_ENVELOPE_KIND_INITIAL UINT8_C(1)

#ifdef __cplusplus
extern "C" {
#endif

#define CP_CRYPTO_V1_ABI_VERSION UINT32_C(1)
#define CP_CRYPTO_V1_CAPABILITIES_SIZE UINT32_C(32)

typedef enum cp_crypto_status_v1 {
  CP_CRYPTO_OK = 0,
  CP_CRYPTO_INVALID_ARGUMENT = 1,
  CP_CRYPTO_INPUT_TOO_LARGE = 2,
  CP_CRYPTO_OUTPUT_TOO_SMALL = 3,
  CP_CRYPTO_MALFORMED_INPUT = 4,
  CP_CRYPTO_INVALID_HANDLE = 5,
  CP_CRYPTO_WRONG_HANDLE_TYPE = 6,
  CP_CRYPTO_AUTHENTICATION_FAILED = 7,
  CP_CRYPTO_UNSUPPORTED_VERSION = 8,
  CP_CRYPTO_UNSUPPORTED_OPERATION = 9,
  CP_CRYPTO_RESOURCE_EXHAUSTED = 10,
  CP_CRYPTO_ENTROPY_UNAVAILABLE = 11,
  CP_CRYPTO_STATE_VIOLATION = 12,
  CP_CRYPTO_INTERNAL_FAILURE = 13,
  CP_CRYPTO_PANIC_CONTAINED = 14
} cp_crypto_status_v1;

typedef struct cp_crypto_capabilities_v1 {
  uint32_t struct_size;
  uint32_t abi_version;
  uint64_t feature_bits;
  uint32_t max_input_bytes;
  uint32_t max_cbor_depth;
  uint32_t max_cbor_items;
  uint32_t reserved;
} cp_crypto_capabilities_v1;

uint32_t cp_crypto_v1_abi_version(void);
int32_t cp_crypto_v1_capabilities(
    cp_crypto_capabilities_v1* output,
    uintptr_t output_len);
int32_t cp_crypto_v1_self_test(void);

int32_t cp_crypto_v1_prepare_device(
    const uint8_t* user_id,
    uintptr_t user_id_len,
    uint8_t* output,
    uintptr_t output_len,
    uintptr_t* written);
int32_t cp_crypto_v1_prepare_first_identity(
    const uint8_t* user_id,
    uintptr_t user_id_len,
    uint8_t* output,
    uintptr_t output_len,
    uintptr_t* written);
int32_t cp_crypto_v1_restore_identity(
    const uint8_t* user_id,
    uintptr_t user_id_len,
    const uint8_t* recovery_secret,
    uintptr_t recovery_secret_len,
    const uint8_t* backup,
    uintptr_t backup_len,
    uint8_t* output,
    uintptr_t output_len,
    uintptr_t* written);
int32_t cp_crypto_v1_sanitize_identity(
    const uint8_t* identity_package,
    uintptr_t identity_package_len,
    uint8_t* output,
    uintptr_t output_len,
    uintptr_t* written);
int32_t cp_crypto_v1_rotate_recovery_secret(
    const uint8_t* identity_package,
    uintptr_t identity_package_len,
    uint8_t* output,
    uintptr_t output_len,
    uintptr_t* written);
int32_t cp_crypto_v1_cross_sign_device(
    const uint8_t* device_package,
    uintptr_t device_package_len,
    const uint8_t* identity_package,
    uintptr_t identity_package_len,
    const uint8_t* device_id,
    uintptr_t device_id_len,
    uint32_t bundle_version,
    uint8_t* output,
    uintptr_t output_len,
    uintptr_t* written);
int32_t cp_crypto_v1_create_device_log_record(
    const uint8_t* identity_package,
    uintptr_t identity_package_len,
    const uint8_t* user_id,
    uintptr_t user_id_len,
    uint64_t sequence,
    const uint8_t* previous_hash,
    uintptr_t previous_hash_len,
    const uint8_t* canonical_live_set,
    uintptr_t canonical_live_set_len,
    uint32_t identity_version,
    uint32_t coarse_unix_day,
    uint8_t* output,
    uintptr_t output_len,
    uintptr_t* written);
int32_t cp_crypto_v1_inspect_device_log_record(
    const uint8_t* identity_package,
    uintptr_t identity_package_len,
    const uint8_t* user_id,
    uintptr_t user_id_len,
    const uint8_t* record,
    uintptr_t record_len,
    uint8_t* output,
    uintptr_t output_len,
    uintptr_t* written);
int32_t cp_crypto_v1_identity_operation(
    uint32_t operation,
    const uint8_t* input,
    uintptr_t input_len,
    uint8_t* output,
    uintptr_t output_len,
    uintptr_t* written);
int32_t cp_crypto_v1_pairwise_operation(
    uint32_t operation,
    const uint8_t* input,
    uintptr_t input_len,
    uint8_t* output,
    uintptr_t output_len,
    uintptr_t* written);
int32_t cp_crypto_v1_application_operation(
    uint32_t operation,
    const uint8_t* input,
    uintptr_t input_len,
    uint8_t* output,
    uintptr_t output_len,
    uintptr_t* written);
int32_t cp_crypto_v1_attachment_operation(
    uint32_t operation,
    const uint8_t* input,
    uintptr_t input_len,
    uint8_t* output,
    uintptr_t output_len,
    uintptr_t* written);
int32_t cp_crypto_v1_attest_peer_master(
    const uint8_t* identity_package,
    uintptr_t identity_package_len,
    const uint8_t* peer_user_id,
    uintptr_t peer_user_id_len,
    const uint8_t* peer_master_public,
    uintptr_t peer_master_public_len,
    uint8_t* output,
    uintptr_t output_len,
    uintptr_t* written);

#ifdef __cplusplus
}
#endif

#endif /* COMMUNICATION_CRYPTO_H */
