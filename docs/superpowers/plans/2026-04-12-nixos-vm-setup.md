# NixOS VM Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write all NixOS flake config, push to private GitHub repo, then walk through VM creation and installation.

**Architecture:** Modular flake with `nixosConfigurations.vm` (headless QEMU/KVM, 2GB RAM) and `darwinConfigurations.mac-mini` (placeholder). Home Manager integrated via NixOS module. Shared packages in `modules/common.nix`, machine-specific in `hosts/`. Low-RAM tuned via zram + disk swap + nix build limits.

**Tech Stack:** NixOS unstable, Nix flakes, home-manager, nix-darwin (placeholder), QEMU/KVM via virt-manager, claude-code from nixpkgs (unfree)

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `.gitignore` | Create | Exclude nix build results and direnv |
| `flake.nix` | Create | Entry point, all inputs, both system outputs |
| `modules/common.nix` | Create | Shared packages (claude-code, git, gh, etc.), allowUnfree |
| `modules/nixos/vm-tweaks.nix` | Create | Low-RAM nix settings, zram, disk swap |
| `modules/darwin/inference.nix` | Create | Placeholder for Mac Mini Ollama/MLX config |
| `home/jonathan.nix` | Create | Home Manager: zsh, git identity, stateVersion |
| `hosts/vm/default.nix` | Create | VM system config: boot, networking, users, SSH, imports |
| `hosts/vm/hardware-configuration.nix` | Create placeholder → replace | Empty module now; replaced with generated file post-VM-boot |
| `hosts/mac-mini/default.nix` | Create | Placeholder nix-darwin config |

---

### Task 1: Collect SSH public key

**Files:** none (data gathering step)

- [ ] **Step 1: Print your SSH public key**

  Run in your terminal:
  ```bash
  cat ~/.ssh/id_ed25519.pub || cat ~/.ssh/id_rsa.pub
  ```
  Copy the output — you'll paste it into Task 5 (hosts/vm/default.nix).

  If you have no SSH key, generate one first:
  ```bash
  ssh-keygen -t ed25519 -C "jonathan@vm"
  cat ~/.ssh/id_ed25519.pub
  ```

---

### Task 2: Create GitHub repo and push initial state

**Files:** none (remote setup)

- [ ] **Step 1: Authenticate gh CLI if needed**

  ```bash
  gh auth status
  ```
  Expected: shows `Logged in to github.com`. If not: `gh auth login`.

- [ ] **Step 2: Create private GitHub repo**

  ```bash
  cd /home/jonathan/Repos/nixos-config
  gh repo create jonathanmoregard/nixos-config --private --source=. --remote=origin --push
  ```
  Expected: `✓ Created repository jonathanmoregard/nixos-config on GitHub` and pushes the existing design spec commit.

- [ ] **Step 3: Verify remote**

  ```bash
  git remote -v
  ```
  Expected:
  ```
  origin  https://github.com/jonathanmoregard/nixos-config.git (fetch)
  origin  https://github.com/jonathanmoregard/nixos-config.git (push)
  ```

---

### Task 3: .gitignore

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Write .gitignore**

  ```
  # Nix build results
  result
  result-*

  # direnv
  .direnv/

  # VM disk images (don't commit these)
  *.qcow2
  *.vmdk

  # Editor
  .DS_Store
  ```

- [ ] **Step 2: Commit**

  ```bash
  git add .gitignore
  git commit -m "chore: add .gitignore"
  git push
  ```

---

### Task 4: flake.nix

**Files:**
- Create: `flake.nix`

- [ ] **Step 1: Write flake.nix**

  ```nix
  {
    description = "jonathanmoregard's NixOS + nix-darwin config";

    inputs = {
      nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

      home-manager.url = "github:nix-community/home-manager";
      home-manager.inputs.nixpkgs.follows = "nixpkgs";

      nix-darwin.url = "github:LnL7/nix-darwin";
      nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    };

    outputs = { self, nixpkgs, home-manager, nix-darwin, ... }:
    let
      linuxSystem = "x86_64-linux";
      darwinSystem = "aarch64-darwin";
    in {
      # NixOS VM (headless, QEMU/KVM)
      nixosConfigurations.vm = nixpkgs.lib.nixosSystem {
        system = linuxSystem;
        modules = [
          ./hosts/vm/default.nix
          ./modules/common.nix
          ./modules/nixos/vm-tweaks.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.jonathan = import ./home/jonathan.nix;
          }
        ];
      };

      # Mac Mini (nix-darwin, placeholder — flesh out on arrival)
      darwinConfigurations.mac-mini = nix-darwin.lib.darwinSystem {
        system = darwinSystem;
        modules = [
          ./hosts/mac-mini/default.nix
          ./modules/common.nix
          ./modules/darwin/inference.nix
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.jonathan = import ./home/jonathan.nix;
          }
        ];
      };
    };
  }
  ```

