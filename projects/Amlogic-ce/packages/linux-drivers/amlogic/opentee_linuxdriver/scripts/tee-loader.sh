#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2023-present Team CoreELEC (https://coreelec.org)

message() {
  >&2 echo "${@}"
}

VIDEO_UCODE_BIN_PATH=/lib/firmware/video/video_ucode.bin
TEE_SUPPLICANT_PID_FILE=/var/run/tee-supplicant.pid

# run only if SoC is minimum SC2 (0x32) architecture
SERIAL_THIS=$(awk '/^Serial[ \t]*:/ {printf "%d", "0x" substr($3,0,2)}' /proc/cpuinfo)
SERIAL_SC2=$(printf "%d" "0x32")

if [ ${SERIAL_THIS} -lt ${SERIAL_SC2} ]; then
  echo 1 > $(realpath /sys/module/*tee/parameters/disable_flag)
  message "tee not needed (SoC is less than SC2 (0x32) architecture)"
  exit 0
fi

android_wrapper() {
  local android_arch=$(od -An -t x1 -j 4 -N 1 /vendor/bin/tee-supplicant | tr -d '[:space:]')
  local bit64=""
  local arg_exec=""

  [ "${android_arch}" = "02" ] && bit64="64"  # 01 for 32-bit, 02 for 64 bit

  if [ "${1}" = "exec" ]; then
    arg_exec="exec"
    shift
  fi

  LD_LIBRARY_PATH=/system/lib${bit64}/bootstrap:/system/lib${bit64}:/vendor/lib${bit64} \
    ${arg_exec} \
    /system/bin/bootstrap/linker${bit64} \
    ${@}

  return ${?}
}

run_tee_from_coreelec() {
  message "run tee from coreelec start"

  local SOC=$(awk '/SoC[ \t]*:/ {printf "%s", $3}' /proc/cpuinfo)
  if [ -z "${SOC}" ]; then
    message "SoC architecture unknown"
    return 1
  fi

  mkdir -p /var/lib
  ln -sfn /usr/lib/ta/${SOC} /var/lib/teetz
  ln -sfn ${SOC}/video_ucode.bin ${VIDEO_UCODE_BIN_PATH}

  modprobe -q optee_armtz
  tee-supplicant &
  echo ${!} >${TEE_SUPPLICANT_PID_FILE}
  # wait for tee-supplicant process to start
  sleep 5

  tee_preload_fw ${VIDEO_UCODE_BIN_PATH}
  local rv=${?}
  message "run tee from coreelec end"
  return ${rv}
}

run_tee_from_android() {
  message "run tee from android start"
  [ ! -b /dev/mapper/dynpart-vendor_a ] && dmsetup create --concise "$(parse-android-dynparts /dev/super)"
  mountpoint -q /vendor   || mount -o ro /dev/mapper/dynpart-vendor_a /vendor
  mountpoint -q /system_a || mount -o ro /dev/mapper/dynpart-system_a /system_a

  if [ ! -x /vendor/bin/tee-supplicant ]; then
    message "tee-supplicant does not exist on android"
    return 1
  fi

  modprobe -q optee_armtz
  android_wrapper exec /vendor/bin/tee-supplicant &
  echo ${!} >${TEE_SUPPLICANT_PID_FILE}
  # wait for tee-supplicant process to start
  sleep 5

  android_wrapper /vendor/bin/tee_preload_fw /vendor${VIDEO_UCODE_BIN_PATH}
  local rv=${?}
  message "run tee from android end"
  return ${rv}
}

cleanup() {
  message "cleanup tee start"
  if [ -r ${TEE_SUPPLICANT_PID_FILE} ]; then
    kill -KILL $(cat ${TEE_SUPPLICANT_PID_FILE})
    rm -f ${TEE_SUPPLICANT_PID_FILE}
  fi

  modprobe -r optee_armtz

  mountpoint -q /vendor   && umount /vendor
  mountpoint -q /system_a && umount /system_a
  [ -b /dev/mapper/dynpart-vendor_a ] && dmsetup remove /dev/mapper/dynpart-*
  message "cleanup tee end"
}

case "${1}" in
  start)
    if [ -b /dev/super ]; then
      run_tee_from_android
      [ ${?} -eq 0 ] && exit 0

      message "using tee from android failed, trying from coreelec"
      cleanup
    fi

    run_tee_from_coreelec
    [ ${?} -eq 0 ] && exit 0

    cat > /tmp/tee.message << 'EOF'
[TITLE]CoreELEC Media Playback[/TITLE]
[B][COLOR red]Missing partition 'super' on eMMC![/COLOR][/B]
[COLOR red]No media playback possible![/COLOR]

Current Android installed on eMMC does not have 'super' partition which is required for media playback in CoreELEC. Android must be reinstalled on your device to satisfy the requirements.

If you have a CoreELEC internal install by the tool 'ceemmc' it is possible to perform the internal install again after Android is restored.

Please ensure you have done a backup of your data before perform any recovery step.
EOF

    message "using tee from coreelec failed"
    cleanup
    ;;
  stop)
    cleanup
    ;;
esac