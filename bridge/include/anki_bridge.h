#ifndef ANKI_BRIDGE_H
#define ANKI_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Create a new Anki backend instance.
 *
 * @param init_data  Serialized anki.backend.BackendInit protobuf (may be NULL for defaults).
 * @param init_len   Length of init_data in bytes.
 * @param out_ptr    Receives an opaque backend handle.
 * @return 0 on success, -1 on error.
 */
int anki_open_backend(const uint8_t *init_data, size_t init_len, int64_t *out_ptr);

/**
 * Execute a backend RPC method.
 *
 * @param backend_ptr  Handle from anki_open_backend.
 * @param service      Service index (see generated AnkiRPC.swift).
 * @param method       Method index within the service.
 * @param input_data   Serialized protobuf request (may be NULL when input_len is 0).
 * @param input_len    Length of input_data.
 * @param out_data     Receives a heap buffer with the response; free with anki_free_response.
 * @param out_len      Receives the response length.
 * @return 0 = success (response protobuf), 1 = backend error (BackendError protobuf), -1 = FFI error.
 */
int anki_run_method(
    int64_t backend_ptr,
    uint32_t service,
    uint32_t method,
    const uint8_t *input_data,
    size_t input_len,
    uint8_t **out_data,
    size_t *out_len
);

/** Free a buffer returned by anki_run_method (NULL is allowed). */
void anki_free_response(uint8_t *data, size_t len);

/** Close the backend. The handle is invalid afterwards. */
void anki_close_backend(int64_t backend_ptr);

/** Static NUL-terminated bridge version string. */
const char *anki_bridge_version(void);

#ifdef __cplusplus
}
#endif

#endif /* ANKI_BRIDGE_H */
