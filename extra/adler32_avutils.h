

#ifndef ADLER32_AVUTILS_H
#define ADLER32_AVUTILS_H

#include <stdint.h>

unsigned long av_adler32_avutils(unsigned long adler, const uint8_t * buf, unsigned int len);

#endif // ADLER32_AVUTILS_H
