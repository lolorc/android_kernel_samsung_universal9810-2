/*
 * Copyright (C) 2015 - ARM Ltd
 * Author: Marc Zyngier <marc.zyngier@arm.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <linux/arm-smccc.h>
#include <linux/linkage.h>

#include <asm/alternative.h>
#include <asm/assembler.h>
#include <asm/cpufeature.h>
#include <asm/kvm_arm.h>
#include <asm/kvm_asm.h>
#include <asm/kvm_mmu.h>

.macro save_caller_saved_regs_vect
	stp	x0, x1,   [sp, #-16]!
	stp	x2, x3,   [sp, #-16]!
	stp	x4, x5,   [sp, #-16]!
	stp	x6, x7,   [sp, #-16]!
	stp	x8, x9,   [sp, #-16]!
	stp	x10, x11, [sp, #-16]!
	stp	x12, x13, [sp, #-16]!
	stp	x14, x15, [sp, #-16]!
	stp	x16, x17, [sp, #-16]!
.endm

.macro restore_caller_saved_regs_vect
	ldp	x16, x17, [sp], #16
	ldp	x14, x15, [sp], #16
	ldp	x12, x13, [sp], #16
	ldp	x10, x11, [sp], #16
	ldp	x8, x9,   [sp], #16
	ldp	x6, x7,   [sp], #16
	ldp	x4, x5,   [sp], #16
	ldp	x2, x3,   [sp], #16
	ldp	x0, x1,   [sp], #16
.endm

	.text
	.pushsection	.hyp.text, "ax"

.macro do_el2_call
	/*
	 * Shuffle the parameters before calling the function
	 * pointed to in x0. Assumes parameters in x[1,2,3].
	 */
	mov	lr, x0
	mov	x0, x1
	mov	x1, x2
	mov	x2, x3
	blr	lr
.endm

