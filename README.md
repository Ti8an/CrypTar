[English](README.md) | [Русский](README.ru.md)

# CrypTar

**CrypTar** is a Bash tool for archiving, GPG-encrypting, and sending backups to remote servers over SSH and to cloud storage (Google Drive, Yandex Disk).

---

## Installation

Clone the repository:
```bash
git clone https://github.com/Ti8an/CrypTar.git
```

Enter the project directory:
```bash
cd CrypTar
```

Make the installer executable:
```bash
chmod +x install.sh
```

Run the installer:
```bash
./install.sh
```

The installer checks for and installs the following dependencies if missing: `tar`, `gnupg`, `openssh-client`, `curl`, `jq`, `sshpass`.

> **Note:** `sshpass` is installed with a warning — SSH key authentication is strongly preferred over password auth.

`curl` and `jq` are only needed by the `--cloud` commands; if they are missing, those commands stop with an error naming the package to install. The installer never asks for cloud/OAuth credentials.

---

## Commands

| Command | Description |
|---|---|
| `crypTar <path>` | Archive and encrypt a file or directory |
| `crypTar -s <path>` | Archive, encrypt, and send to a remote server |
| `crypTar -d <file.tar.gz.gpg>` | Decrypt and extract an archive |
| `crypTar --server list` | List configured servers |
| `crypTar --server add` | Add a new server (interactive wizard) |
| `crypTar --server remove` | Remove a server |
| `crypTar --server push-key` | Push a GPG key to a server |
| `crypTar --server set-key` | Change the config encryption key (servers and clouds) |
| `crypTar --cloud add` | Add a cloud connection (interactive wizard) |
| `crypTar --cloud list [--check]` | List cloud connections (`--check` verifies each one live) |
| `crypTar --cloud remove [name\|index]` | Remove a cloud connection (local config only) |
| `crypTar --cloud test [name\|index\|--all]` | Check authorization and destination folder access |
| `crypTar --cloud send [--to n1,n2] <path>` | Upload an encrypted archive, or archive + encrypt + upload |
| `crypTar --cloud reauth [name\|index]` | Re-authorize a connection (expired/revoked token) |
| `crypTar --version` | Print the version |
| `crypTar -h \| --help` | Show help |

---

## Usage examples

Encrypt a directory:
```bash
crypTar ~/projects/myApp
```
→ `myApp_25_05_2026_14_30_00.tar.gz.gpg`

Decrypt an archive:
```bash
crypTar -d myApp_25_05_2026_14_30_00.tar.gz.gpg
```

Encrypt and send to a server in one step:
```bash
crypTar -s ~/projects/myApp
```

Add a remote server:
```bash
crypTar --server add
```

List configured servers:
```bash
crypTar --server list
```

Push your GPG key to a server (so it can decrypt archives there):
```bash
crypTar --server push-key
```

Change the GPG key used to encrypt the server and cloud configs:
```bash
crypTar --server set-key
```

Archive, encrypt and upload to two cloud accounts at once:
```bash
crypTar --cloud send --to google-work,yandex-backup ~/projects/myApp
```

---

## Cloud storage (Google Drive, Yandex Disk)

CrypTar can upload encrypted archives to any number of cloud **connections**. A connection is one authorized account of one provider plus a destination folder, identified by a unique name you choose — so several accounts of the same provider can coexist:

| ID | Name | Provider | Account |
|---|---|---|---|
| 1 | google-work | Google Drive | work@example.com |
| 2 | google-personal | Google Drive | me@gmail.com |
| 3 | yandex-backup | Yandex Disk | my-login |

Only already-encrypted `.gpg` archives ever leave the machine.

### How authorization works

Both providers use the official **OAuth 2.0 device authorization flow**: CrypTar shows a URL and a short code, you open the URL on any device (phone, laptop), sign in and approve access. CrypTar never sees your account password, does not need a local web server or a redirect URI, and works over SSH on headless backup hosts.

You need your own OAuth application (client ID + client secret) for each provider. It is created once and can be reused for all accounts of that provider.

### Google Drive: OAuth setup

