/*
 * 
 * x64+SSE2 assembly implementation for computing Alder32 checksums
 * 
 * Matthew Heller <matthew.f.heller@accre.vanderbilt.edu>
 * 
 */

.global x64_adler32

.text
/*
 * C signature:
 *    unsigned long x64_adler32(unsigned long adler, const uint8_t * buf, unsigned int len);
 * 
 * ABI: http://www.x86-64.org/documentation/abi.pdf
 * 
 * callee preserves %rbx,%rsp,%rbp,%r12-15 
 *    (other regular, float, & SSE registers are fair game)
 * 
 * First 6 int/ptr args are passed in %rdi,%rsi, %rdx, %rcx, %r8 and %r9 (in that order)
 *   (involving floating point args, SSE vector args, etc changes the rules) 
 *
 * Return value via %rax for int/ptr
 */

#define	ADLER_ARG		rdi
#define BUF_ARG			rsi
#define LEN_ARG			rdx

/* DO NOT CHANGE LEN_ARG or SUM_H from rdx and rax unless you change the multiply near the end of the code ! */

#define SUM_H			ADLER_ARG
#define SUM_L			rax
#define PRE_SIMD_LEN		r9

#define OUTER_COUNT		r8

#define MOD_BASE		65521
#define INIT_ADLER		0x00000001
#define ALIGNMENT		16
#define ALIGN_MASK		0x0f
#define WIDTH			8
#define	WIDTH_LOG2		3

#define ZERO_VEC		xmm11

#define H_ACUM_VEC32b_A		xmm15
#define H_ACUM_VEC32b_B		xmm14
#define L_ACUM_VEC32b_A		xmm13
#define L_ACUM_VEC32b_B		xmm12

#define H_ADJUST_A		xmm10
#define H_ADJUST_B		xmm9



.macro Adler_Modulo_SIMD_64b_init_consts prime primeMinus1 mask tmpA1 tmpA2
	/* Generate our constants since 128bit intermediates are not an option and the only alternative is loading from memory */

	# create a vector of adler mod primes, 65521 or 0xFFF1
	pcmpeqd         \prime,\prime     # all 1's bitwise (0xfff...)
	pcmpeqd         \primeMinus1,\primeMinus1     # all 1's bitwise (0xfff...)	
	pcmpeqd         \tmpA1,\tmpA1     # all 1's bitwise (0xfff...)	
	pcmpeqd         \tmpA2,\tmpA2     # all 1's bitwise (0xfff...)
	
	psllq		$(64-16),\prime	#
	psrlq		$(64-16),\prime	# Zero the first 16 bits leaving 0x0000FFFF	
	movdqa		\prime,\primeMinus1	# copy ^^^

	psrlq		$(64-3),\tmpA1	
	psllq		$1,\tmpA1	# all 14's  0x0000000e x4
	psubq		\tmpA1,\prime	# all 65521, 65535-14
	
	psrlq		$(64-4),\tmpA2	# all 15's 0x0000000f x4
	psubq		\tmpA2,\primeMinus1	# all 65520, 65535-15

	# create our bit masks
	pcmpeqd		\mask,\mask	# all 1's bitwise (0xfff...)
					## There is no SIMD NOT, NAND, or XNOR instuction so we use this "compare and mask" op	
	psllq		$(64-16),\mask
	psrlq		$(64-16),\mask	# \mask = [  0x0000FFFF, 0x0000FFFF, ... ]
.endm

.macro Adler_Modulo_SIMD_32b_init_consts prime primeMinus1 mask tmpA1 tmpA2
	/* Generate our constants since 128bit intermediates are not an option and the only alternative is loading from memory */

	# create a vector of adler mod primes, 65521 or 0xFFF1
	pcmpeqd         \prime,\prime     # all 1's bitwise (0xfff...)
	pcmpeqd         \primeMinus1,\primeMinus1     # all 1's bitwise (0xfff...)	
	pcmpeqd         \tmpA1,\tmpA1     # all 1's bitwise (0xfff...)	
	pcmpeqd         \tmpA2,\tmpA2     # all 1's bitwise (0xfff...)
	
	pslld		$16,\prime	#
	psrld		$16,\prime	# Zero the first 16 bits leaving 0x0000FFFF	
	movdqa		\prime,\primeMinus1	# copy ^^^

	psrld		$29,\tmpA1	
	pslld		$1,\tmpA1	# all 14's  0x0000000e x4
	psubd		\tmpA1,\prime	# all 65521, 65535-14
	
	psrld		$28,\tmpA2	# all 15's 0x0000000f x4
	psubd		\tmpA2,\primeMinus1	# all 65520, 65535-15

	# create our bit masks
	pcmpeqd		\mask,\mask	# all 1's bitwise (0xfff...)
					## There is no SIMD NOT, NAND, or XNOR instuction so we use this "compare and mask" op	
	pslld		$16,\mask
	psrld		$16,\mask	# \mask = [  0x0000FFFF, 0x0000FFFF, ... ]
.endm

.macro Adler_Modulo_SIMD_64b_one_div_pass vecA prime primeMinus1 mask tmpA1 tmpA2
	/* 1x "divide by" pass */ 
	/* conditionals in SIMD is a pain so keep this branchless */
	movdqa	\vecA,\tmpA1	#A	
	pand	\mask,\vecA	#A only the lower 16bits of each element
	psrlq	$16,\tmpA1		#A 1 per 65536, keep only the upper 48 bits of each element
	movdqa 	\tmpA1,\tmpA2		#A
	psllq	$4,\tmpA2		#A 16 per 65536
	paddq	\tmpA2,\vecA	#A 
	psubq	\tmpA1,\vecA	#A +16 per 65536 - 1 per 65536 = 15 per 65536
.endm

