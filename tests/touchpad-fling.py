#!/usr/bin/env python3
"""Synthetic touchpad fling — drives kitty's X11 momentum-scroll path.

Creates a uinput device whose evdev capabilities mirror
libinput's `litest-device-synaptics-rmi4` test fixture so the udev
`input_id` builtin tags it ID_INPUT_TOUCHPAD=1; libinput then
dispatches it as a touchpad and xf86-input-libinput attaches it
with a SmoothScroll valuator. Then performs a fast 2-finger upward
swipe that lifts while still moving — the lift-while-moving phase
seeds kitty's momentum scroller via glfw_handle_scroll_event_for_momentum.

References:
  glfw/x11_init.c::read_xi_scroll_devices       — is_finger_based gate
  glfw/x11_window.c::handle_xi_motion_event     — is_highres gate
  glfw/momentum-scroll.c                        — fling state machine
"""

import argparse
import os
import time

from evdev import UInput, AbsInfo, ecodes as e


CAPS = {
    e.EV_KEY: [
        e.BTN_LEFT,
        e.BTN_TOUCH,
        e.BTN_TOOL_FINGER,
        e.BTN_TOOL_DOUBLETAP,
        e.BTN_TOOL_TRIPLETAP,
        e.BTN_TOOL_QUADTAP,
        e.BTN_TOOL_QUINTTAP,
    ],
    e.EV_ABS: [
        (e.ABS_X,            AbsInfo(0, 0, 1940, 0, 0, 20)),
        (e.ABS_Y,            AbsInfo(0, 0, 1062, 0, 0, 20)),
        (e.ABS_PRESSURE,     AbsInfo(0, 0, 255,  0, 0, 0)),
        (e.ABS_MT_SLOT,         AbsInfo(0, 0, 4,     0, 0, 0)),
        (e.ABS_MT_TRACKING_ID,  AbsInfo(0, 0, 65535, 0, 0, 0)),
        (e.ABS_MT_POSITION_X,   AbsInfo(0, 0, 1940,  0, 0, 20)),
        (e.ABS_MT_POSITION_Y,   AbsInfo(0, 0, 1062,  0, 0, 20)),
        (e.ABS_MT_PRESSURE,     AbsInfo(0, 0, 255,   0, 0, 0)),
        (e.ABS_MT_TOUCH_MAJOR,  AbsInfo(0, 0, 100,   0, 0, 0)),
        (e.ABS_MT_TOUCH_MINOR,  AbsInfo(0, 0, 100,   0, 0, 0)),
        (e.ABS_MT_ORIENTATION,  AbsInfo(0, -1, 1,    0, 0, 0)),
    ],
}


def fling(ui, *, start_xs=(800, 1100), start_y=900,
          dy_per_step=-30, steps=25, interval_s=0.008):
    """Two fingers down → fast Y motion → lift while still moving."""
    for slot, tid, x in ((0, 100, start_xs[0]), (1, 101, start_xs[1])):
        ui.write(e.EV_ABS, e.ABS_MT_SLOT, slot)
        ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, tid)
        ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, x)
        ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, start_y)
        ui.write(e.EV_ABS, e.ABS_MT_PRESSURE, 60)
        ui.write(e.EV_ABS, e.ABS_MT_TOUCH_MAJOR, 50)
        ui.write(e.EV_ABS, e.ABS_MT_TOUCH_MINOR, 50)
    ui.write(e.EV_KEY, e.BTN_TOUCH, 1)
    ui.write(e.EV_KEY, e.BTN_TOOL_DOUBLETAP, 1)
    ui.syn()

    y = start_y
    for _ in range(steps):
        y += dy_per_step
        for slot in (0, 1):
            ui.write(e.EV_ABS, e.ABS_MT_SLOT, slot)
            ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, y)
        ui.syn()
        time.sleep(interval_s)

    # Lift fingers WHILE still moving — final velocity sample non-zero,
    # so kitty's set_velocity_from_samples seeds momentum.
    for slot in (0, 1):
        ui.write(e.EV_ABS, e.ABS_MT_SLOT, slot)
        ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, -1)
    ui.write(e.EV_KEY, e.BTN_TOUCH, 0)
    ui.write(e.EV_KEY, e.BTN_TOOL_DOUBLETAP, 0)
    ui.syn()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--name",    default="synthetic-touchpad")
    p.add_argument("--vendor",  type=lambda s: int(s, 0), default=0x06CB)
    p.add_argument("--product", type=lambda s: int(s, 0), default=0x0001)
    p.add_argument("--settle",  type=float, default=1.5,
                   help="seconds to wait after device creation "
                        "(udev tag + Xorg attach)")
    p.add_argument("--trigger-file", default="",
                   help="if set, wait for this file to appear before "
                        "flinging (instead of --settle). Lets the "
                        "harness coordinate ordering with other "
                        "processes (kitty startup, etc.).")
    p.add_argument("--persist", type=float, default=2.5,
                   help="seconds to keep device alive after fling "
                        "(let kitty drain momentum events)")
    p.add_argument("--steps",   type=int,   default=25)
    p.add_argument("--dy",      type=int,   default=-30,
                   help="per-step ABS_MT_POSITION_Y delta "
                        "(negative = upward = natural-scroll content down)")
    args = p.parse_args()

    ui = UInput(
        CAPS,
        name=args.name,
        vendor=args.vendor,
        product=args.product,
        input_props=[e.INPUT_PROP_POINTER, e.INPUT_PROP_BUTTONPAD],
    )
    print(f"DEVICE_READY {ui.device.path} name={args.name}", flush=True)
    try:
        if args.trigger_file:
            while not os.path.exists(args.trigger_file):
                time.sleep(0.05)
            print("FLING_TRIGGERED", flush=True)
        else:
            time.sleep(args.settle)
        print("FLING_START", flush=True)
        fling(ui, dy_per_step=args.dy, steps=args.steps)
        print("FLING_COMPLETE", flush=True)
        time.sleep(args.persist)
        print("PERSIST_DONE", flush=True)
    finally:
        ui.close()


if __name__ == "__main__":
    main()
