# Code signing

On macOS a debugger is not trusted because of what it does, but because of
how it is signed.  This document explains the rules, what `scripts/sign.sh`
does about them, and how to fix the usual failures.

## Why signing is required

To control another process, a debugger asks the kernel for that process's
task port with `task_for_pid`.  `taskgated` checks the caller's code
signature and only grants the port when the binary carries

```xml
<key>com.apple.security.cs.debugger</key>
<true/>
```

The entitlement is not enough on its own: the signature has to come from an
identity macOS trusts.  A binary signed ad hoc (`codesign -s -`) is
internally consistent — `codesign --verify` happily accepts it — but the
entitlement is not honoured, and the first `run` command blocks in
`taskgated` instead of starting the inferior.

That failure mode is worth knowing because it does not look like a signing
problem from inside GDB: the debugger starts, reads the Mach-O file, sets
breakpoints and prints source lines, then hangs on `run` with no message.
If GDB appears to freeze at inferior startup, check the signature with

```sh
codesign -dvvv dist/bin/gdb
```

A `Signature=adhoc` line means the build was not signed with a real
identity.

## Getting an identity

The free Apple ID route is enough for local debugging:

1. Open Xcode > Settings > Accounts and add an Apple ID.
2. Select the team, click Manage Certificates, then `+` and
   `Apple Development`.

Verify that the identity and its private key are visible:

```sh
security find-identity -v -p codesigning
```

A usable entry looks like

```text
1) 3C8E7F20FC43909ACC542034089D737FFED404B2 "Apple Development: Name (TEAMID)"
   1 valid identities found
```

An entry without a private key is not usable; `codesign` reports
`errSecInternalComponent` or `unable to build chain to self-signed root`
when it tries to use one.

`./scripts/sign.sh` picks the first `Apple Development` identity.  When
several exist, select one explicitly:

```sh
./scripts/sign.sh --identity "Apple Development: Name (TEAMID)"
```

## What the script does

```sh
codesign --force --options runtime --timestamp=none \
    --entitlements entitlements/gdb.entitlements \
    --sign "$IDENTITY" "$GDB"
```

- `--force` replaces the ad hoc signature the linker applied.
- `--options runtime` enables the hardened runtime, which is what makes
  the debugger entitlement meaningful.
- `--timestamp=none` avoids a network round trip to Apple's timestamp
  server; a local development build does not need a trusted timestamp.
- `--entitlements` adds `com.apple.security.cs.debugger`.

Afterwards the script verifies the result: `codesign --verify --strict`,
the presence of the entitlement, and the absence of `Signature=adhoc`.

Run the check at any time with

```sh
./scripts/sign.sh --check
```

## Inferiors usually do not need signing

Programs that GDB starts itself are traced from the moment they are spawned,
so the kernel grants the task port and no `get-task-allow` is needed.  A
plain `cc -g hello.c` build can be debugged without any extra step.

Attaching to a process that is already running is different: the target has
to allow it.  Sign the target with the inferior entitlement:

```sh
./scripts/sign.sh --target ./a.out
gdb -p "$(pgrep a.out)"
```

Note that hardened system binaries and processes owned by other users
refuse the attachment regardless of signing; that is SIP and TCC working as
intended, not a problem with the port.

## Re-signing after a rebuild

Any change to a Mach-O file invalidates its signature.  Rebuilding GDB,
even through `make` in `build/`, replaces `dist/bin/gdb` with an ad hoc
signed binary, so re-run

```sh
./scripts/sign.sh
```

`./build.sh` does this automatically at the end of every build.

## CI and headless machines

`codesign` needs the private key in an unlocked keychain.  On a build
machine, import a development certificate into a temporary keychain before
building:

```sh
security create-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
security set-keychain-settings -lut 21600 build.keychain
security unlock-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
security import certificate.p12 -k build.keychain -P "$P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" build.keychain
security list-keychains -d user -s build.keychain login.keychain
```

Then call `./build.sh --identity "Apple Development: Name (TEAMID)"`.

`--no-sign` builds without a certificate for compile testing; the resulting
GDB cannot debug.

## Troubleshooting

| Message | Cause | Fix |
| --- | --- | --- |
| `no usable codesigning identity found` | No certificate with a private key | Create one in Xcode, or import a `.p12` |
| `errSecInternalComponent` | Keychain locked, or the key is not usable by `codesign` | `security unlock-keychain`, or `security set-key-partition-list` |
| `code object is not signed at all` | The binary was replaced by a rebuild | Re-run `./scripts/sign.sh` |
| `invalid signature (code or signature have been modified)` | Binary edited after signing | Re-sign |
| `unable to build chain to self-signed root` | Self-signed certificate not marked as trusted for code signing | Use an Apple-issued identity, or set trust in Keychain Access |
| GDB hangs on `run`, no error | Ad hoc signature, or no entitlement | `./scripts/sign.sh --check` |
| `not permitted to attach to process` | Target hardened, owned by another user, or unsigned for attach | Sign the target with `--target`; SIP-protected targets cannot be attached to |

The signature state can always be inspected by hand:

```sh
codesign -dvvv dist/bin/gdb
codesign -d --entitlements - dist/bin/gdb
codesign --verify --strict --verbose=4 dist/bin/gdb
```

## A note on certificates

An Apple Development certificate identifies a person and a team.  It is
appropriate for builds on that person's machines, not for distribution.
Do not publish a signed GDB binary; other users must sign with their own
identity, which is why the build signs locally as its last step.