.macro Adler_Modulo_SIMD_Twin_32b_one_div_pass vecA vecB prime primeMinus1 mask tmpA1 tmpA2 tmpB1 tmpB2
	/* 1x "divide by" pass */ 
	/* work on A and B vector simultaneously, interleaving marked in comment
	/* conditionals in SIMD is a pain so keep this branchless */
	movdqa	\vecA,\tmpA1	#A	
	movdqa	\vecB,\tmpB1	#B	
	pand	\mask,\vecA	#A only the lower 16bits of each element
	pand	\mask,\vecB	#B only the lower 16bits of each element
	psrld	$16,\tmpA1		#A 1 per 65536, keep only the upper 16 bits of each element
	psrld	$16,\tmpB1		#B 1 per 65536, keep only the upper 16 bits of each element
	/* note we could just subtract tmpX1 now and avoid the tmpX2 copy, however this is tested to be slower
	 * depsite reducing instructions and registers, probably because of increased latency from register dependencies */
	movdqa 	\tmpA1,\tmpA2		#A
	movdqa 	\tmpB1,\tmpB2		#B
	pslld	$4,\tmpA2		#A 16 per 65536
	pslld	$4,\tmpB2		#B 16 per 65536
	psubd	\tmpA1,\vecA	#A +16 per 65536 - 1 per 65536 = 15 per 65536
	psubd	\tmpB1,\vecB	#B +16 per 65536 - 1 per 65536 = 15 per 65536
	paddd	\tmpA2,\vecA	#A 
	paddd	\tmpB2,\vecB	#B 
.endm

.macro Adler_Modulo_SIMD_64b_one_sub_pass vecA prime primeMinus1 mask tmpA1 tmpA2
	movdqa	\vecA,\tmpA1	#A
	pcmpgtd	\primeMinus1,\tmpA1	#A compare to Adler prime - 1, 65520, and make mask all 1's if greater-than, note this is a 32bit but it behaves correctly for 64bit in this particular situation
					### Also this is a signed op but the "sign bit" won't be set on our unsigned #s so we are safe
	pand	\prime,\tmpA1		# prime vec & tmp-mask -> tmp-mask
	psubq	\tmpA1,\vecA		#A subtract the adler prime from the greater than prime values
.endm

.macro Adler_Modulo_SIMD_Twin_32b_one_sub_pass vecA vecB prime primeMinus1 mask tmpA1 tmpA2 tmpB1 tmpB2
	/* work on A and B vector simultaneously, interleaving marked in comment
	 * 1x "subtract from" pass */
	movdqa	\vecA,\tmpA1	#A
	movdqa	\vecB,\tmpB1	#B
	pcmpgtd	\primeMinus1,\tmpA1	#A compare to Adler prime - 1, 65520, and make mask all 1's if greater-than
					### This is a signed op but the "sign bit" won't be set on our unsigned #s so we are safe
	pcmpgtd	\primeMinus1,\tmpB1	#B compare to Adler prime - 1, 65520, and make mask all 1's if greater-than
	pand	\prime,\tmpA1		#A prime vec & tmp-mask -> tmp-mask
	pand	\prime,\tmpB1		#B prime vec & tmp-mask -> tmp-mask
	psubd	\tmpA1,\vecA		#A subtract the adler prime from the greater than prime values
	psubd	\tmpB1,\vecB		#B subtract the adler prime from the greater than prime values
.endm

/* Keep this to demonstrate usage and a complete solution but because our inputs are constrained we are a more efficient calling the stages directly */
/* Also each macro instance copies code, so beware of inline bloat */
.macro Adler_Modulo_SIMD_Twin_64b vecA vecB prime primeMinus1 mask tmpA1 tmpA2 tmpB1 tmpB2
	/* initalization + 5x div pass + 1x sub pass, each pass moves the value closer to modulo */
	/* This combination of passes should be sufficient, less could be used in some scenarios*/

	/* This requires many passes if the input is not bounded below 2^64, the efficency of using lightweight ops is probably lost and an algorithm using
	   reciprical multiplication may be faster: x % MODBASE = x - floor(x * 1/MODBASE) * MODBASE   */

	/* modulo 65521 both the adler sums */
	/* Do this without division or multiplication by exploiting that arithmatic 
	 * performed modulo 2^16 (65536) is simple in binary and our modulo base, 65521 
	 * is only 15 less. So basically for every time modulo 2^16 arithmatic would
	 * wrap/overflow we need to add back 15. 
	 *
	 * (another approach would be to use reciprocal multiplication to avoid division and replace it with somewhat 
	 * fast multiplication, but for these particular numbers I like the above approach)
	 */
	
	/* each div pass moves us 2^11 closer to the answer but does not necessarily get us all the way to the answer, 
	 * the sub pass does cover the edge cases and give us the correct result if the input is under 2*MOD_BASE */
	Adler_Modulo_SIMD_64b_init_consts		\prime, \primeMinus1, \mask, \tmpA1, \tmpA2
	Adler_Modulo_SIMD_64b_one_div_pass		\vecA, \prime, \primeMinus1, \mask, \tmpA1, \tmpA2
	Adler_Modulo_SIMD_64b_one_div_pass		\vecA, \prime, \primeMinus1, \mask, \tmpA1, \tmpA2
	Adler_Modulo_SIMD_64b_one_div_pass		\vecA, \prime, \primeMinus1, \mask, \tmpA1, \tmpA2
	Adler_Modulo_SIMD_64b_one_div_pass		\vecA, \prime, \primeMinus1, \mask, \tmpA1, \tmpA2
	Adler_Modulo_SIMD_64b_one_div_pass		\vecA, \prime, \primeMinus1, \mask, \tmpA1, \tmpA2
	Adler_Modulo_SIMD_64b_one_sub_pass		\vecA, \prime, \primeMinus1, \mask, \tmpA1, \tmpA2
.endm

