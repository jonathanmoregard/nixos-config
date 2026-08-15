# macOS test VM via Scaleway Apple Silicon

Runbook for spinning up a real macOS desktop for onboarding-flow
testing — installing apps, walking first-run wizards, exercising
App Store / iCloud / TCC prompts as a real user would.

## Why Scaleway, not the others

Full desktop testing needs **bare-metal + dedicated + admin/root**.
That eliminates the cheap shared tiers (MacinCloud shared / managed
= no root, blocks every installer prompt) and every macOS-in-a-VM
path (Apple's own note limits App Store, iCloud Backup, Find My,
Apple Wallet, Apple Media Services inside VMs — the exact surfaces
onboarding flows exercise).

Scaleway Apple silicon Mac minis:

- Bare metal (App Store + iCloud sign-in should work — vendor claim,
  not independently verified per session)
- VNC "directly integrated with the macOS system without any
  restrictions" (vendor docs), so Apple's native Screen Sharing
  client works from a Mac
- 24-hour minimum lease (Apple license §3.A — not a vendor quirk;
  applies at AWS EC2 Mac too)
- Reinstall = clean state; convenient for repeat onboarding runs

Cheapest per test session:

| Config | Hourly | 24h (one session) |
|---|---|---|
| M1-M (8 GiB) | €0.11 | ~€2.64 |
| M4-S (16 GiB) | €0.22 | ~€5.28 |

Three sessions/month → ~€8–16.

## One-time setup

### 1. Scaleway account + payment

Manual step (Jonathan, not Claude — requires credit card):

1. Sign up at <https://console.scaleway.com/>
2. Add payment method (Billing → Payment methods)
3. Create an API token: **IAM → API keys → Generate API key**
   - Save the secret key immediately (shown once)

### 2. Store the API token as an agenix secret

```bash
cd ~/Repos/nixos-config-worktrees/<your-slug>
add-secret scaleway-api-token
# paste the secret key when prompted, then confirm
# → opens a PR; merge to deploy
```

The secret lands at `/run/agenix/scaleway-api-token` on dellan.

### 3. Install the `scw` CLI

Add to `environment.systemPackages` (or a wrapper module) in a
future PR:

```nix
environment.systemPackages = [ pkgs.scaleway-cli ];
```

Configure with the API token — one-time interactive:

```bash
export SCW_SECRET_KEY="$(< /run/agenix/scaleway-api-token)"
scw init  # walk through org ID + default region prompts
```

## Per-session flow

### Spin up (once you have credit)

```bash
# List available offer types + regions
scw apple-silicon server-type list zone=fr-par-3

# Create — M1-M, cheapest; zone must match the offer
scw apple-silicon server create \
    type=M1-M \
    name=onboarding-test \
    zone=fr-par-3

# Grab the server ID + wait for state=ready (~1–2 min)
scw apple-silicon server list
scw apple-silicon server get <server-id>
```

### Enable auto-delete guard

**Critical** — Scaleway defaults to open-ended monthly rental once
the 24h minimum lease clears. Console → your server → **Enable
auto-delete after 24h** to bound cost.

CLI equivalent (verify current flag name against `scw apple-silicon
server update -h`; API has churned):

```bash
scw apple-silicon server update <server-id> delete-at="+24h"
```

### Get VNC connection info

```bash
scw apple-silicon server vnc-url <server-id>
# → vnc://<host>:<random-port> (port is NOT 5900 — randomly assigned per server)
```

### Connect from a Mac (recommended)

Native Screen Sharing:

```
open "vnc://<host>:<port>"
# password shown in console → your server → Credentials
```

Reason to use native ARD/Screen Sharing over RealVNC: Scaleway's own
client-comparison rates the built-in Mac client "High" on
responsiveness with working copy-paste; RealVNC free has partial
copy-paste + no audio.

### Connect from Linux (fallback)

RealVNC Viewer or Remmina — expect noticeable latency vs a Mac
client. Consider Parsec if you need better input feel (setup on the
Mac side required).

### Reset to clean state between runs

```bash
scw apple-silicon server reinstall <server-id>
# → wipes disk, reinstalls macOS. Takes ~10–15 min. There is no
# snapshot/rollback equivalent to an AWS AMI.
```

### Tear down

```bash
scw apple-silicon server delete <server-id>
# Note: you're still billed for the full 24h from creation regardless
# — Apple license minimum.
```

## Sanity: what to test on the VM

Onboarding-flow specifics known to differ from a local Mac:

- **App Store login**: should work on bare metal — verify on first
  session, not documented per-vendor
- **TCC prompts (screen recording, camera, mic)**: real macOS
  behaviour on the console; over remote VNC these dialogs still
  render, but capture output may behave differently — trial first
- **iCloud sign-in**: bare metal → works; a VM guest would refuse
- **Setup Assistant**: the whole point — run through it clean
  after each `reinstall`

## Do not

- Do **not** use MacinCloud's `$1/hr` or `$25/mo` shared plans:
  "No Admin/Root Access", installers won't work.
- Do **not** use OSX-KVM / hackintosh: breaks App Store, Apple ID,
  iCloud — exactly the onboarding surfaces you're testing. Also
  outside Apple's license.
- Do **not** use Anka + disable SIP: Anka's docs recommend
  disabling SIP because TCC dialogs hang automation; those dialogs
  ARE what you're testing.

## References

Research report:
`~/Repos/research-agent/reports/959a8e40d92840ebb6619c08ff34c1d7.md`
