// XI_Motion event monitor — prints deviceid + sourceid + scroll valuator
// values for every XI Motion event with scroll-valuator deltas. Used by
// vm-kitty-momentum to verify which slave device kitty's `handle_xi_motion_event`
// receives scroll events from. The slave's deviceid determines which entry
// in kitty's `scroll_devices[]` table is matched, which in turn drives
// `is_highres` / `is_finger_based`.
//
// Usage:
//   xi-scroll-monitor <max_events>
//
// Exits after capturing <max_events> scroll-bearing motions, or at SIGTERM.
#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

int main(int argc, char **argv) {
    int max_events = (argc > 1) ? atoi(argv[1]) : 60;
    Display *d = XOpenDisplay(NULL);
    if (!d) { fprintf(stderr, "no display\n"); return 1; }
    int op, evt, err;
    if (!XQueryExtension(d, "XInputExtension", &op, &evt, &err)) {
        fprintf(stderr, "no XInput\n"); return 1;
    }
    Window root = DefaultRootWindow(d);
    XIEventMask em;
    unsigned char mask[XIMaskLen(XI_LASTEVENT)] = { 0 };
    em.deviceid = XIAllDevices;
    em.mask_len = sizeof(mask);
    em.mask = mask;
    XISetMask(mask, XI_Motion);
    XISelectEvents(d, root, &em, 1);
    XSync(d, False);
    fprintf(stdout, "READY\n");
    fflush(stdout);

    XEvent ev;
    int count = 0;
    while (count < max_events) {
        XNextEvent(d, &ev);
        if (ev.xcookie.type != GenericEvent) continue;
        if (ev.xcookie.extension != op) continue;
        if (!XGetEventData(d, &ev.xcookie)) continue;
        if (ev.xcookie.evtype == XI_Motion) {
            XIDeviceEvent *de = ev.xcookie.data;
            bool has_scroll = false;
            int total_bits = de->valuators.mask_len * 8;
            for (int i = 2; i < total_bits; i++) {
                if (XIMaskIsSet(de->valuators.mask, i)) { has_scroll = true; break; }
            }
            if (has_scroll) {
                printf("XI_Motion deviceid=%d sourceid=%d valuators:",
                       de->deviceid, de->sourceid);
                double *vp = de->valuators.values;
                for (int i = 0; i < total_bits; i++) {
                    if (XIMaskIsSet(de->valuators.mask, i)) {
                        printf(" v[%d]=%.3f", i, *vp);
                        vp++;
                    }
                }
                printf("\n");
                fflush(stdout);
                count++;
            }
        }
        XFreeEventData(d, &ev.xcookie);
    }
    XCloseDisplay(d);
    return 0;
}