/* Keep this to demonstrate usage and a complete solution but because our inputs are constrained we are a more efficient calling the stages directly */
/* Also each macro instance copies code, so beware of inline bloat */
# all arguments must be SSE registers, xmm*
.macro Adler_Modulo_SIMD_Twin_32b vecA vecB prime primeMinus1 mask tmpA1 tmpA2 tmpB1 tmpB2
	/* initalization + 2x div pass + 1x sub pass, each pass moves the value closer to modulo */
	/* This combination of passes should be sufficient, less could be used in some scenarios*/

	/* modulo 65521 both the adler sums */
	/* Do this without division or multiplication by exploiting that arithmatic 
	 * performed modulo 2^16 (65536) is simple in binary and our modulo base, 65521 
	 * is only 15 less. So basically for every time modulo 2^16 arithmatic would
	 * wrap/overflow we need to add back 15. 
	 *
	 * (another approach would be to use reciprocal multiplication to avoid division and replace it with somewhat 
	 * fast multiplication, but for these particular numbers I like the above approach)
	 */
	
	/* each div pass moves us 2^11 closer to the answer but does not necessarily get us all the way to the answer, 
	 * the sub pass does cover the edge cases and give us the correct result if the input is under 2*MOD_BASE */
	Adler_Modulo_SIMD_32b_init_consts		\prime, \primeMinus1, \mask, \tmpA1, \tmpA2
	Adler_Modulo_SIMD_Twin_32b_one_div_pass		\vecA, \vecB, \prime, \primeMinus1, \mask, \tmpA1, \tmpA2, \tmpB1, \tmpB2
	Adler_Modulo_SIMD_Twin_32b_one_div_pass		\vecA, \vecB, \prime, \primeMinus1, \mask, \tmpA1, \tmpA2, \tmpB1, \tmpB2
	Adler_Modulo_SIMD_Twin_32b_one_sub_pass		\vecA, \vecB, \prime, \primeMinus1, \mask, \tmpA1, \tmpA2, \tmpB1, \tmpB2
.endm


.macro SIMD_8b_to_16b_interleaved inLower0, upper0, inLower1, upper1, inLower2, upper2, zeros
		movdqa		\inLower0,\upper0		# second copy of the 16 bytes of input
		movdqa		\inLower1,\upper1		# second copy of the 16 bytes of input
		movdqa		\inLower2,\upper2		# second copy of the 16 bytes of input
		punpcklbw	\zeros,\inLower0		# interleave the lower0 half (the first bytes loaded from the buffer0) w/ 0's to create 8x16bit ints 
		punpckhbw	\zeros,\upper0		# interleave the upper0 half (8x8bit ints) with zeros to create 8x16bit ints
		punpcklbw	\zeros,\inLower1		# interleave the lower0 half (the first bytes loaded from the buffer0) w/ 0's to create 8x16bit ints 
		punpckhbw	\zeros,\upper1		# interleave the upper0 half (8x8bit ints) with zeros to create 8x16bit ints
		punpcklbw	\zeros,\inLower2		# interleave the lower0 half (the first bytes loaded from the buffer0) w/ 0's to create 8x16bit ints 
		punpckhbw	\zeros,\upper2		# interleave the upper0 half (8x8bit ints) with zeros to create 8x16bit ints
.endm

.macro SIMD_8b_to_16b inLower, upper, zeros
		movdqa		\inLower,\upper		# second copy of the 16 bytes of input
		punpcklbw	\zeros,\inLower		# interleave the lower half (the first bytes loaded from the buffer) w/ 0's to create 8x16bit ints 
		punpckhbw	\zeros,\upper		# interleave the upper half (8x8bit ints) with zeros to create 8x16bit ints
.endm

# same result as above but without needing the zero vector but more instructions
.macro SIMD_8b_to_16b_special inLower, upper
		movdqa		\inLower,\upper		# second copy of the 16 bytes of input
		punpcklbw	\inLower,\inLower	# interleave the lower half with itself, contains two copies of every lower byte 
		punpckhbw	\upper,\upper		# interleave the upper half with itself, contains two copies of every upper byte 
		psllw		$8,\inLower		# shift and unshift to clear the upper bits
		psllw		$8,\upper
		psrlw		$8,\inLower		# shift and unshift to clear the upper bits
		psrlw		$8,\upper
.endm

.macro SIMD_16b_to_32b	inLower, upper, zeros
		movdqa		\inLower,\upper		# second copy of the 8x16bit input	
		punpcklwd	\zeros,\inLower		# interleave the lower half (the first words loaded from the buffer) w/ 0's to create 4x32bit ints 
		punpckhwd	\zeros,\upper		# interleave (in 2byte groups) the upper half (4x16bit ints) with zeros to create 4x32bit ints
.endm


/******** Inner Loop with 16bit accumulator vectors ********/
/***********************************************************/
/* With the L & H accumulators both starting off zeroed we can do...
 * ...257 vector additions with SUM-L before overflowing
 *   0xff is the max value added, 0xffff is the max each element of the accumulator vector can hold, 0xffff/0xff = 0x101
 *   in decimal: 65535 / 255 = 257
 *
 * ...22 vector additions before we overflow the SUM-H accumulator
 *    255 * (1 + 2 + 3 + ... + n) < 65535
 *    255 * n(n+1)/2 < 65535
 *    n(n+1) < 65535 * 2 / 255
 *    n^2 + n - 514 < 0
 *    solve with quadratic formula (-b +/- sqrt(b^2 - 4ac))/a2
 *    -23.17_ < n < 22.17_
 *
 *    The inner loop currently processes 4 bytes of input per vector element in series per loop at 8 input bytes wide each (in parallel) x2 sets of vectors
 *    So we can run the loop 5 floor(22/4) times and process 5 * 4 * 8 * 2 = 320 bytes before needing to break to avoid overflow 
 */

