/* For some reason GAS doesn't know about it, even with .cpu cortex-a57 */
#define cpuactlr_el1 s3_1_c15_c2_0
#define cpuectlr_el1 s3_1_c15_c2_1

.macro      RESET_CORE
    mov  x0, #(1 << 63)
    msr  cpuactlr_el1, x0 /* disable regional clock gating */
    isb
    mov  x0, #3
    msr  rmr_el3, x0
    isb
    dsb  sy
    /* Nintendo forgot to copy-paste the branch instruction below. */
    1:
        wfi
        b 1b
.endm

.macro      ERRATUM_INVALIDATE_BTB_AT_BOOT
/* Nintendo copy-pasted https://github.com/ARM-software/arm-trusted-firmware/blob/master/plat/nvidia/tegra/common/aarch64/tegra_helpers.S#L312 */
        /*
        * Copyright (c) 2015-2017, ARM Limited and Contributors. All rights reserved.
        *
        * SPDX-License-Identifier: BSD-3-Clause
        */
    /* The following comments are mine. */
    /* mask all interrupts */
    msr daifset, 0b1111

    /*
        Enable invalidates of branch target buffer, then flush
        the entire instruction cache at the local level, and
        with the reg change, the branch target buffer, then disable
        invalidates of the branch target buffer again.
    */
    mrs  x0, cpuactlr_el1
    orr  x0, x0, #1
    msr  cpuactlr_el1, x0

    dsb  sy
    isb
    ic   iallu
    dsb  sy
    isb

    mrs  x0, cpuactlr_el1
    bic  x0, x0, #1
    msr  cpuactlr_el1, x0

.rept 7
    nop                     /* wait long enough for the write to cpuactlr_el1 to have completed */
.endr

    /* if the OS lock is set, disable it and request a warm reset */
    mrs  x0, oslsr_el1
    ands x0, x0, #2
    b.eq 2f
    mov  x0, xzr
    msr  oslar_el1, x0

    RESET_CORE

.rept 65
    nop                     /* guard against speculative excecution */
.endr

    2:
    /* set the OS lock */
    mov  x0, #1
    msr  oslar_el1, x0
.endm

.section    .cold_crt0.text.start, "ax", %progbits
.align      6
.global     __start_cold
__start_cold:
    ERRATUM_INVALIDATE_BTB_AT_BOOT

    msr  spsel, #0
    bl   get_coldboot_crt0_stack_address
    mov  sp, x0
    mov  fp, #0

    adrp x19, g_coldboot_crt0_relocation_list
    add  x19, x19, #:lo12:g_coldboot_crt0_relocation_list
    mov  x0, x19
    bl   coldboot_init

    ldr  x16, =__jump_to_main_cold
    br   x16

.section    .warm_crt0.text.start, "ax", %progbits
.align      6
.global     __start_warm
__start_warm:
    ERRATUM_INVALIDATE_BTB_AT_BOOT

    /* For some reasons, Nintendo uses spsel, #1 here, causing issues if an exception occurs */
    msr  spsel, #0
    bl   get_warmboot_crt0_stack_address
    mov  sp, x0
    mov  fp, #0

    adrp x0, g_warmboot_crt0_main_func_list
    add  x0, x0, #:lo12:g_warmboot_crt0_main_func_list
    bl   warmboot_init
    ldr  x16, =__jump_to_main_warm
    br   x16

/* Used by coldboot as well */
.section    .warm_crt0.text.__set_memory_registers, "ax", %progbits
.global     __set_memory_registers
.type       __set_memory_registers, %function
__set_memory_registers:
    msr  cpuectlr_el1, x2
    isb
    msr  scr_el3, x3
    msr  ttbr0_el3, x0
    msr  tcr_el3, x4
    msr  cptr_el3, x5
    msr  mair_el3, x6
    msr  vbar_el3, x1

    /* Invalidate the entire TLB on the Inner Shareable domain */
    isb
    dsb  ish
    tlbi alle3is
    dsb  ish
    isb

    msr  sctlr_el3, x7
    isb
    ret