- [ ] **Step 2: Commit**

  ```bash
  git add flake.nix
  git commit -m "feat: add flake.nix with vm + mac-mini outputs"
  git push
  ```

---

### Task 5: modules/common.nix

**Files:**
- Create: `modules/common.nix`

- [ ] **Step 1: Write modules/common.nix**

  ```nix
  { pkgs, ... }:
  {
    # Allow unfree packages (required for claude-code)
    nixpkgs.config.allowUnfree = true;

    # Packages available on all machines
    environment.systemPackages = with pkgs; [
      claude-code
      git
      gh
      ripgrep
      fd
      jq
      curl
      wget
    ];

    # Nix flakes + nix-command enabled globally
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
  }
  ```

- [ ] **Step 2: Commit**

  ```bash
  git add modules/common.nix
  git commit -m "feat: add shared common module with claude-code"
  git push
  ```

---

### Task 6: modules/nixos/vm-tweaks.nix

**Files:**
- Create: `modules/nixos/vm-tweaks.nix`

- [ ] **Step 1: Write vm-tweaks.nix**

  ```nix
  { ... }:
  {
    # Conservative nix build settings for 2GB RAM VM
    nix.settings = {
      max-jobs = 1;
      cores = 1;
      # Trigger GC automatically when store is low on space
      min-free = 134217728;  # 128 MB in bytes
    };

    # Compressed RAM swap — good for memory pressure
    zramSwap.enable = true;

    # Additional disk swap for heavy nix builds
    swapDevices = [{
      device = "/swapfile";
      size = 2048;  # MB
    }];

    # Use disk for /tmp, not RAM (saves ~200MB)
    boot.tmp.useTmpfs = false;
  }
  ```

- [ ] **Step 2: Commit**

  ```bash
  mkdir -p modules/nixos
  git add modules/nixos/vm-tweaks.nix
  git commit -m "feat: add low-RAM tuning module for VM"
  git push
  ```

---

### Task 7: modules/darwin/inference.nix (placeholder)

**Files:**
- Create: `modules/darwin/inference.nix`

- [ ] **Step 1: Write placeholder**

  ```nix
  # Placeholder — flesh out when Mac Mini arrives.
  # Will contain: Ollama (Metal-accelerated), MLX Python env, launchd service.
  { ... }:
  {
    # TODO(mac-mini): enable when hardware arrives
    # services.ollama.enable = true;
    # environment.systemPackages = with pkgs; [ ollama python3Packages.mlx ];
  }
  ```

- [ ] **Step 2: Commit**

  ```bash
  mkdir -p modules/darwin
  git add modules/darwin/inference.nix
  git commit -m "chore: add darwin inference module placeholder"
  git push
  ```

---

### Task 8: home/jonathan.nix

**Files:**
- Create: `home/jonathan.nix`

**Note:** Replace `"Your Name"` and `"your@email.com"` with your actual git name and email before committing.

- [ ] **Step 1: Write home/jonathan.nix**

  ```nix
  { pkgs, ... }:
  {
    home.username = "jonathan";
    home.homeDirectory = "/home/jonathan";

    # Keep this at the version when you first set up Home Manager
    home.stateVersion = "25.11";

    # Let Home Manager manage itself
    programs.home-manager.enable = true;

    # Git identity
    programs.git = {
      enable = true;
      userName = "Your Name";       # REPLACE THIS
      userEmail = "your@email.com"; # REPLACE THIS
      extraConfig = {
        init.defaultBranch = "main";
        pull.rebase = true;
      };
    };

    # Zsh with quality-of-life features
    programs.zsh = {
      enable = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      shellAliases = {
        ll = "ls -la";
        rebuild = "sudo nixos-rebuild switch --flake /etc/nixos#vm";
        update = "sudo nix flake update /etc/nixos && rebuild";
      };
    };
  }
  ```

- [ ] **Step 2: Update git name and email in home/jonathan.nix**

  Edit the file and replace `"Your Name"` and `"your@email.com"` with your actual values.

- [ ] **Step 3: Commit**

  ```bash
  git add home/jonathan.nix
  git commit -m "feat: add Home Manager config for jonathan"
  git push
  ```

---

### Task 9: hosts/vm/default.nix + hardware placeholder

**Files:**
- Create: `hosts/vm/default.nix`
- Create: `hosts/vm/hardware-configuration.nix` (placeholder — replaced in Task 12)

**Note:** Paste your SSH public key from Task 1 into the `openssh.authorizedKeys.keys` list.