ENTRY(__vhe_hyp_call)
	str	lr, [sp, #-16]!
	do_el2_call
	ldr	lr, [sp], #16
	/*
	 * We used to rely on having an exception return to get
	 * an implicit isb. In the E2H case, we don't have it anymore.
	 * rather than changing all the leaf functions, just do it here
	 * before returning to the rest of the kernel.
	 */
	isb
	ret
ENDPROC(__vhe_hyp_call)

/*
 * Compute the idmap address of __kvm_hyp_reset based on the idmap
 * start passed as a parameter, and jump there.
 *
 * x0: HYP phys_idmap_start
 */
ENTRY(__kvm_hyp_teardown)
	mov	x4, x0
	adr_l	x3, __kvm_hyp_reset

	/* insert __kvm_hyp_reset()s offset into phys_idmap_start */
	bfi	x4, x3, #0, #PAGE_SHIFT
	br	x4
ENDPROC(__kvm_hyp_teardown)
	
el1_sync:				// Guest trapped into EL2
	stp	x0, x1, [sp, #-16]!

	mrs	x0, esr_el2
	lsr	x0, x0, #ESR_ELx_EC_SHIFT
	cmp	x0, #ESR_ELx_EC_HVC64
	ccmp	x0, #ESR_ELx_EC_HVC32, #4, ne
	b.ne	el1_trap

	mrs	x1, vttbr_el2		// If vttbr is valid, the guest
	cbnz	x1, el1_hvc_guest	// called HVC

	/* Here, we're pretty sure the host called HVC. */
	ldp	x0, x1, [sp], #16

	cmp	x0, #HVC_GET_VECTORS
	b.ne	1f
	mrs	x0, vbar_el2
	b	2f

1:
	/*
	 * Perform the EL2 call
	 */
	kern_hyp_va	x0
	do_el2_call

2:	eret

el1_hvc_guest:
	/*
	 * Fastest possible path for ARM_SMCCC_ARCH_WORKAROUND_1.
	 * The workaround has already been applied on the host,
	 * so let's quickly get back to the guest. We don't bother
	 * restoring x1, as it can be clobbered anyway.
	 */
	ldr	x1, [sp]				// Guest's x0
	eor	w1, w1, #ARM_SMCCC_ARCH_WORKAROUND_1
	cbz	w1, wa_epilogue

	/* ARM_SMCCC_ARCH_WORKAROUND_2 handling */
	eor	w1, w1, #(ARM_SMCCC_ARCH_WORKAROUND_1 ^ \
			  ARM_SMCCC_ARCH_WORKAROUND_2)
	cbnz	w1, el1_trap

#ifdef CONFIG_ARM64_SSBD
alternative_cb	arm64_enable_wa2_handling
	b	wa2_end
alternative_cb_end
	get_vcpu_ptr	x2, x0
	ldr	x0, [x2, #VCPU_WORKAROUND_FLAGS]

	// Sanitize the argument and update the guest flags
	ldr	x1, [sp, #8]			// Guest's x1
	clz	w1, w1				// Murphy's device:
	lsr	w1, w1, #5			// w1 = !!w1 without using
	eor	w1, w1, #1			// the flags...
	bfi	x0, x1, #VCPU_WORKAROUND_2_FLAG_SHIFT, #1
	str	x0, [x2, #VCPU_WORKAROUND_FLAGS]

	/* Check that we actually need to perform the call */
	hyp_ldr_this_cpu x0, arm64_ssbd_callback_required, x2
	cbz	x0, wa2_end

	mov	w0, #ARM_SMCCC_ARCH_WORKAROUND_2
	smc	#0

	/* Don't leak data from the SMC call */
	mov	x3, xzr
wa2_end:
	mov	x2, xzr
	mov	x1, xzr
#endif

wa_epilogue:
	mov	x0, xzr
	add	sp, sp, #16
	eret

el1_trap:
	get_vcpu_ptr	x1, x0

	mrs		x0, esr_el2
	lsr		x0, x0, #ESR_ELx_EC_SHIFT
	/*
	 * x0: ESR_EC
	 * x1: vcpu pointer
	 */

	/* Guest accessed VFP/SIMD registers, save host, restore Guest */
	cmp	x0, #ESR_ELx_EC_FP_ASIMD
	b.eq	__fpsimd_guest_restore

	mov	x0, #ARM_EXCEPTION_TRAP
	b	__guest_exit

el1_irq:
	stp     x0, x1, [sp, #-16]!
	get_vcpu_ptr	x1, x0
	mov	x0, #ARM_EXCEPTION_IRQ
	b	__guest_exit

el1_error:
	stp     x0, x1, [sp, #-16]!
	get_vcpu_ptr	x1, x0
	mov	x0, #ARM_EXCEPTION_EL1_SERROR
	b	__guest_exit

el2_error:
	save_caller_saved_regs_vect
	stp     x29, x30, [sp, #-16]!

	bl	kvm_unexpected_el2_exception

	ldp     x29, x30, [sp], #16
	restore_caller_saved_regs_vect

	eret

ENTRY(__hyp_do_panic)
	mov	lr, #(PSR_F_BIT | PSR_I_BIT | PSR_A_BIT | PSR_D_BIT |\
		      PSR_MODE_EL1h)
	msr	spsr_el2, lr
	ldr	lr, =panic
	msr	elr_el2, lr
	eret
ENDPROC(__hyp_do_panic)

ENTRY(__hyp_panic)
	get_host_ctxt x0, x1
	b	hyp_panic
ENDPROC(__hyp_panic)

.macro invalid_vector	label, target = __hyp_panic
	.align	2
\label:
	b \target
ENDPROC(\label)
.endm

	/* None of these should ever happen */
	invalid_vector	el2t_sync_invalid
	invalid_vector	el2t_irq_invalid
	invalid_vector	el2t_fiq_invalid
	invalid_vector	el2t_error_invalid
	invalid_vector	el2h_sync_invalid
	invalid_vector	el2h_irq_invalid
	invalid_vector	el2h_fiq_invalid
	invalid_vector	el1_sync_invalid
	invalid_vector	el1_irq_invalid
	invalid_vector	el1_fiq_invalid

	.ltorg

	.align 11

ENTRY(__kvm_hyp_vector)
	ventry	el2t_sync_invalid		// Synchronous EL2t
	ventry	el2t_irq_invalid		// IRQ EL2t
	ventry	el2t_fiq_invalid		// FIQ EL2t
	ventry	el2t_error_invalid		// Error EL2t

	ventry	el2h_sync_invalid		// Synchronous EL2h
	ventry	el2h_irq_invalid		// IRQ EL2h
	ventry	el2h_fiq_invalid		// FIQ EL2h
	ventry	el2_error			// Error EL2h

	ventry	el1_sync			// Synchronous 64-bit EL1
	ventry	el1_irq				// IRQ 64-bit EL1
	ventry	el1_fiq_invalid			// FIQ 64-bit EL1
	ventry	el1_error			// Error 64-bit EL1

	ventry	el1_sync			// Synchronous 32-bit EL1
	ventry	el1_irq				// IRQ 32-bit EL1
	ventry	el1_fiq_invalid			// FIQ 32-bit EL1
	ventry	el1_error			// Error 32-bit EL1
ENDPROC(__kvm_hyp_vector)