1. Open the [Google Cloud Console](https://console.cloud.google.com/) and create (or select) a project.
2. **APIs & Services → Library** → enable **Google Drive API**.
3. **Google Auth Platform / OAuth consent screen**: choose *External* user type, fill in the app name and contact e-mail, and add the scope `https://www.googleapis.com/auth/drive.file`.
   While the app is in *Testing* status, add every Google account you will connect under **Test users**.
4. **Credentials → Create credentials → OAuth client ID** → application type **TVs and Limited Input devices**. Copy the **Client ID** and **Client secret**.
5. Run `crypTar --cloud add`, choose *Google Drive* and enter the client ID / secret when asked.

Notes:
- CrypTar requests only the `drive.file` scope: it can see and manage **only the files and folders it created itself** — not the rest of your Drive.
- A device-flow client does not use a redirect URI; nothing needs to be configured there.
- Google expires refresh tokens of apps in *Testing* status after 7 days. For long-term unattended backups, set the app's publishing status to *In production* (`drive.file` is a non-sensitive scope), or run `crypTar --cloud reauth <name>` when the token expires.

### Yandex Disk: OAuth setup

1. Open [oauth.yandex.ru](https://oauth.yandex.ru/client/new) and create an application.
2. Under data access, add the Yandex Disk REST API permissions:
   - `cloud_api:disk.write` — create folders and upload files,
   - `cloud_api:disk.read` — check whether a file already exists / finished uploading,
   - `cloud_api:disk.info` — show the account login and free space.

   Alternatively grant only `cloud_api:disk.app_folder` and use a destination such as `app:/CrypTar` (the app's own folder).
3. If the form requires a platform and Redirect URI, choose *Web services* and use `https://oauth.yandex.ru/verification_code` — CrypTar's device-code flow does not use it.
4. Copy the **ClientID** and **Client secret** and enter them in `crypTar --cloud add` (choose *Yandex Disk*).

### Supplying OAuth client credentials

The `add` wizard takes the client ID / secret from, in this order:
1. environment variables `CRYPTAR_GDRIVE_CLIENT_ID` / `CRYPTAR_GDRIVE_CLIENT_SECRET` or `CRYPTAR_YADISK_CLIENT_ID` / `CRYPTAR_YADISK_CLIENT_SECRET`;
2. an existing connection of the same provider (you are asked to confirm);
3. interactive input (the secret is not echoed).

They are then stored in the encrypted cloud config together with the tokens. Without a client ID and secret the wizard stops with a setup error — nothing is saved.

### Adding connections

```bash
crypTar --cloud add
```

The wizard:
1. asks for the provider;
2. asks for a unique connection name — 1–64 characters `A-Z a-z 0-9 _ -`, starting with a letter or digit, not digits only (numbers are reserved for list indices). An existing name is never overwritten;
3. obtains the OAuth client (see above);
4. runs the device authorization and verifies the account is reachable;
5. asks for the destination folder (default `CrypTar` for Google Drive, `/CrypTar` for Yandex Disk) and creates it if needed;
6. saves the connection.

Run it again with another name to connect a second account of the same provider, e.g. `google-work` and `google-personal`.

### Listing, testing, removing

```bash
crypTar --cloud list            # status "configured": nothing verified
crypTar --cloud list --check    # live check: OK / AUTH ERROR / NETWORK ERROR / ...
crypTar --cloud test google-work
crypTar --cloud test 2          # by list index
crypTar --cloud test --all
crypTar --cloud test            # interactive: pick one or several ("1,3", "1-3", "all")
crypTar --cloud remove yandex-backup
crypTar --cloud remove 3
crypTar --cloud remove          # interactive
crypTar --cloud reauth google-work
```

Names are the stable identifiers; indices (`ID` column of `list`) are a convenience and change when connections are added or removed. `remove` asks for confirmation and deletes **only** the local connection entry and its tokens — nothing is deleted in the cloud. To also revoke CrypTar's access, use [Google account permissions](https://myaccount.google.com/permissions) or the apps section of your Yandex ID security settings.

`test` checks authorization (refreshing the token), shows the account and free space, and verifies — creating if necessary — the destination folder.

### Uploading

Upload an existing encrypted archive (uploaded as-is, never re-encrypted):
```bash
crypTar --cloud send --to google-work backup_12_10_2026_20_00_00.tar.gz.gpg
```

Archive + encrypt + upload in one step (same archive/encryption code and naming as `crypTar <path>`):
```bash
crypTar --cloud send --to google-work,yandex-backup ~/Documents
```

Several destinations: comma-separated and/or repeated `--to` (`--to a --to=b`). Without `--to`, an interactive multi-select menu is shown.

How the input is interpreted:
- a regular file named `*.gpg` whose header is an OpenPGP encrypted message → uploaded directly;
- a file named `*.gpg` that is **not** OpenPGP-encrypted → rejected (rename it if you want it archived);
- any other file or a directory → archived and encrypted with your GPG key first.

Behaviour:
- every `--to` name must match a connection exactly; unknown names abort the command before anything is archived or uploaded;
- the same local file is uploaded to every destination (no extra copies); a failure at one destination does not stop the others; a per-destination result table is printed;
- archives created by `send` follow the `crypTar -s` convention: when **all** uploads succeed you are asked whether to delete the local copy; if any upload fails, the archive is always kept in the current directory. An archive you passed in is never modified or deleted;
- **filename conflicts**: an existing remote file is never overwritten — the upload gets a free name with a numeric suffix (`name-1.tar.gz.gpg`, `name-2.tar.gz.gpg`, …).

Exit codes of `send`: `0` all uploads succeeded, `3` some failed, `1` all failed or invalid input. `test` with a single connection returns the specific error code (`10` auth, `11` permission, `12` network, `13` rate limit, `14` quota, `16` configuration).

### Destination folders

- **Google Drive** addresses folders by ID. CrypTar stores the folder path you entered (e.g. `CrypTar` or `Backups/CrypTar`) and the resolved folder ID; if that folder is deleted or trashed, it is found again or recreated automatically on the next upload.
- **Yandex Disk** addresses resources by path: `/CrypTar`, `disk:/Backups/CrypTar`, or `app:/CrypTar` (app folder). Missing folders are created level by level.

### Reliability

- Transient errors (network failures, timeouts, HTTP 429/5xx, Google rate-limit 403) are retried up to 4 times with exponential backoff (1, 2, 4, 8 s), honouring `Retry-After`. Permanent errors (auth, permissions, quota, bad requests) are not retried. Override with `CRYPTAR_CLOUD_MAX_RETRIES`.
- Google Drive uploads use a **resumable upload session**: after an interruption CrypTar asks the server how many bytes arrived and continues from there (an expired session is restarted once).
- Yandex Disk: if an upload is interrupted, CrypTar first checks whether the file already landed (same size) before uploading again with a fresh upload link. `202 Accepted` responses are followed until the file is stored.
- Folder creation on Google Drive is not blindly repeated: after a failed create, CrypTar looks for the folder before trying again.

### Where configuration and credentials are stored

| File | Contents |
|---|---|
| `~/.config/cryptar/clouds.conf.gpg` | Cloud connections: provider, account, folder, folder ID, OAuth client ID/secret, tokens — GPG-encrypted, `chmod 600` |
| `~/.config/cryptar/servers.conf.gpg` | SSH servers (unchanged) |
| `~/.config/cryptar/.gpg_key_id` | ID of the GPG key that encrypts both configs |

The cloud config uses the same encrypted-INI format, GPG key, lock file and atomic write (`*.tmp` + rename) as the server config, but is a separate file, so cloud connections never appear in `--server` commands. `crypTar --server set-key` re-encrypts both files.

Stored tokens: Google — refresh token only (access tokens live in memory for one run); Yandex — access token, refresh token and expiry (refreshed one day before expiry).

### Troubleshooting

CLI messages are in Russian; the exit code of `crypTar --cloud test <name>` or the `list --check` status identifies the case.

| Symptom (exit code / list status) | Fix |
|---|---|
| Missing dependencies `curl` / `jq` (exit 16) | `sudo apt-get install curl jq` or re-run `install.sh` |
| OAuth client not configured (exit 16) | Create the OAuth app (see above) and enter client ID/secret, or set the `CRYPTAR_*_CLIENT_ID/SECRET` variables |
| `invalid_client` — configuration error (exit 16) | Wrong client ID/secret, or the Google client is not of type *TVs and Limited Input devices* |
| Authorization error (exit 10, `AUTH ERROR`) | Token expired or revoked: `crypTar --cloud reauth <name>` (Google *Testing* apps: tokens last 7 days) |
| Insufficient permissions (exit 11, `NO ACCESS`) | Missing scope/rights: check the app permissions, then `reauth` |
| Not enough cloud storage (exit 14, `QUOTA FULL`) | Free space or choose another connection |
| File exceeds provider limit (exit 18) | Yandex Disk: 1 GB per file (50 GB with Yandex 360) |
| Rate limit (exit 13, `RATE LIMITED`) | Wait a few minutes and retry |
| Network error or timeout (exit 12, `NETWORK ERROR`) | Check connectivity / proxy; uploads resume where possible |
| Cannot decrypt `clouds.conf.gpg` | The GPG secret key that encrypted the config is not in your keyring |

### Limitations

- The first authorization of each connection is interactive (a browser on any device is required); later runs are unattended.
- Uploads to several destinations run sequentially.
- No download/restore, remote listing or remote retention cleanup — use the provider's web UI.
- Google Drive `drive.file` scope: a folder you created manually in Drive is invisible to CrypTar; CrypTar creates its own folder (which may have the same name).
- Yandex Disk has no resumable-upload API: an interrupted upload is restarted from the beginning (after checking it did not already complete).
- Name-conflict checks on Google Drive are best effort against *concurrent* uploads of the same name (Drive allows duplicate names; nothing is ever overwritten).

### Manual integration test (optional)

Automated tests mock all HTTP traffic. To verify against real services, use **dedicated test accounts**:

1. Create OAuth apps as described above (Google: add the test account as a test user).
2. `crypTar --cloud add` → Google Drive → `gtest1`; repeat with a second Google account → `gtest2`; add Yandex → `ytest`.
3. `crypTar --cloud list --check` → all `OK`.
4. `crypTar --cloud send --to gtest1,gtest2,ytest /etc/hostname` → three `OK` rows; the archive appears in each destination folder.
5. Run the same `send` with an existing archive twice → the second upload gets a `-1` suffix.
6. Delete the destination folder in the Drive web UI → `crypTar --cloud test gtest1` recreates it.
7. Revoke access (Google permissions page) → `crypTar --cloud test gtest1` reports an authorization error → `crypTar --cloud reauth gtest1` restores it.
8. Download one uploaded archive and run `crypTar -d` on it → contents match.
9. `crypTar --cloud remove gtest2` → only the local entry disappears; the files stay in Drive.

---

## Project structure

```
app/
├── crypTar                  # Main executable
├── VERSION                  # Version file
├── install.sh               # Installer
├── src/
│   ├── lib/
│   │   ├── config.sh        # Encrypted INI config (servers; shared crypto/locking)
│   │   ├── cloud.sh         # Cloud connections, HTTP/retries, multi-upload
│   │   ├── creds.sh         # Credential load / unload
│   │   └── transfer.sh      # File transfer (rsync / scp)
│   ├── providers/
│   │   └── cloud/
│   │       ├── google_drive.sh  # Google Drive API v3
│   │       └── yandex_disk.sh   # Yandex Disk REST API
│   ├── commands/
│   │   ├── encrypt.sh       # cmd_encrypt, cmd_archive_and_encrypt
│   │   ├── decrypt.sh       # cmd_decrypt
│   │   ├── send.sh          # cmd_send, cmd_send_all
│   │   ├── server/
│   │   │   ├── add.sh       # srv_add
│   │   │   ├── list.sh      # srv_list
│   │   │   ├── remove.sh    # srv_remove
│   │   │   ├── push_key.sh  # srv_push_key
│   │   │   ├── set_key.sh   # srv_set_key
│   │   │   └── dispatch.sh  # Routes --server <subcommand>
│   │   └── cloud/
│   │       ├── add.sh       # cloud_add, cloud_reauth
│   │       ├── list.sh      # cloud_list
│   │       ├── remove.sh    # cloud_remove
│   │       ├── test.sh      # cloud_test
│   │       ├── send.sh      # cloud_send
│   │       └── dispatch.sh  # Routes --cloud <subcommand>
│   └── utils/
│       ├── log.sh           # log_ok / log_err / log_step / log_info
│       ├── ui.sh            # ui_prompt / ui_select / ui_confirm / ui_secret
│       └── ssh.sh           # ssh_exec / scp_send / ssh_test_conn
└── tests/
    ├── test_config.sh           # Unit tests for config.sh
    ├── test_transfer.sh         # Unit tests for transfer.sh
    ├── test_commands.sh         # CLI integration tests
    ├── test_cloud.sh            # Unit tests for cloud.sh
    ├── test_cloud_providers.sh  # Google Drive / Yandex Disk with mocked HTTP
    ├── test_cloud_commands.sh   # --cloud commands + backward compatibility
    └── cloud_helper.bash        # Shared fixtures / HTTP mock
```

New providers are added as `src/providers/cloud/<file>.sh` implementing `<id>_auth`, `<id>_account`, `<id>_ensure_folder`, `<id>_test`, `<id>_upload`, `<id>_default_folder`, `<id>_normalize_folder`, and registered in `CLOUD_PROVIDER_IDS` / `_cloud_provider_file` in `src/lib/cloud.sh`.

---

## Tests

### Installing bats-core

```bash
git submodule add https://github.com/bats-core/bats-core.git tests/bats
git submodule add https://github.com/bats-core/bats-support.git tests/test_helper/bats-support
git submodule add https://github.com/bats-core/bats-assert.git tests/test_helper/bats-assert
```

Or install globally via a package manager:

Debian / Ubuntu:
```bash
sudo apt-get install bats
```

macOS:
```bash
brew install bats-core
```

### Running the tests

Run all tests (test files use the `.sh` extension, so list them explicitly):
```bash
bats tests/*.sh
```

Run a single file:
```bash
bats tests/test_config.sh
```

Tests create an isolated GPG keyring in a temporary directory (`GNUPGHOME=$(mktemp -d)`) and never touch the developer's real keyring. Cloud tests mock every HTTP request — no cloud account, token or network access is needed. Config tests need `flock` (util-linux) and cloud tests need `jq`; they are skipped when these are unavailable.

---

## Security

- **Encryption:** asymmetric only (GPG public key). Symmetric passphrases are never used.
- **Server credentials:** stored in an encrypted INI file under `~/.config/cryptar/`, readable only by the owner (`chmod 700`).
- **Cloud credentials:** OAuth client secrets and tokens are stored only in the GPG-encrypted `clouds.conf.gpg` (`chmod 600`). CrypTar never asks for cloud account passwords (OAuth device flow) and requests minimal scopes (Google `drive.file`).
- **No secrets on the command line:** curl receives the URL, headers, bearer token and request body through a configuration file descriptor (`curl -K <(...)`), so they never appear in `ps` output; config values are written with shell builtins only. Upload links and session URIs are treated the same way.
- **No secrets in logs:** provider error messages are passed through a redaction filter; token responses, authorization codes and headers are never printed; shell tracing (`set -x`) is suspended inside cloud commands.
- **Temporary files:** created in `/dev/shm` (RAM-backed tmpfs) when available, minimising the time decrypted data spends on disk; HTTP responses (which may contain tokens) are shredded immediately after parsing.
- **sshpass:** the SSH password is passed via the `SSHPASS` environment variable rather than as a command-line argument, so it never appears in `ps aux`. SSH key authentication is strongly recommended.
- **Key rotation:** to change the GPG key used to encrypt the configs, run `crypTar --server set-key` — it decrypts both the server and the cloud config with the old key and re-encrypts them with the new one atomically. To push your public key to remote servers so they can decrypt archives, use `crypTar --server push-key`.
- **Environment variables:** `CRYPTAR_*_CLIENT_SECRET` are convenient for setup but visible to processes of the same user; prefer interactive input on shared machines.

---

## About

CrypTar is a Bash tool for automating backup archiving and data encryption. Built with ❤️ in Bash.
