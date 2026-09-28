#!/bin/bash

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}

if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
else
  controlfolder="/roms/ports/PortMaster"
fi

source $controlfolder/control.txt
get_controls

GAMEDIR=/$directory/ports/sdlball
BINARY=sdl-ball.${DEVICE_ARCH}

mkdir -p "$GAMEDIR/conf"
cd $GAMEDIR

> "$GAMEDIR/log.txt" && exec > >(tee "$GAMEDIR/log.txt") 2>&1

# SDL-Ball saves settings/highscores/screenshots under $HOME/.config/sdl-ball --
# point HOME at the port's own conf/ folder so it stays self-contained instead
# of writing into the real device $HOME, same convention as other native ports
# in this project. Resolution is never hardcoded here: SDL-Ball only writes
# resx/resy into settings.cfg once the player explicitly changes it (F11 or an
# in-game option); with no settings.cfg on first run it auto-detects the real
# desktop/current video mode (main.cpp's SDL_GetVideoInfo()->current_w/h) and
# launches fullscreen at that native resolution on its own.
export HOME="$GAMEDIR/conf"

# R36S (RK3326) is roughly 2-3x slower than the X55 (RK3566) on this project's
# other ports, and real-hardware testing showed SDL-Ball's particle-heavy
# brick-burst effects get noticeably sluggish there. Pre-seed a lighter
# default (eye candy off) on the very first launch only -- SDL-Ball's own
# Settings menu (in-game) reads/writes this same file from then on, so this
# never overrides a player's own later choice, it only changes what a first
# run starts with. R36S can already start the game fine without this; it's
# purely a performance default, not a compatibility fix.
SETTINGSCFG="$HOME/.config/sdl-ball/settings.cfg"
if [ "$DEVICE_NAME" = "R36S" ] && [ ! -f "$SETTINGSCFG" ]; then
  mkdir -p "$(dirname "$SETTINGSCFG")"
  echo "eyecandy=0" > "$SETTINGSCFG"
fi

export LD_LIBRARY_PATH="$GAMEDIR/libs.${DEVICE_ARCH}:$LD_LIBRARY_PATH"
export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"

if [ -f "${controlfolder}/libgl_${CFW_NAME}.txt" ]; then
  source "${controlfolder}/libgl_${CFW_NAME}.txt"
elif [ -f "${controlfolder}/libgl_default.txt" ]; then
  source "${controlfolder}/libgl_default.txt"
fi

# SDL-Ball's renderer (background.cpp/effects.cpp/main.cpp) is fixed-function
# desktop GL only (glBegin/glOrtho/gluPerspective) -- no native GLES path, same
# shape as this project's egoboo port, which needed gl4es unconditionally even
# on Panfrost hardware that otherwise reports real desktop GL to a generic
# capability probe. gl4es.$DEVICE_ARCH must be on LD_LIBRARY_PATH itself, not
# just referenced by absolute path below: gl4es's own libEGL.so.1 has a bare
# ELF NEEDED on libGL.so.1, which without this on the search path resolves to
# the system's real Mesa libGL.so.1 instead of gl4es's paired one, breaking
# gl4es's EGL init from the inside (confirmed on real hardware during egoboo).
if [ -d "$GAMEDIR/gl4es.${DEVICE_ARCH}" ]; then
  export LD_LIBRARY_PATH="$GAMEDIR/gl4es.${DEVICE_ARCH}:$LD_LIBRARY_PATH"
  export SDL_VIDEO_GL_DRIVER="$GAMEDIR/gl4es.${DEVICE_ARCH}/libGL.so.1"
  export SDL_VIDEO_EGL_DRIVER="$GAMEDIR/gl4es.${DEVICE_ARCH}/libEGL.so.1"
fi

# OmniOSK on-screen keyboard, for the highscore name-entry prompt. SDL-Ball is
# an SDL 1.2 game running through the sdl12-compat shim, so this must be the
# sdl12-compat-bridge build of libomni_osk.so, not the plain SDL2 variant --
# see licenses/LICENSE-OmniOSK.txt. Select+D-Pad Down (sdlball.ini) sends the
# default OMNI_TOGGLE_KEY (F12). LD_PRELOAD is set bare/unexported and only on
# the game's own launch line, after gptokeyb2 is already running -- exporting
# it would leak into gptokeyb2's own process, which links its own real SDL2
# for joystick reading, and a second SDL pulled in via preload breaks that.
export OMNI_MODE=buffered
export OMNI_EVENT_MODE=auto

$GPTOKEYB2 "$BINARY" -c "$GAMEDIR/sdlball.ini" &

pm_platform_helper "$GAMEDIR/$BINARY"

LD_PRELOAD="$GAMEDIR/libs.${DEVICE_ARCH}/libomni_osk.so${LD_PRELOAD:+:$LD_PRELOAD}" ./$BINARY

pm_finish
