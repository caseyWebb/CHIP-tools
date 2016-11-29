#!/bin/bash

TIMEOUT=30
FEL=sunxi-fel
SPLMEMADDR=0x43000000
UBOOTMEMADDR=0x4a000000
UBOOTSCRMEMADDR=0x43100000
nand_erasesize=400000
nand_writesize=4000
nand_oobsize=680

if [[ -z $(which $FEL) ]]; then
  echo "  Error: Unable to locate FEL utility."
  echo "  Install FEL with:"
  echo "  CHIP-SDK setup script      [github.com/NextThingCo/CHIP-SDK]"
  echo "     - or build from source  [github.com/linux-sunxi/sunxi-tools]"
  exit 1
fi

#------------------------------------------------------------
onMac() {
  if [ "$(uname)" == "Darwin" ]; then
    return 0;
  else
    return 1;
  fi
}

#------------------------------------------------------------
filesize() {
  if onMac; then
    stat -f "%z" $1
  else
    stat --printf="%s" $1
  fi
}

#------------------------------------------------------------
wait_for_fastboot() {
  echo -n "waiting for fastboot...";
  for ((i=$TIMEOUT; i>0; i--)) {
    if [[ ! -z "$(fastboot -i 0x1f3a $@ devices)" ]]; then
      echo "OK";
      return 0;
    fi
    echo -n ".";
    sleep 1
  }

  echo "TIMEOUT";
  return 1
}

#------------------------------------------------------------
wait_for_fel() {
  echo -n "waiting for fel...";
  for ((i=$TIMEOUT; i>0; i--)) {
    if ${FEL} $@ ver 2>/dev/null >/dev/null; then
      echo "OK"
      return 0;
    fi
    echo -n ".";
    sleep 1
  }

  echo "TIMEOUT";
  return 1
}

#------------------------------------------------------------
detect_nand() {
  local RC=0

  local tmpdir=`mktemp -d -t chip-uboot-script-XXXXXX`
  local ubootcmds=$tmpdir/uboot.cmds
  local ubootscr=$tmpdir/uboot.scr

  echo "nand info
env export -t -s 0x100 0x7c00 nand_erasesize nand_writesize nand_oobsize
reset" > $ubootcmds
  mkimage -A arm -T script -C none -n "detect NAND" -d $ubootcmds $ubootscr || RC=1

  if ! wait_for_fel; then
    echo "ERROR: please make sure CHIP is connected and jumpered in FEL mode"
    RC=1
    exit 1
  fi

  $FEL spl $IMAGESDIR/sunxi-spl.bin || RC=1
  # wait for DRAM initialization to complete
  sleep 1

  $FEL write $UBOOTMEMADDR $IMAGESDIR/u-boot-dtb.bin || RC=1
  $FEL write $UBOOTSCRMEMADDR $ubootscr || RC=1
  $FEL exe $UBOOTMEMADDR || RC=1

  if ! wait_for_fel; then
    echo "ERROR: please make sure CHIP is connected and jumpered in FEL mode"
    exit 1
  fi

  $FEL read 0x7c00 0x100 $tmpdir/nand-info || RC=1

  echo "NAND detected:"
  cat $tmpdir/nand-info || RC=1
  UBI_TYPE="$(cat $tmpdir/nand-info | awk -F= '/erase/ {print $2}')-$(cat $tmpdir/nand-info | awk -F= '/write/ {print $2}')"
  echo "${UBI_TYPE}" > $IMAGESDIR/ubi_type || RC=1
  source $tmpdir/nand-info || RC=1

  rm -rf $tmpdir

  return $RC
}

