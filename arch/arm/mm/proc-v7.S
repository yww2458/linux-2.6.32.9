/*
 *  linux/arch/arm/mm/proc-v7.S
 *
 *  Copyright (C) 2001 Deep Blue Solutions Ltd.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 *
 *  This is the "shell" of the ARMv7 processor support.
 */
#include <linux/init.h>
#include <linux/linkage.h>
#include <asm/assembler.h>
#include <asm/asm-offsets.h>
#include <asm/hwcap.h>
#include <asm/pgtable-hwdef.h>
#include <asm/pgtable.h>

#include "proc-macros.S"

#define TTB_S		(1 << 1)
#define TTB_RGN_NC	(0 << 3)
#define TTB_RGN_OC_WBWA	(1 << 3)
#define TTB_RGN_OC_WT	(2 << 3)
#define TTB_RGN_OC_WB	(3 << 3)
#define TTB_NOS		(1 << 5)
#define TTB_IRGN_NC	((0 << 0) | (0 << 6))
#define TTB_IRGN_WBWA	((0 << 0) | (1 << 6))
#define TTB_IRGN_WT	((1 << 0) | (0 << 6))
#define TTB_IRGN_WB	((1 << 0) | (1 << 6))


#ifndef CONFIG_SMP
/* PTWs cacheable, inner WB not shareable, outer WB not shareable */
#define TTB_FLAGS	TTB_IRGN_WB|TTB_RGN_OC_WB
#define PMD_FLAGS	PMD_SECT_WB
#else
/* PTWs cacheable, inner WBWA shareable, outer WBWA not shareable */
#define TTB_FLAGS	TTB_IRGN_WBWA|TTB_S|TTB_NOS|TTB_RGN_OC_WBWA
#define PMD_FLAGS	PMD_SECT_WBWA|PMD_SECT_S
#endif

#ifdef CONFIG_CPU_PJ4
#define CPU_V7_CR_TRE_REMAP_ENABLE
#endif

ENTRY(cpu_v7_proc_init)
	mov	pc, lr
ENDPROC(cpu_v7_proc_init)

ENTRY(cpu_v7_proc_fin)
	stmfd	sp!, {lr}
	cpsid	if				@ disable interrupts
	bl	v7_flush_kern_cache_all
	mrc	p15, 0, r0, c1, c0, 0		@ ctrl register
	bic	r0, r0, #0x1000			@ ...i............
	bic	r0, r0, #0x0006			@ .............ca.
	mcr	p15, 0, r0, c1, c0, 0		@ disable caches
#ifdef CONFIG_CPU_PJ4	
	mrc	p15, 0, r0, c1, c0, 1
	bic	r0, r0, #0x2
	mcr	p15, 0, r0, c1, c0, 1		@ disable L2 cache
#endif
	ldmfd	sp!, {pc}
ENDPROC(cpu_v7_proc_fin)

/*
 *	cpu_v7_reset(loc)
 *
 *	Perform a soft reset of the system.  Put the CPU into the
 *	same state as it would be if it had been reset, and branch
 *	to what would be the reset vector.
 *
 *	- loc   - location to jump to for soft reset
 *
 *	It is assumed that:
 */
	.align	5
ENTRY(cpu_v7_reset)
	mov	pc, r0
ENDPROC(cpu_v7_reset)

/*
 *	cpu_v7_do_idle()
 *
 *	Idle the processor (eg, wait for interrupt).
 *
 *	IRQs are already disabled.
 */
ENTRY(cpu_v7_do_idle)

	dsb					@ WFI may enter a low-power mode
#ifdef CONFIG_DOVE_DEBUGGER_MODE_V6
	mov	r1, #0
	mcr	p15, 0, r1, c7, c0, 4		@ wait for interrupt
#else
	wfi
#endif
#ifdef CONFIG_DOVE_REV_Y0
	mrc	p15, 0, r0, c0, c0, 0		@ Main ID
	and	r0, #0xF
	cmp	r0, #1				@ issue the following instructions for Y0 only
	mcreq   p15, 0, r1, c7, c5, 4           @ Prefetch Flush - ISB
	mcreq	p15, 0, r1, c7, c10, 4		@ Sync Data barrier
#endif
	mov	pc, lr
ENDPROC(cpu_v7_do_idle)