#define MAX_OUTER_LOOPS 100
#define MAX_INNER_LOOPS 5       /* was 11 */
#define BYTES_PER_INNER_LOOP	64	/* was 16 */
#define BYTES_PER_INNER_LOG2	6	/* was 4 */
#define INNER_MASK		0x3f	/* was 0x0f */
#define INNER_MASK_INV		0xffffffffffffffc0
#define L_0	xmm0
#define L_1	xmm1
#define H_0	xmm2
#define H_1	xmm3


/* Conditions: 
/* This function reserves the right to use xmm0-11 !!! 
 * OutAcc_L_A and OutAcc_L_B values must be <2^28     (2^32 - (bytes-per-loop / SIMD-width))
 */

.macro	Inner_Loop_prechecked_init Buf, Len, OutAcc_L_A, OutAcc_L_B, OutAcc_H_A, OutAcc_H_B, uniq=42
	subq	$(MAX_OUTER_LOOPS * MAX_INNER_LOOPS * BYTES_PER_INNER_LOOP),%LEN_ARG	# update length in advance to skip some branches since we already know the bytes are available
.endm

.macro	Inner_Loop_head_prechecked Buf, Len, OutAcc_L_A, OutAcc_L_B, OutAcc_H_A, OutAcc_H_B, uniq=42
	movq	$MAX_INNER_LOOPS,%rcx		# init loop counter	
.endm

.macro	Inner_Loop_head_regular Buf, Len, OutAcc_L_A, OutAcc_L_B, OutAcc_H_A, OutAcc_H_B, uniq=42
	movq	$MAX_INNER_LOOPS,%rcx		# init loop counter	
	subq	$(MAX_INNER_LOOPS*BYTES_PER_INNER_LOOP),%LEN_ARG	# update in advance length and also check that we won't run out of bytes to process
	jae	.enough_bytes_remain_\uniq
		/* our subtraction made LEN_ARG wrap, so len is >=16 (tested earlier in the code)
		 * but less that MAX_INNER_LOOPS * BYTES_PER_INNER_LOOP   */
		addq	$(MAX_INNER_LOOPS*BYTES_PER_INNER_LOOP),%LEN_ARG	# undo the change to the length counter
		movq	%LEN_ARG,%rcx
		shrq	$BYTES_PER_INNER_LOG2,%rcx		# effectively integer divide len by our chunk size to figure out how many loops we are allowed to do
		andq	$INNER_MASK,%LEN_ARG	# we are going to process all the bytes except any trailing bytes < chunk size, adjust len accordingly		
.endm

# uses a 16byte load so total buffer length must be 16bytes or larger otherwise this could segfault
.macro	UpTo16Unaligned Buf, Len, ToRead, OutAcc_L_A, OutAcc_L_B, OutAcc_H_A, OutAcc_H_B, uniq=42
		movdqu		(%BUF_ARG),%xmm4        # load 16 bytes out of the buffer
		psrldq		$(16-T)%xmm4
.endm

.macro	Inner_Loop_body Buf, Len, OutAcc_L_A, OutAcc_L_B, OutAcc_H_A, OutAcc_H_B, uniq=42
.enough_bytes_remain_\uniq: 
	pslld	$(BYTES_PER_INNER_LOG2 - WIDTH_LOG2),\OutAcc_L_A	# shift the outside L vecs and shift them back to there orig position before we hand them back
	pslld	$(BYTES_PER_INNER_LOG2 - WIDTH_LOG2),\OutAcc_L_B	### this will help us keep the outside H vec updated efficiently   (multiply by bytes/loop * 1/width)

	pxor	%L_0,%L_0	# zero accumulators
	pxor	%L_1,%L_1
	pxor	%H_0,%H_0
	pxor	%H_1,%H_1
#	pxor	%ZERO_VEC,%ZERO_VEC	# %xmm11  # as long as this is done in the outer loop this can be disabled
.align 32 # instruction alignment, make sure the machine code is nicely aligned since this is an inner loop label
.loop_inner_\uniq:
		movdqa		(%BUF_ARG),%xmm4	# load 16 bytes out of the buffer
		movdqa		16(%BUF_ARG),%xmm5	# load 16 bytes out of the buffer
		movdqa		32(%BUF_ARG),%xmm6	# load 16 bytes out of the buffer
		movdqa		48(%BUF_ARG),%xmm7	# load 16 bytes out of the buffer
		addq		$BYTES_PER_INNER_LOOP,%BUF_ARG		# update buffer pointer
		PREFETCHNTA	768(%BUF_ARG)		/* test of prefetch */

		paddd		\OutAcc_L_A,\OutAcc_H_A		# keep the outer H vec updated
		paddd		\OutAcc_L_B,\OutAcc_H_B		### L is shifted to match the bytes / loop / element

		# SIMD_8b_to_16b inLower, upper, zeros	
#		SIMD_8b_to_16b	%xmm4,%xmm8,%ZERO_VEC
#		SIMD_8b_to_16b	%xmm5,%xmm9,%ZERO_VEC
#		SIMD_8b_to_16b	%xmm6,%xmm10,%ZERO_VEC

		SIMD_8b_to_16b_interleaved	%xmm4,%xmm8,%xmm5,%xmm9,%xmm6,%xmm10,%ZERO_VEC

#define PERF_1 1
#if PERF_1
		SIMD_8b_to_16b_special	%xmm7,%ZERO_VEC		# steal the zero vec, fix it later
		paddw           %xmm4,%L_0
#else
		paddw		%xmm4,%L_0 	# run this before the last 8->16bit unpack because we need to free one register
		SIMD_8b_to_16b	%xmm7,%xmm4,%ZERO_VEC
