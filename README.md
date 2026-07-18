# RouterBOX-Fake

RouterBOX-Fake is an integration wrapper for running two related forks on one VPS:

- [`iqubik/myfakesite`](https://github.com/iqubik/myfakesite) — a Docker/Nginx mock API and frontend.
- [`hoaxisr/routebox`](https://github.com/hoaxisr/routebox) — a VPN-router/VPS panel project.

The repository keeps the two upstream projects separate and deploys them side-by-side, so each fork can still be updated from its original Git repository.

## Target VPS

The default deployment values are prepared for `delend.space`:

| Component | Default URL | Local path |
| --- | --- | --- |
| MyFakeSite | `https://delend.space` | `/opt/routerbox-fake/myfakesite` |
| Naive/TCP VPN endpoint | `delend.space:443` | RouteBox-generated client configs |
| AWG2 endpoint | `delend.space:2053/udp` | RouteBox-generated AmneziaWG configs |
| RouteBox panel | `https://panel.delend.space:8443` | `/opt/routerbox-fake/routebox` |

> Before installing, make sure DNS records point to the VPS: `delend.space` for MyFakeSite and `panel.delend.space` for the RouteBox panel.

## Quick install

Run on the VPS as `root` or through `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/RouterBOX-Fake/main/deploy/delend-space.sh | sudo bash
```

For a local checkout:

```bash
sudo ./deploy/delend-space.sh
```

## What the installer does

1. Installs required packages (`git`, `curl`, `ca-certificates`).
2. Clones or updates both upstream forks into `/opt/routerbox-fake`; RouteBox upstream code is currently expected from the `source` branch.
3. Issues a Let's Encrypt certificate for `panel.delend.space` before MyFakeSite occupies port `80`.
4. Builds and installs the RouteBox VPS panel on `panel.delend.space:8443`.
5. Configures VPN public endpoints/share links for `delend.space:443`, with AWG2 on `delend.space:2053/udp`, while keeping the panel separate.
6. Runs `myfakesite/install.sh` for the public mock site on `delend.space`.
7. Stores deployment settings in `/etc/routerbox-fake/routerbox-fake.env` for repeatable updates.

## Customization

All settings can be overridden with environment variables:

```bash
sudo ROUTERBOX_DOMAIN=example.com \
  ROUTEBOX_PANEL_DOMAIN=panel.example.com \
  ROUTEBOX_EMAIL=admin@example.com \
  VPN_PUBLIC_HOST=example.com \
  VPN_PUBLIC_PORT=443 \
  ./deploy/delend-space.sh
```

See [`deploy/routerbox-fake.env.example`](deploy/routerbox-fake.env.example) for the full list of variables.


## Deploying through GitHub Actions

If the operator environment cannot open a direct SSH connection to the VPS, use the manual workflow `.github/workflows/deploy-vps.yml`. Configure these repository secrets first:

| Secret | Example | Purpose |
| --- | --- | --- |
| `SSH_PRIVATE_KEY` | private key matching `authorized_keys` on both hosts | SSH authentication |
| `JUMP_USER` | `root` | SSH user for the jump host |
| `JUMP_HOST` | `217.60.4.60` | jump host address |
| `JUMP_PORT` | `28` | SSH port for the jump host |
| `VPS_USER` | `root` | SSH user for the target VPS |
| `VPS_HOST` | `78.17.84.28` | target VPS address |

Then open **Actions → Deploy RouterBOX-Fake to VPS → Run workflow** and keep the default inputs for `delend.space`.

## Updating

Re-run the installer. It fetches the configured branches and re-applies the deployment scripts with the saved settings.

## Notes

- This repository intentionally does not merge the source trees into one application bundle. It acts as an operational layer that joins the forks on one VPS while preserving clean upstream update paths.
- RouteBox receives a separate Let's Encrypt certificate before MyFakeSite starts Nginx, which avoids a port `80` conflict between the public site and the panel certificate challenge.
- The management panel is intentionally separate from VPN client endpoints: users connect to VPN profiles via `delend.space:443`, while admins manage RouteBox at `panel.delend.space:8443`.
- AmneziaWG/AWG2 listens on UDP `2053` by default, leaving TCP `443` clean for Naive. If you move a TCP-based VPN protocol onto TCP `443`, keep MyFakeSite off that TCP port or add an explicit TCP/SNI multiplexer.
