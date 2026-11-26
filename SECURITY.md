# Security policy

## Reporting a vulnerability

If you believe you have found a security issue in Wax, please report it
privately. Do not open a public GitHub issue for exploitable vulnerabilities.

Report it through [GitHub private vulnerability reporting](https://github.com/isaaclins/wax/security/advisories/new)
(the **Report a vulnerability** button on the repository's Security tab). Only
you and I can see the report, and we can work on the fix and an advisory there
together.

Please include:

- The Wax version and your macOS version
- What an attacker can do and what they need for it (another local account, a
  malicious website, a network position, a crafted file)
- Steps to reproduce, ideally the smallest one that works
- Whether it touches the equalizer helper or driver, the sign-in, the updater or
  the log

We aim to acknowledge reports within a reasonable time and will work with you on
a fix and coordinated disclosure when appropriate.

## What not to include in reports or public issues

- Spotify **refresh tokens**, **access tokens**, or authorization codes
- Spotify **client secrets** (this app uses PKCE; there should be no client secret)
- Contents of your **Keychain** or `settings.json` from Application Support
- OAuth callback URLs containing live `code=` or `state=` parameters from a real session

Redact or rotate credentials if they were accidentally exposed.

## Scope

In scope:

- Wax macOS app code in this repository
- OAuth loopback listener and token storage behavior documented in [data-storage.md](docs/data-storage.md)
- Local cache and settings handling

Out of scope:

- Vulnerabilities in Spotify's or Apple's services or SDKs, such as the Web Playback SDK, MusicKit or the Apple Music API (report those to Spotify or Apple)
- Social engineering or physical access to an unlocked Mac with an active session
- Issues that require a user to install a malicious modified build from an untrusted source

## Supported versions

Security fixes are applied on the default development branch. There is no separate
LTS release channel for this personal project.
