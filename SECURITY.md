# Security boundaries

RemoteMac is experimental remote-control software. Run only on devices and networks you own or are authorized to administer.

- Use a private, access-controlled Tailscale tailnet. Do not publish or port-forward the host listener to the Internet.
- The macOS host currently creates a plain TCP listener without an explicit loopback bind. Do not assume this application socket is limited to localhost. Restrict network access accordingly before running it.
- Ed25519 challenge signatures authenticate paired identities; they do not encrypt application payloads. Transport confidentiality relies on the intended Tailscale path, not on application-level TLS.
- Pair only devices you recognize and compare identity information. Keep pairing mode disabled when it is not needed.
- Screen capture and remote input expose sensitive capabilities. This snapshot has not received an independent security audit.
- Stored identities, tailnet state, device tokens, signing credentials and notification contents must remain private. None are required in a public source repository.
- Session teardown/reconnect behavior and launch-at-login restart acceptance require further validation.

This document describes limitations, not a security guarantee.