ENTRY(cpu_v7_dcache_clean_area)
#ifndef TLB_CAN_READ_FROM_L1_CACHE
	dcache_line_size r2, r3
1:	mcr	p15, 0, r0, c7, c10, 1		@ clean D entry
#ifndef CONFIG_MRV_PTE_IN_L2
	mcr     p15, 1, r0, c7, c11, 1		@ clean L2C D entry
#endif
	add	r0, r0, r2
	subs	r1, r1, r2
	bhi	1b
	dsb
#endif
	mov	pc, lr
ENDPROC(cpu_v7_dcache_clean_area)

/*
 *	cpu_v7_switch_mm(pgd_phys, tsk)
 *
 *	Set the translation table base pointer to be pgd_phys
 *
 *	- pgd_phys - physical address of new TTB
 *
 *	It is assumed that:
 *	- we are not using split page tables
 */
ENTRY(cpu_v7_switch_mm)
#ifdef CONFIG_MMU
	mov	r2, #0
	ldr	r1, [r1, #MM_CONTEXT_ID]	@ get mm->context.id
#ifdef CONFIG_MRV_PTE_IN_L2 
	orr	r0, r0, #TTB_FLAGS
#else
	bic     r0, r0, #0x18                   @ DONOT Cache the page table in L2
#endif
#ifdef CONFIG_ARM_ERRATA_430973
	mcr	p15, 0, r2, c7, c5, 6		@ flush BTAC/BTB
#endif
	isb
	mcr	p15, 0, r2, c13, c0, 1		@ set reserved context ID
	isb
1:	mcr	p15, 0, r0, c2, c0, 0		@ set TTB 0
	isb
	mcr	p15, 0, r1, c13, c0, 1		@ set context ID
	isb
#endif
	mov	pc, lr
ENDPROC(cpu_v7_switch_mm)

/*
 *	cpu_v7_set_pte_ext(ptep, pte)
 *
 *	Set a level 2 translation table entry.
 *
 *	- ptep  - pointer to level 2 translation table entry
 *		  (hardware version is stored at -1024 bytes)
 *	- pte   - PTE value to store
 *	- ext	- value for extended PTE bits
 */
	armv6_mt_table cpu_v7
ENTRY(cpu_v7_set_pte_ext)
#ifdef CPU_V7_CR_TRE_REMAP_ENABLE
#ifdef CONFIG_MMU
 ARM(	str	r1, [r0], #-2048	)	@ linux version
 THUMB(	str	r1, [r0]		)	@ linux version
 THUMB(	sub	r0, r0, #2048		)

	bic	r3, r1, #0x000003f0
	bic	r3, r3, #PTE_TYPE_MASK
	orr	r3, r3, r2
	orr	r3, r3, #PTE_EXT_AP0 | 2

	tst	r1, #1 << 4
	orrne	r3, r3, #PTE_EXT_TEX(1)

	tst	r1, #L_PTE_WRITE
	tstne	r1, #L_PTE_DIRTY
	orreq	r3, r3, #PTE_EXT_APX

	tst	r1, #L_PTE_USER
	orrne	r3, r3, #PTE_EXT_AP1
	tstne	r3, #PTE_EXT_APX
	bicne	r3, r3, #PTE_EXT_APX | PTE_EXT_AP0

	tst	r1, #L_PTE_EXEC
	orreq	r3, r3, #PTE_EXT_XN

	tst	r1, #L_PTE_YOUNG
	tstne	r1, #L_PTE_PRESENT
	moveq	r3, #0
	str	r3, [r0]
	mcr	p15, 0, r0, c7, c10, 1		@ flush_pte
#ifndef CONFIG_MRV_PTE_IN_L2
        mcr     p15, 1, r0, c7, c11, 1 @ clean L2C D entry
#endif
#endif
#else /* CPU_V7_CR_TRE_REMAP_ENABLE */
	/* Use TRE=0 (remap is off) scheme for full featured MMU */
	armv6_set_pte_ext cpu_v7 
#endif /* CPU_V7_CR_TRE_REMAP_ENABLE */
	mov	pc, lr

ENDPROC(cpu_v7_set_pte_ext)

cpu_v7_name:
	.ascii	"ARMv7 Processor"
	.align

cpu_pj4_name:
	.ascii	"Marvell PJ4 v7 Processor"
#ifdef CONFIG_IWMMXT
	.ascii	"-wmmx"
#endif
#ifdef CONFIG_CPU_ENABLE_WRITECO
	.ascii	"-wco"
#endif 
	.ascii  "\0"
	.align

	__INIT

/*
 *	__v7_setup
 *
 *	Initialise TLB, Caches, and MMU state ready to switch the MMU
 *	on.  Return in r0 the new CP15 C1 control register setting.
 *
 *	We automatically detect if we have a Harvard cache, and use the
 *	Harvard cache control instructions insead of the unified cache
 *	control instructions.
 *
 *	This should be able to cover all ARMv7 cores.
 *
 *	It is assumed that:
 *	- cache type register is implemented
 */
__v7_setup:
#ifdef CONFIG_DOVE_REV_Y0
	mrc p15, 1, r0, c15, c1, 0
        mrc     p15, 0, r10, c0, c0, 0          @ Main ID Y0 or not
        and     r10, #0xF
        cmp     r10, #5
	orrlt  	r0, r0, #(1<<15)		@ Disable VFP/WMMX dual issue
        cmp     r10, #1
	orrle   r0, r0, #(1<<21)		@ X0 - Enable L2 Cache Way 7-4 
	mcr p15, 1, r0, c15, c1, 0
#endif
#ifdef CONFIG_SMP
	mrc	p15, 0, r0, c1, c0, 1
	tst	r0, #(1 << 6)			@ SMP/nAMP mode enabled?
	orreq	r0, r0, #(1 << 6) | (1 << 0)	@ Enable SMP/nAMP mode and
	mcreq	p15, 0, r0, c1, c0, 1		@ TLB ops broadcasting
#endif
#ifdef CONFIG_CPU_PJ4_PMC_ACCESS_IN_USERMODE
	@ Enable performance counters user access
	mrc     p15, 0, r0, c9, c14, 0
	orr     r0, r0, #0x1
	mcr     p15, 0, r0, c9, c14, 0
#endif /* CONFIG_CPU_PJ4_PMC_ACCESS_IN_USERMODE */
	adr	r12, __v7_setup_stack		@ the local stack
	stmia	r12, {r0-r5, r7, r9, r11, lr}
	bl	v7_flush_dcache_all
	ldmia	r12, {r0-r5, r7, r9, r11, lr}

	mrc	p15, 0, r0, c0, c0, 0		@ read main ID register
	and	r10, r0, #0xff000000		@ ARM?
	teq	r10, #0x41000000
	bne	2f
	and	r5, r0, #0x00f00000		@ variant
	and	r6, r0, #0x0000000f		@ revision
	orr	r0, r6, r5, lsr #20-4		@ combine variant and revision

#ifdef CONFIG_ARM_ERRATA_430973
	teq	r5, #0x00100000			@ only present in r1p*
	mrceq	p15, 0, r10, c1, c0, 1		@ read aux control register
	orreq	r10, r10, #(1 << 6)		@ set IBE to 1
	mcreq	p15, 0, r10, c1, c0, 1		@ write aux control register
#endif
#ifdef CONFIG_ARM_ERRATA_458693
	teq	r0, #0x20			@ only present in r2p0
	mrceq	p15, 0, r10, c1, c0, 1		@ read aux control register
	orreq	r10, r10, #(1 << 5)		@ set L1NEON to 1
	orreq	r10, r10, #(1 << 9)		@ set PLDNOP to 1
	mcreq	p15, 0, r10, c1, c0, 1		@ write aux control register
#endif
#ifdef CONFIG_ARM_ERRATA_460075
	teq	r0, #0x20			@ only present in r2p0
	mrceq	p15, 1, r10, c9, c0, 2		@ read L2 cache aux ctrl register
	tsteq	r10, #1 << 22
	orreq	r10, r10, #(1 << 22)		@ set the Write Allocate disable bit
	mcreq	p15, 1, r10, c9, c0, 2		@ write the L2 cache aux ctrl register
#endif

2:	mov	r10, #0
#ifdef HARVARD_CACHE
	#ifdef CONFIG_CPU_PJ4_ERRATA_4574_4731
	mcr	p15, 0, r10, c7, c5, 0		@ I+BTB cache invalidate
	#endif
	mcr	p15, 0, r10, c7, c5, 0		@ I+BTB cache invalidate
#endif
	dsb
#ifdef CONFIG_MMU
	mcr	p15, 0, r10, c8, c7, 0		@ invalidate I + D TLBs
	mcr	p15, 0, r10, c2, c0, 2		@ TTB control register
	dsb
	isb
#ifdef CONFIG_MRV_PTE_IN_L2
	orr	r4, r4, #TTB_FLAGS
#else
						@ OC bits in TTB1 register
	bic	r4, r4, #0x18                   @ DONOT Cache the page table in L2
#endif
#ifdef CONFIG_CPU_ENABLE_WRITECO
						@ Refer 88SV581x-v7.Rev1.5.pdf
	mrc	p15, 1, r0, c15, c1, 0		@ Read Marvell Extra Features Reg
	orr	r0, r0, #0x100
        mrc     p15, 0, r10, c0, c0, 0          @ Main ID Y0 or not
        and     r10, #0xF
        cmp     r10, #1
						@ Write coalesce cycles
						@ Only for not X0
	orreq	r0, r0, #CONFIG_CPU_WRITECO_CYCLE << 9	@ Y0
	mcr	p15, 1, r0, c15, c1, 0		@ Write Marvell Extra Features Reg
	mrcne   p15, 1, r0, c15, c2, 0          @ Auxiliary Function Reg
	bicne	r0, #0x3 << 4
	orrne	r0, r0, #CONFIG_CPU_WRITECO_CYCLE << 4	@ X0
	mcrne   p15, 1, r0, c15, c2, 0          @ Write Marvell Auxiliary Function Reg
#else
	mrc     p15, 1, r0, c15, c1, 0          @ Read Marvell Extra Features Reg
	bic 	r0, r0, #0x100
	mcr     p15, 1, r0, c15, c1, 0          @ Write Marvell Extra Features Reg
#endif
	mcr	p15, 0, r4, c2, c0, 1		@ load TTB1
	mov	r10, #0x1f			@ domains 0, 1 = manager
	mcr	p15, 0, r10, c3, c0, 0		@ load domain access register
	/*
	 * Memory region attributes with SCTLR.TRE=1
	 *
	 *   n = TEX[0],C,B
	 *   TR = PRRR[2n+1:2n]		- memory type
	 *   IR = NMRR[2n+1:2n]		- inner cacheable property
	 *   OR = NMRR[2n+17:2n+16]	- outer cacheable property
	 *
	 *			n	TR	IR	OR
	 *   UNCACHED		000	00
	 *   BUFFERABLE		001	10	00	00
	 *   WRITETHROUGH	010	10	10	10
	 *   WRITEBACK		011	10	11	11
	 *   reserved		110
	 *   WRITEALLOC		111	10	01	01
	 *   DEV_SHARED		100	01
	 *   DEV_NONSHARED	100	01
	 *   DEV_WC		001	10
	 *   DEV_CACHED		011	10
	 *
	 * Other attributes:
	 *
	 *   DS0 = PRRR[16] = 0		- device shareable property
	 *   DS1 = PRRR[17] = 1		- device shareable property
	 *   NS0 = PRRR[18] = 0		- normal shareable property
	 *   NS1 = PRRR[19] = 1		- normal shareable property
	 *   NOS = PRRR[24+n] = 1	- not outer shareable
	 */
	ldr	r5, =0xff0a81a8			@ PRRR
	ldr	r6, =0x40e040e0			@ NMRR
#ifdef CONFIG_CPU_ENABLE_WRITECO
						@ FIXME: Work around for WCO
						@ not working when TRE=1
						@ Set write-through, noWA instead
						@ Impact: D$ performance

	mrc	p15, 0, r0, c0, c0, 0		@ Main ID
	and	r0, #0xF
	cmp	r0, #1
	ldreq	r6, =0x40e840e8
#endif
#ifdef	CONFIG_CPU_L2WAONLY_ENABLE
	bic	r6, r6, #0x800000
#endif
	mcr	p15, 0, r5, c10, c2, 0		@ write PRRR
	mcr	p15, 0, r6, c10, c2, 1		@ write NMRR
#endif
	adr	r5, v7_crval
	ldmia	r5, {r5, r6}
#ifdef CONFIG_CPU_ENDIAN_BE8
	orr	r6, r6, #1 << 25		@ big-endian page tables
#endif
   	mrc	p15, 0, r0, c1, c0, 0		@ read control register
	bic	r0, r0, r5			@ clear bits them
	orr	r0, r0, r6			@ set them
 THUMB(	orr	r0, r0, #1 << 30	)	@ Thumb exceptions
	mov	pc, lr				@ return to head.S:__ret
ENDPROC(__v7_setup)

	/*   AT
	 *  TFR   EV X F   I D LR    S
	 * .EEE ..EE PUI. .T.T 4RVI ZWRS BLDP WCAM
	 * rxxx rrxx xxx0 0101 xxxx xxxx x111 xxxx < forced
	 *    1    0 110       0011 1100 .111 1101 < we want
	 */
	.type	v7_crval, #object
v7_crval:
#ifdef CPU_V7_CR_TRE_REMAP_ENABLE
	crval	clear=0x0120c302, mmuset=0x10c03c7d, ucset=0x00c01c7c
#else
	crval	clear=0x0120c302, mmuset=0x00c03c7d, ucset=0x00c01c7c
#endif

__v7_setup_stack:
	.space	4 * 11				@ 11 registers

	.type	v7_processor_functions, #object
ENTRY(v7_processor_functions)
	.word	v7_early_abort
	.word	v7_pabort
	.word	cpu_v7_proc_init
	.word	cpu_v7_proc_fin
	.word	cpu_v7_reset
	.word	cpu_v7_do_idle
	.word	cpu_v7_dcache_clean_area
	.word	cpu_v7_switch_mm
	.word	cpu_v7_set_pte_ext
	.size	v7_processor_functions, . - v7_processor_functions

	.type	cpu_arch_name, #object
cpu_arch_name:
	.asciz	"armv7"
	.size	cpu_arch_name, . - cpu_arch_name

	.type	cpu_elf_name, #object
cpu_elf_name:
	.asciz	"v7"
	.size	cpu_elf_name, . - cpu_elf_name
	.align

	.section ".proc.info.init", #alloc, #execinstr

	/*
	 * Match Marvell PJ4 v7 processor core.
	 */
	.type	__pj4_v7_proc_info, #object
__pj4_v7_proc_info:
	.long	0x560f5810		@ Marvell PJ4 ID
	.long	0xff0ffff0		@ Mask for ID
	.long   PMD_TYPE_SECT | \
		PMD_SECT_AP_WRITE | \
		PMD_SECT_AP_READ | \
		PMD_FLAGS
	.long   PMD_TYPE_SECT | \
		PMD_SECT_XN | \
		PMD_SECT_AP_WRITE | \
		PMD_SECT_AP_READ
	b	__v7_setup
	.long	cpu_arch_name
	.long	cpu_elf_name
	.long	HWCAP_SWP|HWCAP_HALF|HWCAP_THUMB|HWCAP_FAST_MULT|HWCAP_EDSP
	.long	cpu_pj4_name
	.long	v7_processor_functions
	.long	v7wbi_tlb_fns
	.long	v6_user_fns
	.long	v7_cache_fns
	.size	__pj4_v7_proc_info, . - __pj4_v7_proc_info

	
	/*
	 * Match any ARMv7 processor core.
	 */
	.type	__v7_proc_info, #object
__v7_proc_info:
	.long	0x000f0000		@ Required ID value
	.long	0x000f0000		@ Mask for ID
	.long   PMD_TYPE_SECT | \
		PMD_SECT_AP_WRITE | \
		PMD_SECT_AP_READ | \
		PMD_FLAGS
	.long   PMD_TYPE_SECT | \
		PMD_SECT_XN | \
		PMD_SECT_AP_WRITE | \
		PMD_SECT_AP_READ
	b	__v7_setup
	.long	cpu_arch_name
	.long	cpu_elf_name
	.long	HWCAP_SWP|HWCAP_HALF|HWCAP_THUMB|HWCAP_FAST_MULT|HWCAP_EDSP
	.long	cpu_v7_name
	.long	v7_processor_functions
	.long	v7wbi_tlb_fns
	.long	v6_user_fns
	.long	v7_cache_fns
	.size	__v7_proc_info, . - __v7_proc_info
