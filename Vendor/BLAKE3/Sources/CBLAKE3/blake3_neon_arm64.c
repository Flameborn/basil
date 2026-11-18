/* Basil: compiles the upstream NEON implementation (blake3_neon.inc, unmodified
   blake3_neon.c from BLAKE3 1.8.7) only on arm64, so x86_64 builds still work
   with the portable code. */
#if defined(__aarch64__)
#include "blake3_neon.inc"
#endif