#endif
		paddw		%xmm8,%L_1
	
		paddw		%L_0,%H_0
		paddw		%L_1,%H_1

		paddw		%xmm5,%L_0
		paddw		%xmm9,%L_1

		paddw		%L_0,%H_0
		paddw		%L_1,%H_1

		paddw		%xmm6,%L_0
		paddw		%xmm10,%L_1

		paddw		%L_0,%H_0
		paddw		%L_1,%H_1
		
		paddw		%xmm7,%L_0
#if PERF_1	/* borrow the zero vec */
		paddw		%ZERO_VEC,%L_1
		pxor		%ZERO_VEC,%ZERO_VEC
#else
		paddw		%xmm4,%L_1
#endif
		paddw		%L_0,%H_0
		paddw		%L_1,%H_1

		dec		%rcx		# I would expect doing this earlier would cut down on latency however it appears that the processor does some sort of optimization when the 'dec' and the 'jnz' are adjacent
		jnz		.loop_inner_\uniq

	psrld	$(BYTES_PER_INNER_LOG2 - WIDTH_LOG2),\OutAcc_L_A	# as we prepare to exit shift the outside L vecs back to there original position as promised
	psrld	$(BYTES_PER_INNER_LOG2 - WIDTH_LOG2),\OutAcc_L_B

	# SIMD_16b_to_32b  inLower, upper, zeros
	SIMD_16b_to_32b		%H_0, %xmm6, %ZERO_VEC
	SIMD_16b_to_32b		%H_1, %xmm7, %ZERO_VEC

	SIMD_16b_to_32b		%L_0, %xmm4, %ZERO_VEC
	SIMD_16b_to_32b		%L_1, %xmm5, %ZERO_VEC
	
	/* combine with outer loop accumulators, upper(later) half of each inner accumulator MUST be combined with the *_B, lower(first) half MUST -> *_A
	 * L vec can simply be added, H vecs need a little adjustment, elements from the H_0 vec must be doubled, H1 must be scaled double minus 1 * L_1  */
	
	pslld			$1,%H_1
	pslld			$1,%xmm7

	pslld			$1,%H_0
	pslld			$1,%xmm6

	psubd			%L_1,%H_1
	psubd			%xmm5,%xmm7
	
	paddd			%L_0,\OutAcc_L_A	
	paddd			%xmm4,\OutAcc_L_B	
	paddd			%L_1,\OutAcc_L_A	
	paddd			%xmm5,\OutAcc_L_B	
	
	paddd			%H_0,\OutAcc_H_A	
	paddd			%xmm6,\OutAcc_H_B	
	paddd			%H_1,\OutAcc_H_A	
	paddd			%xmm7,\OutAcc_H_B	
.endm



/* wrap the macro in a function so we can test call overhead vs inline size bloat */
inner_loop_func:
	Inner_Loop_head_regular %BUF_ARG, %LEN_ARG, %L_ACUM_VEC32b_A, %L_ACUM_VEC32b_B, %H_ACUM_VEC32b_A, %H_ACUM_VEC32b_B      
inner_loop_func_prechecked:		/* skip the head if we have already prechecked the length */
	Inner_Loop_body %BUF_ARG, %LEN_ARG, %L_ACUM_VEC32b_A, %L_ACUM_VEC32b_B, %H_ACUM_VEC32b_A, %H_ACUM_VEC32b_B      
	retq



x64_adler32:		# Funtion entry point, global symbol

	testq	%BUF_ARG,%BUF_ARG
	jnz	.buf_valid
	/* for compatibility with orig zlib implementation initialize if buffer is null */
	movq	$INIT_ADLER,%rax
	retq
.buf_valid:

	/* if function is called with len=0 just return the checksum provided in the arg */
	testq	%LEN_ARG,%LEN_ARG
	jnz	.not_done_0
	movq	%ADLER_ARG,%rax
	retq
	
.not_done_0:

	/* import starting checksum, ADLER_ARG not used after this so it is fine to reuse the register */
	#movq	%ADLER_ARG,%SUM_H	# currently uses the same register, disable this "NOP" b/c the assembler won't optimize it out
	movq	%ADLER_ARG,%SUM_L
	shrq	$16,%SUM_H
	andq	$0xffff,%SUM_L

	/* process any unaligned data in the head of the buffer */
	/* note that we already checked that there is at least 1 byte to be processed */
.buf_head_loop:
	testq	$ALIGN_MASK,%BUF_ARG
	jz	.aligned
	
	movzb	(%BUF_ARG),%r8
	addq	%r8,%SUM_L		#revisit this, would using the memory operand directly speed this up?
	addq	%SUM_L,%SUM_H
	/* defer adler32 modulo operation for later */

	incq	%BUF_ARG
	decq	%LEN_ARG
	jnz	.buf_head_loop	# loop unless length remaining hits zero	
	jmp	.done		# length is zero, we are done

.aligned:
	cmpq	$BYTES_PER_INNER_LOOP,%LEN_ARG	# if there are less than BYTES_PER_INNER_LOOP bytes remaining by the time we are aligned skip the SIMD code
	jb	.buf_tail


x64_adler32_64:   /* same as x64_adler32 except assume 16 byte alignment and n*64 length (TODO import existing sum so this could be called directly) */

	movq	%LEN_ARG,%PRE_SIMD_LEN		# save so we can figure out the number of bytes processed later
.init:

/******** Outer Loop with 32bit accumulator vectors ********/
	pxor	%ZERO_VEC,%ZERO_VEC	# zero our vector of zeros (because SIMD width immediate values are generally not possible)
					### and the alternative is loading from memory
	pxor	%H_ACUM_VEC32b_A,%H_ACUM_VEC32b_A	# zero both our accumulators
	pxor	%H_ACUM_VEC32b_B,%H_ACUM_VEC32b_B	# zero both our accumulators
	pxor	%L_ACUM_VEC32b_A,%L_ACUM_VEC32b_A
	pxor	%L_ACUM_VEC32b_B,%L_ACUM_VEC32b_B


