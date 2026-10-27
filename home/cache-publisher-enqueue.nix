{ ... }:
# Every push to a GitHub remote drops `owner/repo sha` into the
# cache-publisher spool (modules/nixos/cache-publisher.nix). The entry is
# a hint only: the publisher proves on its own, anonymously, that the
# repo and commit are public before anything is uploaded. Silent, a few
# ms, and a no-op on hosts without the spool.
{
  homeGitHooks.prePushAll = [{
    name = "cache-publisher-enqueue";
    body = ''
      spool=/var/lib/cache-publisher/queue
      if [ -w "$spool" ]; then
        slug=""
        case "$2" in
          https://github.com/*) slug="''${2#https://github.com/}" ;;
          git@github.com:*) slug="''${2#git@github.com:}" ;;
          ssh://git@github.com/*) slug="''${2#ssh://git@github.com/}" ;;
        esac
        slug="''${slug%/}"
        slug="''${slug%.git}"
        if [[ "$slug" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then
          while read -r _lref lsha _rref _rsha; do
            [[ "$lsha" =~ ^[0-9a-f]{40}$ ]] || continue
            [ "$lsha" = 0000000000000000000000000000000000000000 ] && continue
            tmp="$spool/.$$-$lsha"
            { printf '%s %s\n' "$slug" "$lsha" > "$tmp" \
                && mv -f "$tmp" "$spool/$(date +%s)-$$-$lsha"; } 2>/dev/null || rm -f "$tmp" 2>/dev/null
          done <<< "$refs"
        fi
      fi
      true
    '';
  }];
}
