# Meetily Community Edition (MIT) — local meeting recorder/transcriber.
# https://github.com/Zackriya-Solutions/meetily
#
# Unpacks upstream's 0.5.0 .deb (0.5.0 is the first release with native
# PipeWire/PulseAudio capture) and patches its ELF files for NixOS. ONNX
# Runtime is compiled into the binary; besides WebKitGTK it needs audio libs
# and the Vulkan loader, which whisper.cpp uses on the tuxedo's AMD iGPU
# (no CUDA on this machine).
#
# Models download at runtime into ~/.local/share/com.meetily.ai/models.
# `meetily-kb-whisper` fetches KBLab's Swedish Whisper models there; see below.
#
# Phase 1 of the Meetily work: a quick way to test Swedish/English accuracy.
# A from-source build of the Meetily-ActuallyFree fork (speaker labels,
# meeting detection) is meant to replace this.
final: prev:
let
  meetily = prev.stdenv.mkDerivation (finalAttrs: {
    pname = "meetily";
    version = "0.5.0";

    src = prev.fetchurl {
      url = "https://github.com/Zackriya-Solutions/meetily/releases/download/v${finalAttrs.version}/meetily_${finalAttrs.version}_amd64.deb";
      hash = "sha256-x8nVapv4tPe0G2TY0cBNgXTvFQ9FAEOSPigo6qiV1AQ="; # pragma: allowlist secret
    };

    nativeBuildInputs = with prev; [
      dpkg
      autoPatchelfHook
      wrapGAppsHook3
    ];

    buildInputs = with prev; [
      alsa-lib
      libpulseaudio
      vulkan-loader
      webkitgtk_4_1
      gtk3
      libsoup_3
      openssl
      xz
      dbus
    ];

    # Tauri dlopens the tray library; whisper.cpp dlopens the Vulkan loader.
    runtimeDependencies = with prev; [
      libayatana-appindicator
      vulkan-loader
    ];

    # Wrap just the main binary; the bundled ffmpeg and llama-helper are
    # plain CLI sidecars that need no GTK/GIO environment.
    dontWrapGApps = true;
    postFixup = ''
      wrapGApp $out/opt/meetily/usr/bin/meetily
    '';

    installPhase = ''
      runHook preInstall
      # Keep the .deb's usr/ tree intact under opt/: the app resolves its
      # sidecars relative to its own binary and its resources via
      # ../lib/meetily. Only the launcher goes into bin/, so the bundled
      # ffmpeg never shadows the system one on PATH.
      mkdir -p $out/opt/meetily $out/bin
      cp -r usr $out/opt/meetily/
      ln -s $out/opt/meetily/usr/bin/meetily $out/bin/meetily
      mv $out/opt/meetily/usr/share $out/share
      runHook postInstall
    '';

    meta = {
      description = "Privacy-first AI meeting assistant with local transcription";
      homepage = "https://github.com/Zackriya-Solutions/meetily";
      license = prev.lib.licenses.mit;
      sourceProvenance = [ prev.lib.sourceTypes.binaryNativeCode ];
      platforms = [ "x86_64-linux" ];
      mainProgram = "meetily";
    };
  });

  # Meetily only lists Whisper files named in its built-in catalog
  # (src-tauri/src/config.rs, WHISPER_MODEL_CATALOG) and checks each is
  # >= 90% of the catalog size and a valid GGML file. KBLab's whisper.cpp
  # builds of kb-whisper are drop-in GGML files of the same architecture,
  # so they are saved under catalog names; pick that name in Meetily's
  # model list. Swedish WER (KBLab/Klang benchmarks): kb-whisper-large ~3.5%
  # vs OpenAI large-v3 ~7.2% vs Parakeet v3 (Meetily's default) ~17.7%.
  meetily-kb-whisper = prev.writeShellApplication {
    name = "meetily-kb-whisper";
    runtimeInputs = with prev; [ curl coreutils ];
    text = ''
      usage() {
        cat <<'EOF'
      Usage: meetily-kb-whisper [--force] <variant>

      Downloads KBLab's Swedish Whisper model (kb-whisper) for Meetily.

        large      kb-whisper-large, full precision (3.1 GB)  -> pick "large-v3" in Meetily
        large-q5   kb-whisper-large, q5_0 (about 1.1 GB)      -> pick "large-v3-q5_0"
        medium-q5  kb-whisper-medium, q5_0 (539 MB)           -> pick "medium-q5_0"

      The file replaces OpenAI's model of that name in Meetily's list, so the
      entry Meetily shows as e.g. "large-v3" is then kb-whisper. Set the
      transcription language to Swedish (or auto) in Meetily's settings.

        --force    overwrite an existing model file of that name
      EOF
      }

      force=0
      variant=""
      for arg in "$@"; do
        case "$arg" in
          --force) force=1 ;;
          -h|--help) usage; exit 0 ;;
          -*) echo "meetily-kb-whisper: unknown option: $arg" >&2; usage >&2; exit 2 ;;
          *)
            if [[ -n "$variant" ]]; then
              echo "meetily-kb-whisper: only one variant at a time" >&2; exit 2
            fi
            variant="$arg" ;;
        esac
      done

      case "$variant" in
        large)     repo=kb-whisper-large;  file=ggml-model.bin;      target=ggml-large-v3.bin; ui=large-v3 ;;
        large-q5)  repo=kb-whisper-large;  file=ggml-model-q5_0.bin; target=ggml-large-v3-q5_0.bin; ui=large-v3-q5_0 ;;
        medium-q5) repo=kb-whisper-medium; file=ggml-model-q5_0.bin; target=ggml-medium-q5_0.bin; ui=medium-q5_0 ;;
        "") usage >&2; exit 2 ;;
        *) echo "meetily-kb-whisper: unknown variant: $variant" >&2; usage >&2; exit 2 ;;
      esac

      models_dir="''${MEETILY_MODELS_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/com.meetily.ai/models}"
      dest="$models_dir/$target"
      if [[ -e "$dest" && "$force" -ne 1 ]]; then
        echo "meetily-kb-whisper: $dest already exists (use --force to replace it)" >&2
        exit 1
      fi

      url="https://huggingface.co/KBLab/$repo/resolve/main/$file"
      mkdir -p "$models_dir"
      part="$dest.part"
      echo "Downloading $url"
      echo "  -> $dest"
      # --continue-at - resumes an interrupted download of the same .part file.
      curl --fail --location --continue-at - --output "$part" "$url"
      mv -f "$part" "$dest"
      printf '%s\n' "KBLab/$repo $file" > "$dest.source"
      echo "Done. In Meetily, choose the Whisper model \"$ui\" (now kb-whisper)."
      echo "Restart Meetily if it was open."
    '';
  };
in
{
  inherit meetily meetily-kb-whisper;
}