- [ ] **Step 1: Create hosts/vm/ directory**

  ```bash
  mkdir -p hosts/vm
  ```

- [ ] **Step 2: Write hosts/vm/hardware-configuration.nix placeholder**

  ```nix
  # Generated by nixos-generate-config inside the VM.
  # Replace this file with the actual generated content after booting the installer ISO.
  { ... }: {}
  ```

- [ ] **Step 3: Write hosts/vm/default.nix**

  Replace `"ssh-ed25519 AAAA... your-key-here"` with the public key from Task 1.

  ```nix
  { config, pkgs, ... }:
  {
    imports = [
      ./hardware-configuration.nix
    ];

    # systemd-boot works cleanly with the GPT+ESP partition scheme used during install
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    # Networking — NetworkManager + hostname
    networking = {
      hostName = "nixos-vm";
      networkmanager.enable = true;
    };

    # Locale + timezone
    time.timeZone = "Europe/Stockholm"; # ADJUST to your timezone
    i18n.defaultLocale = "en_US.UTF-8";

    # SSH server — only way to access this headless VM
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;  # key-only auth
        PermitRootLogin = "no";
      };
    };

    # User account
    users.users.jonathan = {
      isNormalUser = true;
      extraGroups = [ "wheel" "networkmanager" ];
      shell = pkgs.zsh;
      # Paste your SSH public key here (from Task 1)
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAA... your-key-here"  # REPLACE THIS
      ];
    };

    # Allow wheel group to use sudo without password (convenient for remote work)
    security.sudo.wheelNeedsPassword = false;

    # Enable zsh system-wide (required for it to be a valid login shell)
    programs.zsh.enable = true;

    system.stateVersion = "25.11";
  }
  ```

- [ ] **Step 4: Paste your SSH public key into hosts/vm/default.nix**

  Replace `"ssh-ed25519 AAAA... your-key-here"` with the output from Task 1.

- [ ] **Step 5: Adjust timezone if needed**

  Valid values: `"Europe/Stockholm"`, `"America/New_York"`, `"America/Los_Angeles"`, etc.

- [ ] **Step 6: Commit**

  ```bash
  git add hosts/vm/
  git commit -m "feat: add VM host config (headless, SSH, low-RAM)"
  git push
  ```

---

### Task 10: hosts/mac-mini/default.nix (placeholder)

**Files:**
- Create: `hosts/mac-mini/default.nix`

- [ ] **Step 1: Create hosts/mac-mini/ and write placeholder**

  ```bash
  mkdir -p hosts/mac-mini
  ```

  ```nix
  # Placeholder — flesh out when Mac Mini (M-series, 64GB) arrives.
  { pkgs, ... }:
  {
    # Basic nix-darwin system config
    system.stateVersion = 6;  # nix-darwin version, not NixOS

    # Enable Touch ID for sudo (convenient on Mac)
    security.pam.enableSudoTouchIdAuth = true;

    # Nix daemon settings
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # Allow unfree (claude-code, etc.)
    nixpkgs.config.allowUnfree = true;

    # Shell
    programs.zsh.enable = true;
  }
  ```

- [ ] **Step 2: Commit**

  ```bash
  git add hosts/mac-mini/
  git commit -m "chore: add mac-mini host placeholder for nix-darwin"
  git push
  ```

---

### Task 11: Create the VM in virt-manager

**⚠ USER ACTION REQUIRED — these steps happen in the GUI/terminal on your host machine, not by Claude.**

- [ ] **Step 1: Verify KVM is available**

  ```bash
  kvm-ok
  ```
  Expected: `KVM acceleration can be used`. If not: `sudo apt install cpu-checker && kvm-ok`.

- [ ] **Step 2: Install virt-manager if not present**

  ```bash
  which virt-manager || sudo apt install virt-manager libvirt-daemon-system
  sudo systemctl enable --now libvirtd
  sudo usermod -aG libvirt jonathan
  newgrp libvirt
  ```

- [ ] **Step 3: Download NixOS minimal ISO**

  ```bash
  cd ~/Downloads
  wget https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-x86_64-linux.iso
  ```
  This is ~1.1 GB. Wait for it to complete.

- [ ] **Step 4: Create VM in virt-manager**

  Open virt-manager: `virt-manager`

  Click **"Create a new virtual machine"** and configure:
  - Installation media: Local install media → browse to the downloaded ISO
  - OS type: Generic Linux (or NixOS if listed)
  - **Memory: 2048 MB**
  - **CPUs: 2**
  - **Storage: 40 GB** (thin provisioned, qcow2)
  - Name: `nixos-vm`
  - **Before finishing:** check "Customize configuration before install"

  In the hardware customization screen:
  - **Disk bus:** VirtIO (faster than IDE/SATA)
  - **NIC:** leave as default (NAT, virtio)
  - **Video:** VGA (needed for console during install)

  Click **Begin Installation**.

