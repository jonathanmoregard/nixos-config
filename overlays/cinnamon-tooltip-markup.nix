# Cinnamon renders tooltip text as Pango markup without validating it first.
#
# js/ui/tooltips.js's Tooltip.set_markup does:
#
#   this._tooltip.set_text(markup);
#   this._tooltip.clutter_text.set_use_markup(true);
#
# and a tooltip's text is not Cinnamon's to trust: it comes from window
# titles and from tray icons over D-Bus. CopyQ publishes the current
# clipboard contents on the second line of its own tray tooltip, so copying
# a URL containing '&', or any code containing '<', is enough — as are
# CopyQ's placeholders for a clipboard that is empty, hidden, or an image.
# Clutter then logs
#
#   Failed to set the markup of the actor 'ClutterText':
#     Unknown tag 'EMPTY' on line 2 char 9
#
# and discards the caller's formatting. 92 of those landed in this host's
# journal between 2026-10-01 and 2026-11-07, at a median of one per 73
# minutes. Clutter keeps the literal text when the parse fails, so the
# visible damage is small; the point of fixing it is that untrusted text
# reaching a markup parser unvalidated is the defect, and the warning is
# how it announces itself.
#
# The patch validates with Pango.parse_markup and falls back to
# GLib.markup_escape_text, which is exactly what js/ui/messageTray.js's
# _fixMarkup already does for notification text — so this follows the
# convention already in the file next door rather than inventing one.
#
# The patch not applying is the removal condition: if upstream validates
# this itself, the build fails loudly instead of quietly doing nothing.
# Both attributes are patched because `cinnamon` is not an alias that
# follows `cinnamon-common`: they are independent bindings onto the same
# source, and the NixOS session module reads `pkgs.cinnamon`. Overriding
# only `cinnamon-common` changed `nixosConfigurations.*.pkgs` while the
# session kept running the unpatched build, which is a silent no-op of
# exactly the kind this repo's overlays are commented to prevent.
final: prev:
let
  validateTooltipMarkup = pkg: pkg.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./cinnamon-tooltip-markup.patch ];
  });
in
{
  cinnamon = validateTooltipMarkup prev.cinnamon;
  cinnamon-common = validateTooltipMarkup prev.cinnamon-common;
}
