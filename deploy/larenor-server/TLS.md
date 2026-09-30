# Unified Core TLS

Android background notification delivery requires an HTTPS Core URL whose
certificate the device trusts. The plain `unified.compose.yaml` deployment
continues to provide the foreground inbox, but intentionally cannot enable the
background delivery lease.

To expose Core directly over TLS, an administrator must provision:

- `/var/lib/larenor-server/core/tls/server.pem`, containing the server
  certificate and any required intermediate certificates;
- `/var/lib/larenor-server/core/tls/server.key`, containing its matching
  unencrypted private key;
- a certificate SAN matching the hostname entered in Larenor; and
- a trust chain accepted by the Android device. A private CA must be installed
  through the device's managed trust policy. Larenor does not install a CA or
  bypass Android certificate and hostname verification.

The directory must be owned by UID/GID `10001:10001` with mode `0700`. Both
files must be owned by UID/GID `10001:10001`, regular, single-link files with
mode `0600`. Core rejects a missing half of the pair, unsafe file metadata, an
invalid PEM, or a certificate/key mismatch before opening the listener.

Start the package with both Compose documents:

```sh
docker compose \
  -f deploy/larenor-server/unified.compose.yaml \
  -f deploy/larenor-server/unified.tls.compose.yaml \
  up -d
```

The overlay keeps port `8098`, changing its protocol to HTTPS. Configure the
Larenor source as `https://<certificate-hostname>:8098`. The overlay health
probe trusts only the mounted certificate for its loopback liveness request;
it does not change the trust policy used by Android clients.
