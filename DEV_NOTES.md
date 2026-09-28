# SDL-Ball PortMaster port -- developer notes

Build/technical reference for anyone maintaining or rebuilding this port. Not shipped to players; see `sdlball/sdlball.md` for that.

## What this is

SDL-Ball 1.04, a 2008-era SDL 1.2 + fixed-function OpenGL Arkanoid/Breakout clone. Source ships with a working Linux `Makefile` already, so this is a genuine native aarch64 build, not a Wine/box64 port -- same shape as this project's `egoboo` port.

## Build environment

Built inside `/opt/arm64chroot` (a real aarch64 Ubuntu 20.04 rootfs run via `qemu-aarch64-static`), same chroot as every other native port in this project. Plain `apt install` there installs native aarch64 packages directly.

```
apt-get install -y libsdl1.2-dev libsdl-image1.2-dev libsdl-mixer1.2-dev libsdl-ttf2.0-dev libgl1-mesa-dev libglu1-mesa-dev
cd src && make
```

No Makefile fixes needed (unlike Egoboo's missing `-lm`) -- compiled clean on the first try.

### SDL 1.2 itself -- sdl12-compat, reused directly from the egoboo port

ROCKNIX ships no SDL 1.2 at all (only SDL2/SDL3). Linked against Ubuntu's real `libsdl1.2-dev` headers at build time, but the port **ships** the chroot's already-built `sdl12-compat` as `libs.aarch64/libSDL-1.2.so.0` -- byte-identical reuse of the exact file already verified working by the `egoboo` port (same chroot, same package versions). Never bundle a real SDL2 alongside this shim (standard project rule).

### `libs.aarch64/` -- reused wholesale from `egoboo`, not rebuilt

`libSDL-1.2.so.0`, `libSDL_image-1.2.so.0`, `libSDL_ttf-2.0.so.0`, `libSDL_mixer-1.2.so.0` (Egoboo's WAVE+OGG-only trimmed build -- SDL-Ball's own audio is 100% OGG samples via `Mix_LoadWAV`, no music at all, so the trim applies identically), `libtiff.so.5`, `libjbig.so.0`, `libwebp.so.6` (SDL_image transitive deps not on-device). Skipped `libphysfs.so.1` (Egoboo needed it, SDL-Ball's Makefile never links `-lphysfs`). `libGLU.so.1` needs no bundling -- confirmed already present with a matching SONAME on both target devices.

### `gl4es.aarch64/` -- reused as-is from `egoboo`

Same binaries (`libGL.so.1`/`libEGL.so.1`), same architecture, same "fixed-function desktop GL, no native GLES path" shape (`glBegin`/`glOrtho`/`gluPerspective` throughout `main.cpp`/`background.cpp`/`effects.cpp`). No separate gl4es build needed.

## Source patches (all in `Port/build-src/`, the actual build tree -- the `Installer/` folder is the original untouched upstream source dump)

1. **`main.cpp`: `setting.joyEnabled` default changed `1` -> `0`.** gptokeyb2 translates the real gamepad into synthetic keyboard events without exclusively grabbing the raw joystick device, so the game's own native `SDL_JoystickOpen(0)` reading would double every input -- identical bug class to the one fixed in the `egoboo` port.

2. **Three separate OpenGL display lists removed, replaced with plain immediate-mode functions** (`title.cpp`'s `glTitleList`, `main.cpp`'s `sceneDL`/`mkDLscene`, `menu.cpp`'s four `dl`/`dl+1..3` lists). Real on-device root cause, found via a live `bt full` backtrace: gl4es's `glCallList` segfaults inside Mesa's gallium driver on this hardware (`libgallium-26.1.2.so`) -- confirmed crash at `title.cpp:281`, then again at `main.cpp:998` (border list) and would have hit the pause-menu lists next. None of these lists had any per-frame-varying content (each was just 1-32 static textured quads recorded once at init), so replacing `glNewList`/`glCallList` with a plain function that issues the identical GL calls directly every frame is functionally identical and sidesteps gl4es's broken display-list path entirely. **If gl4es is ever swapped for a different GL translation layer on this project, re-check whether display lists are safe again** -- this was a real, reproducible driver bug, not a design choice, and the workaround has zero cost either way so there's no reason to revert it regardless.

## OmniOSK on-screen keyboard -- the sdl12-compat bridge

SDL-Ball needs real text entry (highscore name field, `highscores.cpp`/`menu.cpp`). The project's existing OmniOSK (`_readonly/OmniOSK`) only supported genuine SDL2 apps or SDL2-reached-through-sdl12-compat apps whose *rendering* the library could hook via SDL2-named functions (`SDL_CreateWindow`, `SDL_GL_SwapWindow`, `SDL_RenderPresent`, etc.) -- none of which an SDL 1.2 game ever calls. **This port is the first in the project to need OmniOSK against a straight SDL 1.2 game**, so a new build mode (`OMNI_SDL12_BRIDGE`) was built specifically for it. Full source at `_readonly/OmniOSK-sdl12bridge/`, built artifact at `_readonly/OmniOSK/libomni_osk_sdl12bridge.aarch64.so`, copied into `libs.aarch64/libomni_osk.so`.

### Why this needed real new engineering, not just a recipe

SDL 1.2 and SDL2 export several identically-named C symbols (`SDL_Init`, `SDL_PollEvent`, `SDL_WaitEvent`, `SDL_PushEvent`, `SDL_PeepEvents`, ...) with **incompatible `SDL_Event` struct layouts** (SDL 1.2: 24 bytes, `Uint8 type`; SDL2: 56 bytes, `Uint32 type`). The existing OmniOSK (`preload.c`) is compiled against real SDL2 headers throughout. LD_PRELOADing it as-is into an SDL 1.2 game means its `SDL_PollEvent` hook reads/writes the game's 24-byte stack-allocated event using SDL2 field offsets -- real stack corruption, not a theoretical concern (this is exactly what caused the earliest on-device crashes before the bridge existed).

The fix: split into two translation units.
- `sdl12_shim.c` -- compiled with **only** real SDL 1.2 headers. Exports every SDL-1.2-ABI-shaped hook (`SDL_PollEvent`, `SDL_WaitEvent`, `SDL_PushEvent`, `SDL_PeepEvents`, `SDL_GetKeyState`, `SDL_UpdateRect`/`UpdateRects`/`Flip`, `SDL_GL_SwapBuffers`), resolving the real next-in-chain implementation via `dlsym(RTLD_NEXT, ...)`. Never touches a caller's `SDL_Event*` with anything but real SDL 1.2 layout; translates keyboard events to/from plain primitives (a key-name string, pressed/released, ASCII value) at the boundary.
- `sdl12_bridge.c` -- compiled with real SDL2 headers, alongside the existing ABI-agnostic shared core (`runtime.c`/`osk_model.c`/`render_gl.cpp`/`render_sdlrenderer.cpp`/`imgui_bridge.cpp`/`config.c`/`charset.c`/`generated_events.c`/`diagnostics.c`, all reused unmodified). Does the real key-name translation (SDL 1.2's own `SDL_GetKeyName()` -> SDL2's `SDL_GetKeyFromName()`), window/context discovery, and drives the shared model.

### Real bugs found and fixed during bring-up (all confirmed on real X55 hardware, not just reasoning)

1. **Window/renderer discovery.** An SDL 1.2 game never calls `SDL_CreateWindow`/`SDL_CreateRenderer` (names don't exist in SDL 1.2), so the normal discovery hooks never fire. Fixed via real SDL2's `SDL_GetKeyboardFocus()` (finds the window `sdl12-compat` created internally) + `SDL_GetRenderer()`/`SDL_GL_GetCurrentContext()`. Confirmed empirically that a normal build-time `NEEDED` link against `libSDL2-2.0.so.0` resolves to the *same* loaded SDL2 instance `sdl12-compat`'s own private `RTLD_LOCAL dlopen` uses (ELF loads a given SONAME once per process regardless of how many different loaders reference it) -- no `dlopen(..., RTLD_NOLOAD)` fallback needed.
2. **SDL-Ball is OpenGL, not software-surface.** Initial bridge only hooked `SDL_UpdateRect`/`UpdateRects`/`Flip` (the SDL 1.2 software-surface present calls); SDL-Ball calls `SDL_GL_SwapBuffers()` instead, so the overlay could never find a presentation target at all. Added a dedicated `SDL_GL_SwapBuffers` hook mirroring the existing non-bridge `SDL_GL_SwapWindow` hook's draw-then-always-swap shape (no anti-flicker suppression needed for GL, unlike the SDL_Renderer path -- the swap *is* the only presentation mechanism).
3. **`SDL_Quit` teardown gap** caused a real on-device exit hang under the GL path (found via a real GL smoke test using the chroot's `SDL_VIDEODRIVER=offscreen`/llvmpipe support) -- fixed by mirroring the non-bridge `SDL_Quit` hook's teardown ordering.
4. **`gptokeyb2`'s `"enter"` token is not a valid confirm-key match.** Real SDL 1.2 names `SDLK_KP_ENTER` as `"enter"` (distinct from `SDLK_RETURN`'s `"return"`); real SDL2 names the equivalent scancode `"Keypad Enter"` -- a different string, not a case difference. `SDL_GetKeyFromName("enter")` against real SDL2 returned `SDLK_UNKNOWN`, so the OSK's confirm action silently never fired at all. Fixed with a small alias table (`"enter"`/`"return"` both map to `SDLK_RETURN`) in `sdl12_bridge.c`.
5. **Typed text never reached the game's actual name field.** SDL-Ball reads typed characters from the **real event queue** (`highscores.cpp:75`, `menu.cpp:258`, both check `e.key.keysym.unicode`), not from `SDL_GetKeyState()` polling -- the opposite of the "most SDL 1.2-era games poll raw key state" assumption the original design (correctly) targeted for *gameplay* controls. The OSK's submitted/typed characters needed a second delivery path: synthesized real SDL 1.2 `SDL_KEYDOWN`/`KEYUP` events (proper `.unicode` field set, `.sym` set to `SDLK_BACKSPACE`/`SDLK_RETURN` for those two) injected into `sdl12_shim.c`'s own `SDL_PollEvent`/`WaitEvent`/`PeepEvents` loops, checked only after the real queue comes up empty -- mirrors the non-bridge `preload.c`'s own `omni_runtime_pop_generated` pattern as closely as possible. Also handles uppercase/shifted characters correctly: the shared model encodes those as a base lowercase keysym + `KMOD_SHIFT` + a synthetic `SDLK_LSHIFT` pair, not a distinct keysym per character, so the bridge reconstructs the real ASCII value from keysym+modifier before setting `.unicode`.

All five were confirmed with either a real on-device test or a real chroot-side smoke test exercising the actual code path (not just static reasoning) before being called fixed.

## Known open issue: first-launch-after-any-rebuild crash (NOT fixed, documented instead)

**100% consistent across many repeated tests**: the very first launch of a freshly-deployed build (new binary or new `libomni_osk.so`) crashes with a plain SIGSEGV right after `Read 50 levels from 'themes/default/levels.txt'` prints -- i.e. exactly at the title-screen-dismiss -> gameplay-start transition, regardless of which button/action triggers that transition. **Every subsequent launch of the identical, unchanged build is clean** -- confirmed repeatedly, including a full 3-level playthrough with zero further issues.

What's been ruled out:
- Not present at all without the OmniOSK bridge loaded -- extensively confirmed clean across many real launches of the plain (pre-bridge) build through this exact transition, before the bridge existed.
- Not a `settings.cfg`/save-file corruption issue -- `conf/` was never wiped between test rounds, the pattern held regardless.
- A live `gdb -batch -ex run -ex "bt full"` attached to the unstripped debug binary has **never once caught it** across several real attempts, including immediately after a fresh redeploy where the plain (no-gdb) release binary had just crashed moments before at the identical transition. Classic signature of a driver-level timing/scheduling race that gdb's overhead perturbs away, not a deterministic logic bug in this port's own code.
- One specific, well-reasoned candidate was ruled out: a per-frame `SDL_GL_GetCurrentContext()` call (added defensively in `ensure_gl_target()` during an earlier round, to guard against a *hypothetical* stale-context-across-a-level-transition scenario that was never actually confirmed) was suspected as the only every-frame call into the real GL/EGL driver purely because the bridge is loaded -- reverted to a cache-once check. Re-tested on real hardware: crash still reproduces identically. Ruled out, not the cause.

Leading (unconfirmed) theory: a one-time cold-cache shader compile inside gl4es itself, triggered the first time gameplay-specific GL state (new texture/blend combinations the title screen never exercises -- bricks, powerups, borders) gets touched in a fresh process, racing against something the bridge does every frame regardless of whether the overlay is ever opened (at minimum: `SDL_GL_SwapBuffers` itself, the real swap call, unconditional and irreducible). Not confirmed, and may not be practically fixable from this port's or even OmniOSK's side if the actual race is inside gl4es/Mesa/Panfrost.

**Decision: document and ship, do not keep chasing.** Practical impact on a real player is minimal and self-resolving (one crash on first-ever launch after install, permanently fine after a single relaunch) -- noted in `testing_thread.txt` for testers. Worth revisiting only if gl4es itself is ever patched/upgraded, or if someone finds a way to get a live backtrace without perturbing the timing (e.g. a crash-time coredump with a hardware watchpoint set up in advance, rather than a live-attached `gdb run`) -- `ulimit -c unlimited` plus a real `core_pattern` was set up for this during investigation but never actually caught a non-empty core (rlimit propagation issue through the launch script chain, itself unresolved and probably fixable with more effort if this is picked back up).

## Controls

Button layout: A = shoot/confirm (`mouse_left`, doubles as menu-item click since SDL-Ball's own pause menu is mouse-driven), B = pause/menu (`esc`), X = buy powerup in the between-level shop (`mouse_right`), L1 = screenshot. Left analog = `mouse_movement` (the game's own preferred paddle-control method per its README, also drives menu hover). D-pad left/right = digital paddle move (`left`/`right` arrow keys, matches the game's own keyboard scheme). D-pad up = alt shoot (`up` arrow, matches `keyShoot` default). D-pad down = bound to `"down"` purely so the OSK can navigate downward once open -- the base game has no down-key concept at all, so this is a dead binding during normal gameplay, not a real control.

OmniOSK: Select+D-Pad-Down (via `hold_state osk`) sends F12 (`OMNI_TOGGLE_KEY` default) to open/close the keyboard. Y = confirm (`"enter"` gptokeyb2 token -- see bridge bug #4 above for why this needed a real fix, not just a different token choice). R1 = backspace.

## R36S -- confirmed working, one perf tweak

Ran clean, no crashes, every fix above (display lists, OSK bridge) holding identically on the R36S's Mali-G31/Panfrost stack. First launch after deploy did **not** crash there (unlike the X55's repeated pattern) -- consistent with the first-launch issue being genuinely non-deterministic/timing-based rather than something that reproduces on every device.

**Perf**: R36S (RK3326) is roughly 2-3x slower than the X55 (RK3566) on this project's other ports, and real-hardware testing showed SDL-Ball's particle-heavy brick-burst effects get noticeably sluggish there. `SDL-Ball.sh` now pre-seeds `settings.cfg` with `eyecandy=0` on the very first launch **only when `$DEVICE_NAME = "R36S"`** (device_info.txt's own device-detection case statement, sourced via `control.txt`) -- SDL-Ball's own in-game Settings menu reads/writes this same file from then on, so this never overrides a player's own later choice, it only changes what a first run starts with. Confirmed working after the fix; player can turn eye candy back on in Settings if they prefer the look over the framerate.

**Gotcha hit during this test, worth remembering for any future SSH-based testing on this device (or any ROCKNIX device)**: `pkill -9 -x sdl-ball.aarch64` **silently never matches**, because Linux truncates `/proc/PID/comm` to 15 characters -- the real comm name is `sdl-ball.aarch6`. This isn't specific to this port; it'll bite any binary whose basename is 16+ characters. Ran two full game instances simultaneously for a while as a result (a stale one from an earlier test round the `pkill` was supposed to have killed, plus a freshly-launched second one) before catching it via `ps aux` showing two `sdl-ball.aarch64` rows with different start times -- worth double-checking `cat /proc/<pid>/comm` (or just killing by explicit PID) rather than trusting a `pkill -x` on a long binary name silently "succeeding" (exit 1 from `pkill` when it matches nothing looks identical to "already dead").

## Known follow-ups (not yet done)

- `cover.png` not made yet.
- The first-launch crash above (documented, not fixed -- see that section).
- `SDL-Ball-dbg.sh`/`SDL-Ball-core.sh` (debug/core-dump launch script variants used only for this investigation) are not part of the shipped port `items` list and can be deleted before submission, or left as maintainer tooling -- your call.