#------------------------------------------------------------
flash_images() {
  local RC=0

  local tmpdir=`mktemp -d -t chip-uboot-script-XXXXXX`
  local ubootcmds=$tmpdir/uboot.cmds
  local ubootscr=$tmpdir/uboot.scr
  local ubootsize=`filesize $IMAGESDIR/uboot-$nand_erasesize.bin | xargs printf "0x%08x"`
  local pagespereb=`echo $((nand_erasesize/nand_writesize)) | xargs printf "%x"`
  local sparseubi=$tmpdir/ubi.sparse

  if [ "x$ERASEMODE" = "xscrub" ]; then
    echo "nand scrub.chip -y" > $ubootcmds
  else
    echo "nand erase.chip" > $ubootcmds
  fi

  echo "nand write.raw.noverify $SPLMEMADDR 0x0 $pagespereb" >> $ubootcmds
  echo "nand write.raw.noverify $SPLMEMADDR 0x400000 $pagespereb" >> $ubootcmds
  echo "nand write $UBOOTMEMADDR 0x800000 $ubootsize" >> $ubootcmds
  echo "setenv mtdparts mtdparts=sunxi-nand.0:4m(spl),4m(spl-backup),4m(uboot),4m(env),-(UBI)" >> $ubootcmds
  echo "setenv bootargs root=ubi0:rootfs rootfstype=ubifs rw earlyprintk ubi.mtd=4" >> $ubootcmds
  echo "setenv bootcmd 'gpio set PB2; if test -n \${fel_booted} && test -n \${scriptaddr}; then echo '(FEL boot)'; source \${scriptaddr}; fi; mtdparts; ubi part UBI; ubifsmount ubi0:rootfs; ubifsload \$fdt_addr_r /boot/sun5i-r8-chip.dtb; ubifsload \$kernel_addr_r /boot/zImage; bootz \$kernel_addr_r - \$fdt_addr_r'" >> $ubootcmds
  echo "setenv fel_booted 0" >> $ubootcmds

  echo "echo Enabling Splash" >> $ubootcmds
  echo "setenv stdout serial" >> $ubootcmds
  echo "setenv stderr serial" >> $ubootcmds
  echo "setenv splashpos m,m" >> $ubootcmds

  echo "echo Configuring Video Mode" >> $ubootcmds
  if [ "$FLAVOR" = "pocketchip" ]; then
  
    echo "setenv clear_fastboot 'i2c mw 0x34 0x4 0x00 4;'" >> $ubootcmds
    echo "setenv write_fastboot 'i2c mw 0x34 0x4 66 1; i2c mw 0x34 0x5 62 1; i2c mw 0x34 0x6 30 1; i2c mw 0x34 0x7 00 1'" >> $ubootcmds
    echo "setenv test_fastboot 'i2c read 0x34 0x4 4 0x80200000; if itest.s *0x80200000 -eq fb0; then echo (Fastboot); i2c mw 0x34 0x4 0x00 4; fastboot 0; fi'" >> $ubootcmds

    echo "setenv bootargs root=ubi0:rootfs rootfstype=ubifs rw ubi.mtd=4 quiet lpj=501248 loglevel=3 splash plymouth.ignore-serial-consoles" >> $ubootcmds
    echo "setenv bootpaths 'initrd noinitrd'" >> $ubootcmds
    echo "setenv bootcmd '${NO_LIMIT}run test_fastboot; if test -n \${fel_booted} && test -n \${scriptaddr}; then echo (FEL boot); source \${scriptaddr}; fi; for path in \${bootpaths}; do run boot_\$path; done'" >> $ubootcmds
    echo "setenv boot_initrd 'mtdparts; ubi part UBI; ubifsmount ubi0:rootfs; ubifsload \$fdt_addr_r /boot/sun5i-r8-chip.dtb; ubifsload 0x44000000 /boot/initrd.uimage; ubifsload \$kernel_addr_r /boot/zImage; bootz \$kernel_addr_r 0x44000000 \$fdt_addr_r'" >> $ubootcmds
    echo "setenv boot_noinitrd 'mtdparts; ubi part UBI; ubifsmount ubi0:rootfs; ubifsload \$fdt_addr_r /boot/sun5i-r8-chip.dtb; ubifsload \$kernel_addr_r /boot/zImage; bootz \$kernel_addr_r - \$fdt_addr_r'" >> $ubootcmds
    echo "setenv video-mode" >> $ubootcmds
    echo "setenv dip_addr_r 0x43400000" >> $ubootcmds
    echo "setenv dip_overlay_dir /lib/firmware/nextthingco/chip/early" >> $ubootcmds
    echo "setenv dip_overlay_cmd 'if test -n \"\${dip_overlay_name}\"; then ubifsload \$dip_addr_r \$dip_overlay_dir/\$dip_overlay_name; fi'" >> $ubootcmds
    echo "setenv fel_booted 0" >> $ubootcmds
    echo "setenv bootdelay 1" >> "${UBOOT_SCRIPT_SRC}"
  else

    echo "setenv bootpaths 'initrd noinitrd'" >> $ubootcmds
    echo "setenv bootcmd '${NO_LIMIT}run test_fastboot; if test -n \${fel_booted} && test -n \${scriptaddr}; then echo (FEL boot); source \${scriptaddr}; fi; for path in \${bootpaths}; do run boot_\$path; done'" >> $ubootcmds
    echo "setenv boot_initrd 'mtdparts; ubi part UBI; ubifsmount ubi0:rootfs; ubifsload \$fdt_addr_r /boot/sun5i-r8-chip.dtb; ubifsload 0x44000000 /boot/initrd.uimage; ubifsload \$kernel_addr_r /boot/zImage; bootz \$kernel_addr_r 0x44000000 \$fdt_addr_r'" >> $ubootcmds
    echo "setenv boot_noinitrd 'mtdparts; ubi part UBI; ubifsmount ubi0:rootfs; ubifsload \$fdt_addr_r /boot/sun5i-r8-chip.dtb; ubifsload \$kernel_addr_r /boot/zImage; bootz \$kernel_addr_r - \$fdt_addr_r'" >> $ubootcmds
    echo "setenv dip_addr_r 0x43400000" >> $ubootcmds
    echo "setenv dip_overlay_dir /lib/firmware/nextthingco/chip/early" >> $ubootcmds
    echo "setenv dip_overlay_cmd 'if test -n \"\${dip_overlay_name}\"; then ubifsload \$dip_addr_r \$dip_overlay_dir/\$dip_overlay_name; fi'" >> $ubootcmds

    echo "setenv video-mode sunxi:640x480-24@60,monitor=composite-ntsc,overscan_x=40,overscan_y=20" >> $ubootcmds
  fi

  echo "saveenv" >> $ubootcmds

  echo "echo going to fastboot mode" >> $ubootcmds
  echo "fastboot 0" >> $ubootcmds
  echo "reset" >> $ubootcmds

  mkimage -A arm -T script -C none -n "flash $FLAVOR" -d $ubootcmds $ubootscr || RC=1

  if ! wait_for_fel; then
    echo "ERROR: please make sure CHIP is connected and jumpered in FEL mode"
    RC=1
  fi

  $FEL spl $IMAGESDIR/sunxi-spl.bin || RC=1
  # wait for DRAM initialization to complete
  sleep 1

  $FEL write $UBOOTMEMADDR $IMAGESDIR/uboot-$nand_erasesize.bin || RC=1
  $FEL write $SPLMEMADDR $IMAGESDIR/spl-$nand_erasesize-$nand_writesize-$nand_oobsize.bin || RC=1
  $FEL write $UBOOTSCRMEMADDR $ubootscr || RC=1
  $FEL exe $UBOOTMEMADDR || RC=1

  if wait_for_fastboot; then
    fastboot -i 0x1f3a -u flash UBI $IMAGESDIR/chip-$nand_erasesize-$nand_writesize.ubi.sparse || RC=1
  else
    echo "failed to flash the UBI image"
    RC=1
  fi

  rm -rf $tmpdir

  return $RC
}

#------------------------------------------------------------
wait_for_linuxboot() {
  local TIMEOUT=100
  echo -n "flashing...";
  for ((i=$TIMEOUT; i>0; i--)) {
    if lsusb |grep -q "0525:a4a7" ||
       lsusb |grep -q "0525:a4aa"; then
      echo "OK"
      return 0;
    fi
    echo -n ".";
    sleep 3
  }

  echo "TIMEOUT";
  return 1
}

#------------------------------------------------------------
ready_to_roll() {

  echo -e "\n\nFLASH VERIFICATION COMPLETE.\n\n"

  echo "   #  #  #"
  echo "  #########"
  echo "###       ###"
  echo "  # {#}   #"
  echo "###  '%######"
  echo "  #       #"
  echo "###       ###"
  echo "  ########"
  echo "   #  #  #"

  echo -e "\n\nCHIP is ready to roll!\n\n"

  return 0
}