---

### Task 12: Install NixOS inside the VM

**⚠ USER ACTION REQUIRED — run these commands inside the VM console (virt-manager window).**

Log in as `root` (no password needed in live ISO).

- [ ] **Step 1: Verify network**

  ```bash
  ping -c 2 1.1.1.1
  ```
  Expected: packets received. If not: `systemctl start NetworkManager`.

- [ ] **Step 2: Partition the disk**

  ```bash
  # Confirm disk name (should be /dev/vda in QEMU)
  lsblk

  # Create GPT partition table with boot + root partitions
  parted /dev/vda -- mklabel gpt
  parted /dev/vda -- mkpart ESP fat32 1MB 512MB
  parted /dev/vda -- set 1 esp on
  parted /dev/vda -- mkpart primary 512MB 100%
  ```

- [ ] **Step 3: Format partitions**

  ```bash
  mkfs.fat -F 32 -n boot /dev/vda1
  mkfs.ext4 -L nixos /dev/vda2
  ```

- [ ] **Step 4: Mount**

  ```bash
  mount /dev/disk/by-label/nixos /mnt
  mkdir -p /mnt/boot
  mount -o umask=077 /dev/disk/by-label/boot /mnt/boot
  ```

- [ ] **Step 5: Generate hardware configuration and clone repo**

  ```bash
  # Generate hardware config (prints to stdout)
  nixos-generate-config --root /mnt --show-hardware-config > /tmp/hardware-configuration.nix

  # Clone your repo into /mnt/etc/nixos
  nix-shell -p git --run "git clone https://github.com/jonathanmoregard/nixos-config /mnt/etc/nixos"

  # Replace placeholder with generated hardware config
  cp /tmp/hardware-configuration.nix /mnt/etc/nixos/hosts/vm/hardware-configuration.nix
  ```

- [ ] **Step 6: Install**

  ```bash
  nixos-install --flake /mnt/etc/nixos#vm --no-root-passwd
  ```

  This downloads nixpkgs + builds the system. On 2 GB RAM + 2 vCPUs it takes 10-30 minutes depending on internet speed. Watch for errors.

  Expected final line: `installation finished!`

- [ ] **Step 7: Reboot into installed system**

  ```bash
  reboot
  ```

  In virt-manager: after reboot the VM will boot from disk. The ISO will no longer be used.

---

### Task 13: First boot verification

**⚠ USER ACTION — find VM IP and SSH in from your host.**

- [ ] **Step 1: Find the VM's IP address**

  On your host:
  ```bash
  virsh net-dhcp-leases default
  ```
  Expected: a line with `nixos-vm` and an IP like `192.168.122.xxx`.

- [ ] **Step 2: SSH into the VM**

  ```bash
  ssh jonathan@192.168.122.xxx
  ```
  Expected: you land in a zsh shell. No password prompt (key auth).

- [ ] **Step 3: Verify Claude Code is installed**

  ```bash
  claude --version
  ```
  Expected: prints `claude X.Y.Z` (same as or newer than 2.1.92).

- [ ] **Step 4: Verify Home Manager activated**

  ```bash
  which zsh && echo $SHELL
  git config --global user.name
  ```
  Expected: `/run/current-system/sw/bin/zsh` and your git name.

---

### Task 14: Commit hardware-configuration.nix and push final state

**Back in your host terminal (not the VM).**

- [ ] **Step 1: Copy hardware-configuration.nix from VM to host**

  ```bash
  scp jonathan@192.168.122.xxx:/etc/nixos/hosts/vm/hardware-configuration.nix \
      /home/jonathan/Repos/nixos-config/hosts/vm/hardware-configuration.nix
  ```

- [ ] **Step 2: Commit and push**

  ```bash
  cd /home/jonathan/Repos/nixos-config
  git add hosts/vm/hardware-configuration.nix
  git commit -m "feat: add generated hardware-configuration.nix for VM"
  git push
  ```

- [ ] **Step 3: Verify final repo state on GitHub**

  ```bash
  gh repo view jonathanmoregard/nixos-config --web
  ```

---

## Post-Install: Making changes going forward

Once the VM is running, the workflow for config changes is:

1. Edit files in `/home/jonathan/Repos/nixos-config` on your **host**
2. Push to GitHub
3. In the VM, run `update` (the shell alias defined in `home/jonathan.nix`):
   ```bash
   sudo nix flake update /etc/nixos && sudo nixos-rebuild switch --flake /etc/nixos#vm
   ```

Or keep `/etc/nixos` as a git clone in the VM and pull changes there.
