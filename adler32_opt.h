

#ifndef ADLER32_OPT_H
#define ADLER32_OPT_H

#include <stdint.h>

#if defined(__x86_64__) || defined(_M_X64)
    #include <zlib.h>
    unsigned long x64_adler32(unsigned long adler, const uint8_t * buf, unsigned int len);
    #define opt_adler32 x64_adler32
    #define opt_adler32_combine adler32_combine
#else
    #include <zlib.h>
    #define opt_adler32 adler32
    #define opt_adler32_combine adler32_combine
#endif

#endif // ADLER32_OPT_H
