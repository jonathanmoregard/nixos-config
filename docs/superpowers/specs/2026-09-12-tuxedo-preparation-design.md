# TUXEDO InfinityBook Pro 15 Gen10 AMD preparation design

**Date:** 2026-09-12

## Goal

Prepare the reusable, testable NixOS configuration for a TUXEDO InfinityBook
Pro 15 Gen10 AMD without pretending that unknown hardware facts are known.
Keep the current Dell Latitude configuration behaviourally unchanged. Record
how to validate the laptop, local dictation, NPU runtime, and isolated agent
execution after the hardware arrives.

The selected hardware is product 10900244: Ryzen AI 9 HX 370, Radeon 890M,
XDNA 2 NPU, 64 GiB DDR5-5600, 2 TiB WD Black SN7100, Intel AX210, and no
discrete GPU.

## Evidence boundaries

### Verified locally

- The pinned nixpkgs currently supplies Linux 6.18.42, linux-firmware
  20260622, `tuxedo-drivers` 4.20.1, `tuxedo-rs` 0.3.1,
  `whisper-cpp-vulkan` 1.9.2, Mesa 26.1.6, and Vulkan tools 1.4.350.0.
- Linux 6.18.42 contains the in-tree `amdxdna` module and the current firmware
  closure contains Strix Point `amdnpu/17f0_10` and `17f0_11` images.
- nixpkgs has upstream `hardware.tuxedo-drivers` and `hardware.tuxedo-rs`
  NixOS modules. The driver module supports declarative 80%, 90%, or 100%
  charging profiles.
- `modules/nixos/laptop.nix` currently mixes generic laptop behaviour with
  Dell Latitude 7440-specific Intel graphics, TLP, thermald, IPU6, and camera
  recovery code.
- The checked-out Voquill application is dictation/STT, not TTS. Its current
  configuration uses OpenAI transcription. Its local backend supports CPU or
  Vulkan whisper.cpp, not ROCm or XDNA. Its service launches a repo-local
  binary that is not built during fresh-host bootstrap.
- Voquill supports an OpenAI-compatible transcription endpoint, leaving a
  later seam for a local NPU service without changing desktop capture.
- The existing research-agent design already provides the preferred isolation
  boundary: persistent KVM microVM, default-drop networking, and a fresh
  bubblewrap jail per request. `repo-check` Phase C's Docker runner is not a
  sufficient outer boundary for hostile plugins because it runs as root with
  `NET_ADMIN` and `--dangerously-skip-permissions`.

### Sourced current-state facts

- TUXEDO says current distributions can support the model, but its FAQ also
  says the selected Intel AX210 cannot use 6 GHz Wi-Fi on an AMD platform and
  that the Motorcomm YT6801 Ethernet controller needs its vendor driver below
  Linux 7.0.
- A community hardware report for this exact Gen10 model records CPU, Radeon
  890M, Wi-Fi, and keyboard working on Linux 6.18.7; it records Ethernet and
  XDNA 2 working on Linux 7.0.
- The upstream `amdxdna` driver first landed in Linux 6.14. Current
  FastFlowLM/Lemonade Linux guidance requires Linux 7.0 or a matching DKMS
  driver, sufficiently new NPU firmware, and an XRT userspace matching the
  kernel ioctl surface.
- Current reports conflict on kernel stability: one Ryzen AI report describes
  amdgpu MES freezes on 6.18/6.19, while another describes repeatable s2idle
  failure on 7.0.9 that disappears on 6.18.7.
- No upstream `nixos-hardware` profile exists for this Gen10 model. TUXEDO
  Control Center is not packaged in nixpkgs; `tuxedo-rs`/Tailor is the
  packaged alternative.
- `kylemanna/nix-amd-ai` is the broadest current community NixOS integration
  for XRT, FastFlowLM, and Lemonade. It is not an upstream nixpkgs stack and
  carries kernel/runtime, memlock, and device-permission implications.

Sources:

