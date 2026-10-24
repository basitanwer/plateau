#ifndef CSMC_H
#define CSMC_H
#include <stdint.h>

// Opens a connection to AppleSMC. Returns 0 on success.
int smc_open(void);
void smc_close(void);

// Reads a key. Returns 0 on success; fills bytes (up to 32), size and 4-char type.
int smc_read(const char *key, uint8_t *bytes, uint32_t *size, char type[5]);

// Writes a key (size must match the key's size). Requires root. Returns 0 on success.
int smc_write(const char *key, const uint8_t *bytes, uint32_t size);

#endif