.section    .text.__jump_to_main_cold, "ax", %progbits
.align      4
__jump_to_main_cold:
    /* This is inspired by Nintendo's code but significantly different */
    bl   __set_exception_entry_stack_pointer
    /*
        Normally Nintendo calls it in crt0, but it's fine to do that here.
        Please note that package2.c shouldn't have constructed objects, because we
        call __libc_fini_array after load_package2 has been cleared, on EL3
        to EL3 chainload.
    */
    bl   __libc_init_array

    bl   get_pk2ldr_stack_address
    mov  sp, x0

    bl   load_package2

    mov  w0, #3 /* use core3 stack temporarily */
    bl   get_exception_entry_stack_address
    mov  sp, x0
    bl   coldboot_main
    /* If we ever return, it's to chainload an EL3 payload */
    bl   __libc_fini_array
    /* Reset the core (only one is running on coldboot) */
    RESET_CORE

.section    .text.__jump_to_main_warm, "ax", %progbits
__jump_to_main_warm:
    /* Nintendo doesn't do that here, causing issues if an exception occurs */
    bl   __set_exception_entry_stack_pointer

    bl   get_pk2ldr_stack_address
    mov  sp, x0
    bl   load_package2

    mov  w0, #3 /* use core0,1,2 stack bottom + 0x800 (VA of warmboot crt0 sp) temporarily */
    bl   get_exception_entry_stack_address
    add  sp, x0, #0x800
    b    warmboot_main

.section    .text.__set_exception_entry_stack, "ax", %progbits
.type       __set_exception_entry_stack, %function
.global     __set_exception_entry_stack
__set_exception_entry_stack_pointer:
    /* If SPSel == 1 on entry, make sure your function doesn't use stack variables! */
    mov  x16, lr
    mrs  x17, spsel
    mrs  x0, mpidr_el1
    and  w0, w0, #3
    bl   get_exception_entry_stack_address
    msr  spsel, #1
    mov  sp, x0
    msr  spsel, x17
    mov  lr, x16
    ret

.section    .text.__jump_to_lower_el, "ax", %progbits
.global     __jump_to_lower_el
.type       __jump_to_lower_el, %function
__jump_to_lower_el:
    /* x0: arg (context ID), x1: entrypoint, w2: exception level */
    msr  elr_el3, x1

    mov  w1, #(0b1111 << 6 | 1) /* DAIF set and SP = SP_ELx*/
    orr  w1, w2, w2, lsl#2
    msr  spsr_el3, x1

    bl __set_exception_entry_stack_pointer

    isb
    eret

/* Custom stuff */
.section    .cold_crt0.data.g_coldboot_crt0_relocation_list, "aw", %progbits
.align      3
.global     g_coldboot_crt0_relocation_list
g_coldboot_crt0_relocation_list:
    .quad   0, __loaded_end_lma__  /* __start_cold, to be set & loaded size */
    .quad   1, 5                   /* number of sections to relocate/clear before & after mmu init */
    .quad   g_warmboot_crt0_main_func_list
    /* Relocations */
    .quad   __warmboot_crt0_start__, __warmboot_crt0_end__, __warmboot_crt0_lma__
    .quad   __main_start__, __main_bss_start__, __main_lma__
    .quad   __pk2ldr_start__, __pk2ldr_bss_start__, __pk2ldr_lma__
    .quad   __vectors_start__, __vectors_end__, __vectors_lma__
    /* BSS clears */
    .quad   __main_bss_start__, __main_end__, 0
    .quad   __pk2ldr_bss_start__, __pk2ldr_end__, 0

.section    .warm_crt0.data.g_warmboot_crt0_main_func_list, "aw", %progbits
.align      3
.global     g_warmboot_crt0_main_func_list
g_warmboot_crt0_main_func_list:
    .quad   3   /* Number of functions */
    /* Functions */
    .quad   set_memory_registers_enable_mmu
    .quad   flush_dcache_all
    .quad   invalidate_icache_all
