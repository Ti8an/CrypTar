[English](README.md) | [Русский](README.ru.md)

# CrypTar

**CrypTar** is a Bash tool for archiving, GPG-encrypting, and sending backups to remote servers over SSH.

---

## Installation

Clone the repository:
```bash
git clone https://github.com/Ti8an/CrypTar.git
```

Enter the project directory:
```bash
cd CrypTar/app
```

Make the installer executable:
```bash
chmod +x install.sh
```

Run the installer:
```bash
./install.sh
```

The installer checks for and installs the following dependencies if missing: `tar`, `gnupg`, `openssh-client`, `sshpass`.

> **Note:** `sshpass` is installed with a warning — SSH key authentication is strongly preferred over password auth.

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
| `crypTar --server set-key` | Change the config encryption key |
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

Change the GPG key used to encrypt the server config:
```bash
crypTar --server set-key
```

---

## Project structure

```
app/
├── crypTar                  # Main executable
├── VERSION                  # Version file (2.0.0)
├── install.sh               # Installer
├── src/
│   ├── lib/
│   │   ├── config.sh        # Encrypted INI config for servers
│   │   ├── creds.sh         # Credential load / unload
│   │   └── transfer.sh      # File transfer (rsync / scp)
│   ├── commands/
│   │   ├── encrypt.sh       # cmd_encrypt, cmd_archive_and_encrypt
│   │   ├── decrypt.sh       # cmd_decrypt
│   │   ├── send.sh          # cmd_send, cmd_send_all
│   │   └── server/
│   │       ├── add.sh       # srv_add
│   │       ├── list.sh      # srv_list
│   │       ├── remove.sh    # srv_remove
│   │       ├── push_key.sh  # srv_push_key
│   │       ├── set_key.sh   # srv_set_key
│   │       └── dispatch.sh  # Routes --server <subcommand>
│   └── utils/
│       ├── log.sh           # log_ok / log_err / log_step / log_info
│       ├── ui.sh            # ui_prompt / ui_select / ui_confirm / ui_secret
│       └── ssh.sh           # ssh_exec / scp_send / ssh_test_conn
└── tests/
    ├── test_config.sh       # Unit tests for config.sh
    ├── test_transfer.sh     # Unit tests for transfer.sh
    └── test_commands.sh     # CLI integration tests
```

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

Run all tests:
```bash
bats tests/
```

Run a single file:
```bash
bats tests/test_config.sh
```

Tests create an isolated GPG keyring in a temporary directory (`GNUPGHOME=$(mktemp -d)`) and never touch the developer's real keyring.

---

## Security

- **Encryption:** asymmetric only (GPG public key). Symmetric passphrases are never used.
- **Server credentials:** stored in an encrypted INI file under `~/.config/cryptar/`, readable only by the owner (`chmod 700`).
- **Temporary files:** created in `/dev/shm` (RAM-backed tmpfs) when available, minimising the time decrypted data spends on disk.
- **sshpass:** the SSH password is passed via the `SSHPASS` environment variable rather than as a command-line argument, so it never appears in `ps aux`. SSH key authentication is strongly recommended.
- **Key rotation:** to change the GPG key used to encrypt the server config, run `crypTar --server set-key` — it decrypts with the old key and re-encrypts with the new one atomically. To push your public key to remote servers so they can decrypt archives, use `crypTar --server push-key`.

---

## About

CrypTar is a Bash tool for automating backup archiving and data encryption. Built with ❤️ in Bash.