- [TUXEDO model FAQ](https://www.tuxedocomputers.com/en/FAQ-TUXEDO-InfinityBook-Pro-15-Gen10-AMD.tuxedo)
- [Gentoo hardware report for the Gen10 model](https://wiki.gentoo.org/wiki/TUXEDO_InfinityBook_Pro_15_(Gen10))
- [Linux amdxdna documentation](https://docs.kernel.org/next/accel/amdxdna/amdnpu.html)
- [AMD XDNA driver and XRT shim](https://github.com/amd/xdna-driver)
- [FastFlowLM/Lemonade Linux NPU requirements](https://lemonade-server.ai/flm_npu_linux.html)
- [nix-amd-ai](https://github.com/kylemanna/nix-amd-ai)
- [nixos-hardware Ryzen AI freeze report](https://github.com/NixOS/nixos-hardware/issues/1801)
- [s2idle regression report](https://github.com/pop-os/pop/issues/4016)

### Inference and recommendation

- Kernel selection is a hardware test result, not a pre-arrival constant.
  Forcing 7.0 solely for NPU support risks suspend stability; staying on 6.18
  may leave Ethernet or current NPU userspace unavailable.
- Radeon 890M Vulkan is the best first local dictation target because it is
  supported by Voquill's existing local sidecar and current nixpkgs. NPU
  dictation should compete against measured CPU and Vulkan latency on short
  utterances rather than against marketing TOPS.
- Local agent execution and local model inference are independent. Existing
  honeypot agents can run inside the current microVM/bubblewrap boundary while
  inference remains remote. Accelerator access should stay outside an
  adversarial guest.

## Approaches considered

### 1. Verified dormant hardware profile — chosen

Extract the Dell/Intel configuration from the generic laptop module, add a
model-specific AMD/TUXEDO module, and validate both with existing checks. Do
not add a bootable host output until generated hardware configuration, disk
layout, and SSH host key exist.

This produces useful code before arrival while keeping every unverified choice
reversible.

### 2. Complete host plus experimental NPU stack now

Add a host output with a guessed disk layout, force Linux 7.0+, and pin
`nix-amd-ai`. This shortens setup on arrival, but turns unknown storage,
suspend, firmware, and runtime compatibility into production defaults. The
failure modes are boot-critical, so this approach is rejected.

### 3. Research and checklist only

Leave configuration unchanged and document findings. This has the lowest
runtime risk but does not remove the Intel coupling that blocks a correct AMD
laptop profile. It fails the requirement for concrete preparation.

## Configuration design

### Generic laptop module

`modules/nixos/laptop.nix` retains only behaviour shared by both laptops:

- firmware updates;
- touchpad and Bluetooth;
- lid/suspend policy;
- PipeWire with PulseAudio compatibility;
- printing, fonts, and other genuinely host-neutral laptop facilities.

No existing generic behaviour changes.

### Dell Latitude 7440 module

A new `modules/nixos/dell-latitude-7440.nix` receives the code extracted from
the generic file:

- Intel microcode and Iris Xe media packages;
- Intel-specific TLP policy and thermald;
- IPU6 platform configuration;
- the v4l2loopback buffer module currently consumed by the IPU6 relay;
- the IPU6 relay prime, watchdog, and user notification path.

`hosts/dellan/default.nix` imports both generic laptop and Dell-specific
modules. Existing `vm-base` and `vm-camera-relay` tests remain the behavioural
regression gate.

### TUXEDO Gen10 AMD module

A new `modules/nixos/tuxedo-infinitybook-pro-15-gen10-amd.nix` provides only
pre-arrival-safe settings:

- AMD microcode updates;
- Mesa graphics with 32-bit support;
- upstream TUXEDO hardware drivers;
- `stationary` charging profile, corresponding to the driver's 80% longevity
  mode;
- power-profiles-daemon instead of Intel-tuned TLP;
- Vulkan/VA-API diagnostics and Vulkan whisper.cpp tooling needed for arrival
  measurements.

The module does not force an `amd_pstate` mode, kernel package, watt limit,
fan curve, Tailor daemon, NPU runtime, unlimited memlock, or permissive NPU
udev rule. Those settings need evidence from the actual machine.

Importing the file is the activation mechanism; no extra feature flag is
introduced.

### Contract test

Add a focused Nix evaluation/build contract for the TUXEDO module and attach
it to an existing CI-built lane without changing CI workflow files. It checks
the safe settings above and builds the kernel-side TUXEDO driver plus selected
userspace tools. Add or retain assertions showing Dellan still receives its
Intel/IPU6 settings after the split.

Implementation follows test-first order: add the contract and observe the
missing-module failure, then add the modules and restore green checks.

## Dictation direction

Voquill remains the desktop recorder and text-injection UI. Initial local
validation uses its Vulkan whisper.cpp backend on Radeon 890M. The existing
PipeWire Pulse compatibility layer remains part of the generic laptop module.

Fresh-install packaging of Voquill is a separate logical change: its flake is
currently a dev shell, the configured binary is a mutable repo build, and its
nominal GPU sidecar currently falls back to a byte-identical CPU binary. This
PR records that blocker and prevents the AMD profile from depending on the
mutable binary; it does not hide the gap with an activation-time build.

On arrival, clear the Dell-specific saved microphone, select the actual ACP
input, and compare the same short Swedish and English utterances on CPU and
Vulkan. An NPU server is considered only if it beats the Vulkan path on
interactive latency and stability. Voquill's OpenAI-compatible endpoint is
the integration seam.

## NPU direction

The default profile relies on kernel/firmware autoload only and adds no XRT
userspace. Experimental NPU enablement is a second phase after these facts are
captured:

1. actual PCI ID and `/dev/accel` node;
2. firmware version reported by the driver;
3. known-good kernel after repeated suspend and GPU stress;
4. compatible XRT shim and successful FastFlowLM validation;
5. explicit review of memlock and device-access changes.

Only an end-to-end transcription or generation proves the NPU path. Module
load, device-node presence, and marketing TOPS do not.

## Agent isolation direction

Run `repo-check` Phase C or equivalent hostile-agent workloads inside a
dedicated microVM based on the existing research-agent boundary. Keep its
inner Docker runner because Phase C needs Docker semantics, but treat the
microVM as the security boundary. Permit only DNS and provider HTTPS; expose
only quarantined output. Never add the host user or an agent account to the
Docker group.

Keep inference remote initially. If local inference is later useful, run it as
a separate host service with its own credentials and expose a narrow,
authenticated endpoint to the guest. Do not pass `/dev/dri` or `/dev/accel`
into the hostile-agent VM.

## Arrival verification

Before importing the TUXEDO module into a real host output:

1. Generate and review `hardware-configuration.nix`; decide LUKS/Btrfs layout
   from the real disk names. Never copy Dellan UUIDs or VM device paths.
2. Capture `lscpu`, `lspci -nnk`, kernel log, input devices, audio devices,
   display connectors, `/dev/dri`, `/dev/accel`, firmware, sensors, and
   `fwupdmgr` output.
3. Test Wi-Fi, Ethernet, keyboard backlight, webcam, microphone, speakers,
   external displays, brightness, touchpad, suspend, hibernate if configured,
   and charging profile.
4. Run at least ten lid and idle suspend/resume cycles. Search kernel logs for
   amdgpu MES and s2idle errors.
5. Stress Radeon 890M and record temperatures, fan behaviour, power draw, and
   errors before setting any watt or fan limit.
6. Generate the real SSH host key, add its agenix-rekey recipient, and create
   the per-host rekeyed secret directory.
7. Add the bootable flake host only after steps 1–6 are known; build its full
   toplevel before installation.
8. Benchmark Voquill CPU and Vulkan paths with the same short utterances.
9. If NPU work proceeds, validate kernel/userspace compatibility and complete
   an end-to-end workload before enabling it by default.

## Failure handling and rollback

- The current Dellan import split must be behaviour-preserving; any existing
  VM failure blocks the change.
- The TUXEDO module stays dormant until explicitly imported by a future host,
  so it cannot alter Dellan at deployment.
- Kernel experimentation happens through a separate boot generation or
  specialization after arrival. Keep a known-good generation until repeated
  suspend and GPU tests pass.
- NPU runtime, Tailor, fan control, and power limits remain additive follow-up
  changes that can be reverted without changing storage or the base desktop.

## Out of scope

- guessed disk partitions, filesystem UUIDs, initrd modules, or host SSH key;
- forcing Linux 7.0 before real suspend/GPU evidence;
- packaging or forking Voquill;
- enabling external NPU flakes, unlimited memlock, or broad accelerator
  permissions;
- changing CI workflows;
- replacing remote inference models used by honeypot/scanner evaluation.
