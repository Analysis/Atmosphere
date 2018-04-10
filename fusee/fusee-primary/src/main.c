#include "utils.h"
#include "hwinit.h"
#include "fuse.h"
#include "se.h"
#include "sdmmc.h"
#include "sd_utils.h"
#include "stage2.h"
#include "lib/printk.h"
#include "display/video_fb.h"

/* TODO: Should we allow more than 32K for the BCT0? */
#define BCT0_LOAD_ADDRESS (uintptr_t)(0x40038000)
#define BCT0_LOAD_END_ADDRESS (uintptr_t)(0x4003F000)
#define MAGIC_BCT0 0x30544342

#define DEFAULT_BCT0_FOR_DEBUG "BCT0\n[stage1]\nstage2_file = stage2.bin\nstage2_addr = 0xFFF00000\nstage2_entrypoint = 0xCAFEBABE\n"

const char *load_config(void) {
    if (!read_sd_file((void *)BCT0_LOAD_ADDRESS, BCT0_LOAD_END_ADDRESS - BCT0_LOAD_ADDRESS, "BCT.ini")) {
        printk("Failed to read BCT0 from SD!\n");
        printk("[DEBUG] Using default BCT0!\n");
        memcpy((void *)BCT0_LOAD_ADDRESS, DEFAULT_BCT0_FOR_DEBUG, sizeof(DEFAULT_BCT0_FOR_DEBUG));
        /* TODO: Stop using default. */
        /* printk("Error: Failed to load BCT.ini!\n");
         * generic_panic(); */
    }
    
    if ((*((u32 *)(BCT0_LOAD_ADDRESS))) != MAGIC_BCT0) {
        printk("Error: Unexpected magic in BCT.ini!\n");
        generic_panic();
    }
    /* Return pointer to first line of the ini. */
    const char *bct0 = (const char *)BCT0_LOAD_ADDRESS;
    while (*bct0 && *bct0 != '\n') {
        bct0++;
    }
    if (!bct0) {
        printk("Error: BCT.ini has no newline!\n");
        generic_panic();
    }
    return bct0;
}

void load_sbk(void) {
    uint32_t sbk[0x4];
    /* Load the SBK into the security engine, if relevant. */
    memcpy(sbk, (void *)get_fuse_chip_regs()->FUSE_PRIVATE_KEY, 0x10);
    for (unsigned int i = 0; i < 4; i++) {
        if (sbk[i] != 0xFFFFFFFF) {
            set_aes_keyslot(0xE, sbk, 0x10);
            break;
        }
    }
}

int main(void) {
    //stage2_entrypoint_t stage2_entrypoint;
    //void **stage2_argv = (void **)(BCT0_LOAD_END_ADDRESS);
    const char *bct0;
    u32 *lfb_base;
    
    (void)(bct0);

    /* Initialize DRAM. */
    /* TODO: What can be stripped out to make this minimal? */
    nx_hwinit();
    
    /* Initialize the display. */
    display_init();
    
    /* Register the display as a printk provider. */
    lfb_base = display_init_framebuffer();
    video_init(lfb_base);
    
    /* Turn on the backlight after initializing the lfb */
    /* to avoid flickering. */
    display_enable_backlight(true);
    
    /* Say hello. */
    printk("Welcome to Atmosph\xe8re Fus\xe9" "e! SDMMC Development Edition!\n");
    printk("Using color linear framebuffer at 0x%p!\n", lfb_base);
    
    sdmmc1_init();

    printk("Performed sdmmc1_init");

    return 0;
}

