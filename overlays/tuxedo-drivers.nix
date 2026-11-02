# tuxedo-drivers does not build against the 2026-10 nixpkgs without this.
#
# Its own Makefile splices make's flag string into shell recipe lines:
#
#   all:
#   	make -C $(KDIR) M=$(PWD) $(MAKEFLAGS) modules
#
# which was harmless until nixpkgs started overriding the kernel module
# signing rule with `cmd_sign=<kmodigest>$(space)$@`
# (pkgs/os-specific/linux/kernel/common-flags.nix). `$(space)` is a Kbuild
# variable, and make re-emits it into MAKEFLAGS escaped as `$$(space)`. The
# recipe then hands that to bash, which reads `$$` as its own PID and chokes
# on what is left:
#
#   bash: -c: line 1: syntax error near unexpected token `('
#   make: *** [Makefile:29: all] Error 2
#
# Dropping the splice is the fix rather than a workaround: make already
# passes command-line variables down to a sub-make on its own, so
# `$(MAKEFLAGS)` there was redundant. The signing override still applies —
# the build logs a SIGN line per .ko with it removed, which is how this was
# verified rather than assumed.
#
# `--replace-fail` is the removal condition: if upstream (or nixpkgs) fixes
# the Makefile, this overlay fails loudly instead of quietly doing nothing.
# Its sibling out-of-tree module on this host, yt6801, builds unpatched.
final: prev: {
  linuxPackages = prev.linuxPackages.extend (
    kfinal: kprev: {
      tuxedo-drivers = kprev.tuxedo-drivers.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace Makefile --replace-fail ' $(MAKEFLAGS)' ""
        '';
      });
    }
  );
}