.outer_init:
	movq	$MAX_OUTER_LOOPS,%OUTER_COUNT			# init loop counter

	cmpq	$(MAX_OUTER_LOOPS * MAX_INNER_LOOPS * BYTES_PER_INNER_LOOP),%LEN_ARG	# pre-check if we can it the max loops before overflow before running out of bytes to read
											### if so skip some in-loop checks
	jae     .outer_init_prechecked    # likely branch
	jmp	.outer_loop    # unlikely: last loop, run the usual checks


.outer_init_prechecked:	
	Inner_Loop_prechecked_init %BUF_ARG, %LEN_ARG, %L_ACUM_VEC32b_A, %L_ACUM_VEC32b_B, %H_ACUM_VEC32b_A, %H_ACUM_VEC32b_B      
.outer_loop_prechecked:	
	Inner_Loop_head_prechecked %BUF_ARG, %LEN_ARG, %L_ACUM_VEC32b_A, %L_ACUM_VEC32b_B, %H_ACUM_VEC32b_A, %H_ACUM_VEC32b_B      
	call	inner_loop_func_prechecked
	
	dec		%OUTER_COUNT
	jnz		.outer_loop_prechecked

#define MOD_DEFER 1
#if MOD_DEFER
	cmpq	$BYTES_PER_INNER_LOOP,%LEN_ARG	# if there are less than one SIMD loop of bytes remaining break out of the outer loop
	jb	.SIMD_done
#endif
	jmp		.exit_outer_loop


.outer_loop:	
	call	inner_loop_func


/* Loop if there are still at least one SIMD loop of bytes left and we are not going to overflow our 32bit accumulators */
	
	cmpq	$BYTES_PER_INNER_LOOP,%LEN_ARG	# if there are less than one SIMD loop of bytes remaining break out of the outer loop
	jb	.SIMD_done		# Note was "jl" but we are dealing with unsigned so I think it should be "jb"

	dec		%OUTER_COUNT
	jg		.outer_loop	# signed greater than since modulo deferal lets it dec past zero


.exit_outer_loop:
#if MOD_DEFER
/* If none of the MSBs in any of the packed ints are set we can safely defer the modulo for one more loop */
	movmskps	%H_ACUM_VEC32b_A, %r10
	movmskps	%H_ACUM_VEC32b_B, %r11
	#inc		%OUTER_COUNT    # changed conditionals so that we can just let the counter go negative and skip this
	or		%r10,%r11
	jz		.outer_loop	# aways go to the normal outer loop not the prechecked so that len is adjusted correctly even if coming from the prechecked loop
#endif
.SIMD_done:
	/* the counter hit zero, we are about one loop away from risking overflow in our vectors of 32bit accumulators */
	/* ... or less than <SIMD-width> bytes remain
	
.mod_l_SIMD:
	/* The elements of the L vector(s) are 32bit here but the max value is 
	 * BYTE_MAX * BYTES_PER_INNER_LOOP * MAX_INNER_LOOPS * MAX_OUTER_LOOPS
	 * 255 * 2 * 11 * 360 = 2019600 or a little less than 2^21
	 * 
	 * This algorithm of doing a modulo 2^16 but adding back 15 per 2^16 to achieve a mod 65521 (Adler's prime number modulo)
	 * means that we are reducing the max value by over 2^12 per pass not including the modulo of the low bits 
	 * (15 < 2^4,  (2^4)/(2^16) = 2^12). 
	 * Since the max value of the elements of the L vector(s) are 2^21, the max value after one pass is 2^(21-12) + 2^16
	 * 2^9 + 2^16 < 2*ADLER_PRIME 
	 * ...therefore we only need to do 1x "divide" pass and 1x "subtract" pass to calculate the adler modulo on the L vector(s) 
	 */

	#.macro Adler_Modulo_SIMD_Twin_32b vecA vecB prime primeMinus1 mask tmpA1 tmpA2 tmpB1 tmpB2
	#Adler_Modulo_SIMD_Twin_32b  %L_ACUM_VEC32b_A,  %L_ACUM_VEC32b_B, %xmm0, %xmm1, %xmm2, %xmm3, %xmm4, %xmm5, %xmm6

	
	/* L vector needs just one div passe */	
	Adler_Modulo_SIMD_32b_init_consts		%xmm0, %xmm1, %xmm2, %xmm3, %xmm4
	Adler_Modulo_SIMD_Twin_32b_one_div_pass		%L_ACUM_VEC32b_A,  %L_ACUM_VEC32b_B, %xmm0, %xmm1, %xmm2, %xmm3, %xmm4, %xmm5, %xmm6
	Adler_Modulo_SIMD_Twin_32b_one_sub_pass		%L_ACUM_VEC32b_A,  %L_ACUM_VEC32b_B, %xmm0, %xmm1, %xmm2, %xmm3, %xmm4, %xmm5, %xmm6

