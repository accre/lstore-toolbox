/* from: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=193940 */
/* C program, compile with gcc t.C -lz -llzo22 -lavutil */

#include <sys/time.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>

#include <zlib.h>
#include "adler32_avutils.h"
#include "adler32_x64.h"

#include <time.h>
#include <stdlib.h>



int main(int argc, char **argv) 
{
    long max_len = 32 * 1024;
    const int reps = 4;
    long i,j;
    long len = 1;

    unsigned char * packed, * zeros, * ones, * max, * mod256, * randA, * randB;
    unsigned char * buffers[6];
    char * buffer_names[] = {"zeros","ones","max","mod256","randA","randB"};
    
    int alignment_offset = 3;	

    if(argc>1)
    {
	max_len = strtol( argv[1], NULL, 10 );
	if(max_len < 1)
	{
		printf("Byte size requested for test not valid\n");
		return 1;
	}
	    if(argc>2)
	    { /* set the initial length */
		len = strtol( argv[2], NULL, 10 );
		if(len < 1)
		{
			printf("Byte size requested for test not valid\n");
			return 1;
		}
	    }
    }


	//srand(time(NULL));
	//int r = rand();
	//RAND_MAX

    printf("Running from %li upto %li bytes of data\n",len,max_len);



    zeros = (unsigned char *)malloc(max_len + alignment_offset);
    ones = (unsigned char *)malloc(max_len + alignment_offset);
    max = (unsigned char *)malloc(max_len + alignment_offset);
    mod256 = (unsigned char *)malloc(max_len + alignment_offset);
    randA = (unsigned char *)malloc(max_len + alignment_offset);
    randB = (unsigned char *)malloc(max_len + alignment_offset);

    buffers[0] = zeros;
    buffers[1] = ones;
    buffers[2] = max;
    buffers[3] = mod256;
    buffers[4] = randA;
    buffers[5] = randB;

    for(i=0;i<max_len;i++) {
	zeros[i] = 0 & 0xFF;
	ones[i] = 1 & 0xFF;
	max[i] = 255 & 0xFF;
	mod256[i] = i & 0xFF;
	randA[i] = ((i%71) + 42)*((i%111) + 7) & 0xFF;
	randB[i] = (255 - (i % 256)) & 0xFF; //TODO
    }


    while(len < max_len)
    {
	for(j=0; j<6; j++)
	{
		uLong adler = adler32(0L, Z_NULL, 0);
		uLong ref = x64_adler32(1L, Z_NULL, 0);

		packed = buffers[j] + alignment_offset;

		for(i=0;i<reps;i++) {
			ref = adler32(ref, packed, len);
			adler = x64_adler32(adler,packed, len);
		
			if(ref == adler)
			{
				printf("len: %16lu   rep: %4li   buf: %10s  adler: %08lx   ref: %08lx   MATCH!\n",len,i,buffer_names[j],adler,ref);
			}else{
				printf("len: %16lu   rep: %4li   buf: %10s  adler: %08lx   ref: %08lx   MISMATCH!!!!!\n",len,i,buffer_names[j],adler,ref);
				printf("FAILURE, aborting\n");
				return 1;
			}
		}
	}
	len += 1 + (len / 17);  // increase test length exponentially 
    }

    printf("DONE SUCCESS!\n");

    return 0;
}
