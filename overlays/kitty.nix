# kitty overlay — patch glfw to classify libinput touchpads as HIGHRES so
# the X11 momentum scroller fires. See overlays/kitty-libinput-momentum.patch
# for the diff and reasoning. Upstream behavior locks offset_type=V120 for
# every libinput device (XIScrollClass.increment=120 always); patch checks
# is_finger_based first and treats touchpads as HIGHRES.
final: prev: {
  kitty = prev.kitty.overrideAttrs (old: {
    patches = (old.patches or []) ++ [ ./kitty-libinput-momentum.patch ];
  });
}