.mod_h_SIMD:

	/* H vector needs two div passes */	
	/* re-use the constant inialization above*/
	Adler_Modulo_SIMD_Twin_32b_one_div_pass		%H_ACUM_VEC32b_A,  %H_ACUM_VEC32b_B, %xmm0, %xmm1, %xmm2, %xmm3, %xmm4, %xmm5, %xmm6
	Adler_Modulo_SIMD_Twin_32b_one_div_pass		%H_ACUM_VEC32b_A,  %H_ACUM_VEC32b_B, %xmm0, %xmm1, %xmm2, %xmm3, %xmm4, %xmm5, %xmm6
	Adler_Modulo_SIMD_Twin_32b_one_sub_pass		%H_ACUM_VEC32b_A,  %H_ACUM_VEC32b_B, %xmm0, %xmm1, %xmm2, %xmm3, %xmm4, %xmm5, %xmm6

	#.macro Adler_Modulo_SIMD_Twin_32b vecA vecB prime primeMinus1 mask tmpA1 tmpA2 tmpB1 tmpB2
	#Adler_Modulo_SIMD_Twin_32b  %H_ACUM_VEC32b_A  %H_ACUM_VEC32b_B %xmm0 %xmm1 %xmm2 %xmm3 %xmm4 %xmm5 %xmm6


	cmpq	$BYTES_PER_INNER_LOOP,%LEN_ARG	# if there are less than 16 bytes remaining break out of the outer loop
	jb	.unpack_SIMD_result		# Note was "jl" but we are dealing with unsigned so I thinkk it should be "jb"
	jmp		.outer_init

	# const data inside the .text section accessed below via %rip-relative addressing. This is close to the instructions
	# that access these constants and this will never get executed as instructions because of the unconditional jump above

	# put our multiplier arrays in .text and use instruction pointer relative addressing (aka %rip-relative)
	# this makes keeping this -fPIC compatible easier and should be good for performance
	.align 16
	const_4x32bit_0x2x:
		.long	0,0,2,0
	const_4x32bit_4x6x:
		.long	4,0,6,0	
	const_4x32bit_1x3x:
		.long	1,0,3,0
	const_4x32bit_5x7x:
		.long	5,0,7,0	



.unpack_SIMD_result:
	## scale up by width, note we have already done a modulo pass so scaling won't overflow ##
	pslld		$WIDTH_LOG2,%H_ACUM_VEC32b_A
	pslld		$WIDTH_LOG2,%H_ACUM_VEC32b_B



	/* replace this with a general combine adlers function */
	movq		%rdx,%r10		# save both %rdx and %rax before the multiply instruction overwrites them
	movq		%rax,%r11
	subq    	%LEN_ARG,%PRE_SIMD_LEN	# figure out how many bytes where processed in the SIMD section, store in PRE_SIMD_LEN
	#movq		%LEN_ARG,%rax		# this would be needed except %LEN_ARG happens to be an alias for %rax	
	mulq 		%PRE_SIMD_LEN		# the unsigned multiply op for x86-64 is limited to  %rax * arg -> %rdx:rax
						## %LEN_ARG is %rdx and %rax is SUM_L
	addq		%rax,%SUM_H		# SUM_H += SUM_L * bytes-processed-in-SIMD-code
						# IGNORES product bits 64-127 in %rdx, assume product is <2^64 
						# (safe for up to many TB of data, TODO figure out exactly and document/or add check)
	movq		%r10,%rdx		# restore %rdx (LEN_ARG) after multiply 
	movq		%r11,%rax		# restore %rax (SUM_L) after multiply
	
	

	/* the L vector [L0,L1,L2,...,LN] is stored such that 
	 * 	L = sum(L0 + L1 + L2 + ... + LN)
	 * however the H vector [H0,H1,H2,...,HN] is stored such that
	 * 	H = W * sum (H0 + H1 + H2 + ... + HN) - (W-1)L0 - (W-2)L1 - (W-3)L2 - ....
	 *
	 * (W is SIMD width, 8 in this code, could be more if AVX is used)
	 */
	/* The elements of the L vector are 32bit here but the max value is 
	 * BYTE_MAX * BYTES_PER_INNER_LOOP * MAX_INNER_LOOPS * MAX_OUTER_LOOPS
	 * 255 * 2 * 11 * 360 = 2019600 or a little less than 2^21
	 * We multiply these elements by at most one less than ints-per-SIMD-register (8, 2^3, could be 32 with AVX-512) 	
	 * so our product is < 2^24 (or < 2^26 with AVX-512) so we can safely chop off the top 32 bits of the 64bit product here
	 */


	
	/* take the prime vec from above and mult by width for use below creating an equivalent positive number in the modulo */
	pslld		$(WIDTH_LOG2 + 1),%xmm0		# + 1 because we add A and B together so we need to be one order of magnitude larger base 2
	movdqa		%xmm0,%xmm6


	# calculate adjustment for H A [ -0, -1, -2, -3] and
	# H B [ -4, -5, -6, -7 ] with interleaved operations
	movdqa		%L_ACUM_VEC32b_A,%xmm1		#A
	movdqa		%L_ACUM_VEC32b_B,%xmm2		#B
	movdqa		%L_ACUM_VEC32b_A,%H_ADJUST_A	#A
	movdqa		%L_ACUM_VEC32b_B,%H_ADJUST_B	#B
	PMULUDQ		const_4x32bit_0x2x(%rip),%xmm1	#A multiply 1st and third 32bit packed ints and store result as two 64bit ints
	PMULUDQ		const_4x32bit_4x6x(%rip),%xmm2	#B multiply 1st and third 32bit packed ints and store result as two 64bit ints
	PSHUFD		$0xb1,%H_ADJUST_A,%H_ADJUST_A	#A this should swap 1st and 2nd, 3rd and 4th ints
	PSHUFD		$0xb1,%H_ADJUST_B,%H_ADJUST_B	#B this should swap 1st and 2nd, 3rd and 4th ints
	PMULUDQ		const_4x32bit_1x3x(%rip),%H_ADJUST_A	#A multiply 1st and 3rd 32bit packed ints and store as two 64bit ints
	PMULUDQ		const_4x32bit_5x7x(%rip),%H_ADJUST_B	#B multiply 1st and 3rd 32bit packed ints and store as two 64bit ints
	PSHUFD          $0xb1,%H_ADJUST_A,%H_ADJUST_A	#A this should swap 1st and 2nd, 3rd and 4th ints and reverse the shuffle above
	PSHUFD          $0xb1,%H_ADJUST_B,%H_ADJUST_B	#B this should swap 1st and 2nd, 3rd and 4th ints and reverse the shuffle above
							## putting the lower 32bits of of the product in position 2 and 4 
							## (when viewing the register as 4x32bit)
	paddq		%xmm1,%H_ADJUST_A		#A upper 32 bits of the products are zeros so we can "add" to combine
							### the products into the 4x32bit vector we want
	paddq		%xmm2,%H_ADJUST_B		#B upper 32 bits of the products are zeros so we can "add" to combine the


	/* we don't actually need to keep the adjustments separate, just add them up, make it an equivalent positive number in the modulo, and incorporate into vec A	*/
	paddq		%H_ADJUST_B,%H_ADJUST_A
	psubd		%H_ADJUST_A,%xmm6	# make the number the modulo equivalent of a negative number so we can add a postive number to "subtract" 
	movdqa		%xmm6,%H_ADJUST_A
	paddd		%H_ADJUST_A,%H_ACUM_VEC32b_A	#A Incorporate our adjustments  adjustment is like a negative number we can add to conceptually "subtract"



	/* Logically we want to subtract the adjustment however we want to avoid subtraction and negative numbers so we do is find
	 * number that would give the same modulo result as subtraction. For example: 
	 * (9 - 7) % 10 == 2 == (9 + 3) % 10   where subtracting x, 7, is the same as adding (mod-base - x), 10 - 7 = 3
	 *
	 * The L vector elements are already < MOD_BASE (65521) so our adjustment will not be more than
	 * (0 + 1 + ... Width-1) * MOD_BASE,   0.5*w(w-1)*MOD_BASE,  28*MOD_BASE for width=8    (we will go higher to keep the assemble-time math simple)
	 */

