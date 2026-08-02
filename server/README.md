# Eko relay

A self-hosted store-and-forward queue for Eko. It exists so the phone can drain
its outbox even when the Mac is asleep, elsewhere, or on another network.

**The relay cannot read your notifications.** Envelopes arrive already sealed to
the recipient's pinned identity key, and the Eko protocol's own sequence numbers
live inside that ciphertext. What the relay does see is metadata: which device
ids exchange envelopes, when, how often, and how large they are. For a
notification mirror that is not nothing — timing and size can suggest *that* you
heard from your bank at 14:32 without revealing what was said. Run your own.

Design rationale, threat model and the wire format live in
[docs/relay/ARCHITECTURE.md](../docs/relay/ARCHITECTURE.md).

## Quick start

```sh
cp .env.example .env
openssl rand -base64 32          # paste into EKO_BOOTSTRAP_TOKEN
docker compose up -d
curl -fsS localhost:8080/healthz
```

Then claim the deployment. The first account created becomes the admin, which is
why it is the one the bootstrap token guards:

```sh
curl -sX POST localhost:8080/api/v1/accounts \
  -H content-type:application/json \
  -d '{"username":"you","password":"a long passphrase",
       "bootstrap_token":"<the token from .env>"}'
```

Log in, then close registration so nobody else can create an account:

```sh
TOKEN=$(curl -sX POST localhost:8080/api/v1/accounts/login \
  -H content-type:application/json \
  -d '{"username":"you","password":"a long passphrase"}' | jq -r .token)

curl -sX PATCH localhost:8080/api/v1/admin/settings \
  -H "authorization: Bearer $TOKEN" -H content-type:application/json \
  -d '{"registration_open":false}'
```

The response tells you what is actually in force:

```json
{"registration_open": false, "forced_by_environment": false}
```

If `forced_by_environment` is `true`, `EKO_REGISTRATION` in your `.env` is
overriding the toggle and your change had no effect. Leave that variable **empty**
unless you specifically want the hard lock described below.

## Closing registration: two mechanisms

| | Where | Undoable by | Use it for |
| --- | --- | --- | --- |
| Admin toggle | database | any admin session | normal operation |
| `EKO_REGISTRATION=closed` | `.env` | editing `.env` + recreate | a hard lock |

The environment value wins whenever it is set, and `closed` applies to the *first*
account too. That is deliberate: an override exists to lock a deployment down,
and a lock that still lets a stranger claim an unclaimed server is not a lock. To
set up a server that boots locked, start it once with `EKO_REGISTRATION=open`,
create your account, then set `closed` and `docker compose up -d`.

## Adding devices

With registration closed, devices join through single-use enrolment tokens rather
than new accounts. These are `/account/` rather than `/admin/` endpoints on
purpose: they only ever touch the caller's own devices, and adding your phone is
not an administrative act. Closing registration is.

```sh
curl -sX POST localhost:8080/api/v1/account/enrolment-tokens \
  -H "authorization: Bearer $TOKEN" -H content-type:application/json -d '{}'
```

The device posts that token together with its **existing** P-256 identity public
key — the same key pairing already pins, so no new secret is created. It then
authenticates by signing a server nonce with that key. Devices never have
passwords.

```sh
curl -s localhost:8080/api/v1/account/devices -H "authorization: Bearer $TOKEN"
curl -sX DELETE localhost:8080/api/v1/account/devices/phone-1 \
  -H "authorization: Bearer $TOKEN"      # revokes immediately, kills its tokens
```

## TLS

Device bearer tokens travel in the `Authorization` header, so do not expose port
8080 to the internet directly. Either put the relay behind a reverse proxy you
already run, or use the bundled Caddy:

```sh
echo 'EKO_DOMAIN=relay.example.org' >> .env
docker compose --profile tls up -d
```

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `EKO_BIND` | `0.0.0.0:8080` | listen address |
| `EKO_DATABASE` | `/data/relay.db` | SQLite path |
| `EKO_REGISTRATION` | *(empty)* | empty, `open`, or `closed` — see above |
| `EKO_BOOTSTRAP_TOKEN` | *(none)* | required for the first account when set |
| `EKO_RETENTION_DAYS` | `30` | undelivered envelope lifetime |
| `EKO_ACCOUNT_QUOTA_BYTES` | `536870912` | stored bytes per account |
| `EKO_MAX_ENVELOPE_BYTES` | `1048576` | matches the protocol frame limit |
| `EKO_TOKEN_TTL_SECS` | `86400` | bearer token lifetime |

The four numeric settings take positive numbers only. Anything else - a
negative, a zero, a typo - is refused with a warning and the default is used,
because each of them had a wrong-but-plausible behaviour otherwise: `-1` bytes
became an unlimited envelope, a negative quota refused every deposit, and a
negative lifetime expired tokens as they were issued.

Acknowledged envelopes are deleted immediately; the retention sweep only catches
what was never drained. Envelope ids stay monotonic across pruning, because the
recipient rejects a sequence that goes backwards.

## Operating notes

The container runs as uid 10001 with a read-only root filesystem, no
capabilities, and `no-new-privileges`. Only `/data` is writable.

Back up the `relay-data` volume if you care about undelivered envelopes; nothing
in it is required for correctness, because the phone's outbox remains the source
of truth and the resume protocol heals a lost relay database.

## Development

```sh
# Exactly what the `Relay server` CI job runs.
cargo fmt --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked

docker compose config    # validate the compose file
```
