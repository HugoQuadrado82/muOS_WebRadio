#!/bin/sh

LOVE_DIR="/mnt/mmc/ports/WebRadio/"
GPTOKEYB="/mnt/mmc/MUOS/emulator/gptokeyb/gptokeyb2"
cd "$GMU_DIR" || exit

export SDL_GAMECONTROLLERCONFIG_FILE="/usr/lib32/gamecontrollerdb.txt"
export LD_LIBRARY_PATH=/mnt/mmc/ports/WebRadio/libs/

$GPTOKEYB "$LOVE_DIR/love" -c "$LOVE_DIR/conf/love.gptk" &
$LOVE_DIR/love $LOVE_DIR/program

kill -9 $(pidof gptokeyb2)