.add_up_items:

	/* vector items must be <2^29 here to avoid overflow, not a problem since we enforced modulo not long ago ( (2^32)-1 - log2(SIMD width) ) */
	
	movq		%rax,%r9	# we need to use %eax for a bit slightly later, stash the value (SUM_L)

	paddd		%L_ACUM_VEC32b_B,%L_ACUM_VEC32b_A	
	paddd		%H_ACUM_VEC32b_B,%H_ACUM_VEC32b_A	

	# make vector copy with reverse elements
	pshufd		$0x1B,%L_ACUM_VEC32b_A,%xmm0
	pshufd		$0x1B,%H_ACUM_VEC32b_A,%xmm2

	paddd		%xmm0,%L_ACUM_VEC32b_A
	paddd		%xmm2,%H_ACUM_VEC32b_A

	# flip elements 0 <-> 1 and 2 <-> 3
	pshufd		$0xB1,%L_ACUM_VEC32b_A,%xmm0
	pshufd		$0xB1,%H_ACUM_VEC32b_A,%xmm2

	paddd		%xmm0,%L_ACUM_VEC32b_A
	paddd		%xmm2,%H_ACUM_VEC32b_A

	/* movd must be used with 32bit registers otherwise the opcode will turn into a movq 64bit move behind the scenes
	 * despite documentation leading me to expect a zero extended 32->64bit move */
	movd		%L_ACUM_VEC32b_A,%eax
	movd		%H_ACUM_VEC32b_A,%ecx

	addq		%r9,%rax	# %rax is %SUM_L

	addq		%rcx,%SUM_H

.buf_tail:		
	/* process any unaligned data in the tail of the buffer */ 
	testq	%LEN_ARG,%LEN_ARG
	jz	.done
.buf_tail_loop:		
	movzb	(%BUF_ARG),%rcx
	addq	%rcx,%SUM_L		#revisit this, would using the memory operand directly speed this up?
	addq	%SUM_L,%SUM_H
	/* defer adler32 modulo operation for later */

	incq	%BUF_ARG
	decq	%LEN_ARG
	jnz	.buf_tail	# loop until length remaining hits zero	
	

.done:
	movq		%SUM_H,%xmm1	# clears upper half
	movq		%SUM_L,%xmm0
	movlhps		%xmm1,%xmm0	# copy lower to upper, technically a floating point op but I do not think there is a proper int equivalent in the instruction set

	# may use this in the future but for now just call phases individually
	#.macro Adler_Modulo_SIMD_Twin_64b vecA vecB prime primeMinus1 mask tmpA1 tmpA2 tmpB1 tmpB2

	# LIMITED PASSES, assumes input is not that large otherwise more passes needed

	#.macro Adler_Modulo_SIMD_64b_init_consts prime primeMinus1 mask tmpA1 tmpA2
	Adler_Modulo_SIMD_64b_init_consts %xmm1, %xmm2, %xmm4, %xmm5, %xmm6
	#.macro Adler_Modulo_SIMD_64b_one_div_pass vecA prime primeMinus1 mask tmpA1 tmpA2
	Adler_Modulo_SIMD_64b_one_div_pass %xmm0, %xmm1, %xmm2, %xmm4, %xmm5, %xmm6
	Adler_Modulo_SIMD_64b_one_div_pass %xmm0, %xmm1, %xmm2, %xmm4, %xmm5, %xmm6
	#.macro Adler_Modulo_SIMD_64b_one_sub_pass vecA prime primeMinus1 mask tmpA1 tmpA2
	Adler_Modulo_SIMD_64b_one_sub_pass %xmm0, %xmm1, %xmm2, %xmm4, %xmm5, %xmm6 

	movq		%xmm0,%SUM_L
	movhlps		%xmm0,%xmm0
	movq            %xmm0,%SUM_H
	/* assemble sums into checksum return value */
	/* Note: SUM_L is the return register, rax */
	shlq	$16,%SUM_H
	orq	%SUM_H,%SUM_L
	retq

.todo:
	movq	$0xffff70d0,%rax	# return invalid adler32
	retq
.error:
	movq	$0xffffffff,%rax	# return invalid adler32
	retq
