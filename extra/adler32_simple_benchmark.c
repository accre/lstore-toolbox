/* based on code from: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=193940 */

#include <sys/time.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>

#include <zlib.h>
#include "adler32_avutils.h"
#include "adler32_x64.h"

int main(int argc, char **argv) 
{
    long hash_speed_test = 32*1024*1024;
    const int reps = 100;
    //const int reps = 1;
    long i;
    struct rusage hash_start, hash_end;
    double elapsed;
    unsigned char *packed;

    if(argc>1)
    {
	hash_speed_test = strtol( argv[1], NULL, 10 );
	if(hash_speed_test < 1)
	{
		printf("Byte size requested for test not valid\n");
		return 1;
	}
    }
    printf("Running %i repetitions of %li bytes of data\n",reps,hash_speed_test);
    
	//packed = (unsigned char *)malloc(hash_speed_test);   //without extra
    packed = (unsigned char *)malloc(hash_speed_test + 1024); // with a little extra for testing


    for(i=0;i<hash_speed_test;i++) {
	//packed[i] = hash_speed_test & 0xFF;
	packed[i] = i & 0xFF;
    }

    if(argc <= 2 || (argv[2])[0] == 'z')
    {
	uLong adler = adler32(0L, Z_NULL, 0);
	getrusage(RUSAGE_SELF,&hash_start);
	for(i=0;i<reps;i++) {
	    //printf("before rep %li adler = %lx \n",i,adler);
	    adler = adler32(adler,packed, hash_speed_test);
	}
	getrusage(RUSAGE_SELF,&hash_end);
	elapsed = (hash_end.ru_utime.tv_sec - hash_start.ru_utime.tv_sec) + (hash_end.ru_utime.tv_usec - hash_start.ru_utime.tv_usec)/1.0e6;
	printf("Stock ZLib Adler Hash(%lx) of %d * %ld bytes in %.6gs, %.4g MB/s\n",
	       adler,reps, hash_speed_test,elapsed,reps * hash_speed_test / (1e6 *elapsed));
    }


	/* note the ubuntu packaged version seemed to have some sort of endianess flaw IIRC, using an adapted version from source */
    if(argc <= 2 || (argv[2])[0] == 'a')
    {
	uLong adler = av_adler32_avutils(1L, Z_NULL, 0);
	getrusage(RUSAGE_SELF,&hash_start);

	for(i=0;i<reps;i++) {
	    adler = av_adler32_avutils(adler,packed, hash_speed_test);
	}
	getrusage(RUSAGE_SELF,&hash_end);
	elapsed = (hash_end.ru_utime.tv_sec - hash_start.ru_utime.tv_sec) + (hash_end.ru_utime.tv_usec - hash_start.ru_utime.tv_usec)/1.0e6;
	printf("Avutils adler32(%lx) of %d * %ld bytes in %.6gs, %.4g MB/s \n",
	       adler,reps, hash_speed_test,elapsed,reps * hash_speed_test / (1e6 *elapsed));
    }


    if(argc <= 2 || (argv[2])[0] == 'x')
    {
	uLong adler = x64_adler32(1L, Z_NULL, 0);
	
	getrusage(RUSAGE_SELF,&hash_start);

	for(i=0;i<reps;i++) {
	    adler = x64_adler32(adler,packed, hash_speed_test);
	}
	getrusage(RUSAGE_SELF,&hash_end);
	elapsed = (hash_end.ru_utime.tv_sec - hash_start.ru_utime.tv_sec) + (hash_end.ru_utime.tv_usec - hash_start.ru_utime.tv_usec)/1.0e6;
	printf("x64 SSE2 asm adler32(%lx) of %d * %ld bytes in %.6gs, %.4g MB/s \n",
	       adler,reps, hash_speed_test,elapsed,reps * hash_speed_test / (1e6 *elapsed));
    }

    return 0;
}
