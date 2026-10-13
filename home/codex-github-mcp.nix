{ pkgs, githubMcpServer ? pkgs.github-mcp-server }:

# codex-github-mcp-server — credential wrapper for the official GitHub MCP
# server. Its command contract is `github-mcp-server stdio` followed by the
# validated GitHub App credentials and then the caller's arguments. It accepts
# only the configured App identity and fixed private-key path, strips inherited
# token credentials, and pins the server by store path, so GitHub App auth is
# its only credential source. An optional leading `--owner <login>` selects that
# owner's configured App installation and is consumed before server invocation.
# MCP toolsets and tool exclusions are policy and live only in ai-client-config,
# never here.
pkgs.writeShellApplication {
  name = "codex-github-mcp-server";
  text = ''
    die() {
      echo "codex-github-mcp-server: $*" >&2
      exit 1
    }

    [ -n "''${HOME:-}" ] || die "HOME is unset; cannot locate GitHub App config"

    requested_owner=""
    if [[ "''${1:-}" == --owner=* ]]; then
      die "--owner must use the form --owner <login>"
    fi
    if [ "''${1:-}" = --owner ]; then
      [ "$#" -ge 2 ] && [ -n "$2" ] \
        || die "--owner requires a non-empty <login>"
      requested_owner="''${2,,}"
      [[ "$requested_owner" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
        || die "invalid --owner login '$2'; expected ^[a-z0-9][a-z0-9-]*$"
      shift 2
    fi
    for arg in "$@"; do
      case "$arg" in
        --owner | --owner=*)
          die "--owner <login> must be the first two arguments"
          ;;
      esac
    done

    config="$HOME/.config/github-app/config"
    [ -r "$config" ] || die "cannot read config: $config"

    app_id=""
    installation_id=""
    key_path=""
    org_installations=""
    seen_app_id=""
    seen_installation_id=""
    seen_key_path=""
    seen_org_installations=""

    # Treat the config strictly as data. Values are never evaluated, and
    # unrelated assignments (TOKEN_ROOT, etc.) are inert. Accept the shell
    # file's simple assignment syntax without performing expansion or
    # evaluation.
    while IFS= read -r line || [ -n "$line" ]; do
      line="''${line%$'\r'}"
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      if ! [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        die "malformed config line in $config"
      fi

      key="''${BASH_REMATCH[2]}"
      value="''${BASH_REMATCH[3]}"

      # Trailing horizontal whitespace is shell syntax, not part of the value.
      while [[ "$value" == *[[:space:]] ]]; do
        value="''${value%?}"
      done

      # In an unquoted shell word, whitespace starts an optional trailing
      # comment. A # without preceding whitespace remains data.
      case "$value" in
        \"* | \'*) ;;
        *)
          if [[ "$value" =~ ^(.*)[[:space:]]+\#.*$ ]]; then
            value="''${BASH_REMATCH[1]}"
            while [[ "$value" == *[[:space:]] ]]; do
              value="''${value%?}"
            done
          fi
          ;;
      esac

      # Strip one matching quote pair only. This is syntax recognition, not
      # evaluation: the contents stay byte-for-byte data.
      case "$value" in
        \"*\") value="''${value:1:''${#value}-2}" ;;
        \'*\') value="''${value:1:''${#value}-2}" ;;
      esac

      case "$key" in
        APP_ID | INSTALLATION_ID | KEY_PATH | ORG_INSTALLATIONS)
          case "$value" in
            *'$'* | *'`'*)
              die "config key $key requires shell expansion; this wrapper reads the file as data"
              ;;
          esac
          if [ "$key" = KEY_PATH ] && [[ "$value" == *'~'* ]]; then
            die "config key KEY_PATH requires shell expansion; this wrapper reads the file as data"
          fi
          ;;
      esac

      case "$key" in
        APP_ID)
          [ -z "$seen_app_id" ] || die "duplicate APP_ID in $config"
          app_id="$value"
          seen_app_id=1
          ;;
        INSTALLATION_ID)
          [ -z "$seen_installation_id" ] || die "duplicate INSTALLATION_ID in $config"
          installation_id="$value"
          seen_installation_id=1
          ;;
        KEY_PATH)
          [ -z "$seen_key_path" ] || die "duplicate KEY_PATH in $config"
          key_path="$value"
          seen_key_path=1
          ;;
        ORG_INSTALLATIONS)
          [ -z "$seen_org_installations" ] \
            || die "duplicate ORG_INSTALLATIONS in $config"
          org_installations="$value"
          seen_org_installations=1
          ;;
      esac
    done < "$config"

    [[ "$app_id" =~ ^[0-9]+$ ]] \
      || die "APP_ID in $config must be numeric"
    [[ "$installation_id" =~ ^[0-9]+$ ]] \
      || die "INSTALLATION_ID in $config must be numeric"

    expected_key_path="$HOME/.config/github-app/app.pem"
    [ "$key_path" = "$expected_key_path" ] \
      || die "KEY_PATH in $config must equal $expected_key_path"
    [ -r "$key_path" ] || die "cannot read GitHub App private key: $key_path"

    selected_installation_id="$installation_id"
    if [ -n "$requested_owner" ]; then
      org_pairs=()
      read -r -a org_pairs <<< "$org_installations"
      owner_match=""
      for pair in "''${org_pairs[@]}"; do
        if [[ "$pair" != *=* ]]; then
          if [ "''${pair,,}" = "$requested_owner" ]; then
            die "ORG_INSTALLATIONS entry for owner '$requested_owner' is malformed; expected owner=numeric-id"
          fi
          continue
        fi
        entry_owner="''${pair%%=*}"
        entry_id="''${pair#*=}"
        normalized_entry_owner="''${entry_owner,,}"
        [ "$normalized_entry_owner" = "$requested_owner" ] || continue
        [[ "$normalized_entry_owner" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
          || die "ORG_INSTALLATIONS entry for owner '$requested_owner' has an invalid login"
        [[ "$entry_id" =~ ^[0-9]+$ ]] \
          || die "ORG_INSTALLATIONS entry for owner '$requested_owner' must have a numeric installation id"
        [ -z "$owner_match" ] \
          || die "ORG_INSTALLATIONS contains duplicate entries for owner '$requested_owner'"
        selected_installation_id="$entry_id"
        owner_match=1
      done
      [ -n "$owner_match" ] \
        || die "owner '$requested_owner' is not listed in ORG_INSTALLATIONS; refusing personal installation fallback"
    fi

    unset GITHUB_PERSONAL_ACCESS_TOKEN GITHUB_TOKEN GH_TOKEN GITHUB_APP_PRIVATE_KEY

    exec ${githubMcpServer}/bin/github-mcp-server \
      stdio \
      --app-id "$app_id" \
      --app-installation-id "$selected_installation_id" \
      --app-private-key-path "$key_path" \
      "$@"
  '';
}
