[English](README.md) | [Русский](README.ru.md)

# CrypTar v1.1.3

**CrypTar** is a Bash tool for archiving, GPG-encrypting, and sending backups to remote servers over SSH.

---

## Installation

```bash
git clone https://github.com/Ti8an/CrypTar.git
cd CrypTar/app
chmod +x install.sh
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
| `crypTar --version` | Print the version |
| `crypTar -h \| --help` | Show help |

---

## Usage examples

```bash
# Encrypt a directory
crypTar ~/projects/myApp
# → myApp_25_05_2026_14_30_00.tar.gz.gpg

# Decrypt an archive
crypTar -d myApp_25_05_2026_14_30_00.tar.gz.gpg

# Encrypt and send to a server in one step
crypTar -s ~/projects/myApp

# Add a remote server
crypTar --server add

# List configured servers
crypTar --server list

# Push your GPG key to a server (so it can decrypt archives there)
crypTar --server push-key
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

```bash
# Debian / Ubuntu
sudo apt-get install bats

# macOS
brew install bats-core
```

### Running the tests

```bash
# Run all tests
bats tests/

# Run a single file
bats tests/test_config.sh
```

Tests create an isolated GPG keyring in a temporary directory (`GNUPGHOME=$(mktemp -d)`) and never touch the developer's real keyring.

---

## Security

- **Encryption:** asymmetric only (GPG public key). Symmetric passphrases are never used.
- **Server credentials:** stored in an encrypted INI file under `~/.config/cryptar/`, readable only by the owner (`chmod 700`).
- **Temporary files:** created in `/dev/shm` (RAM-backed tmpfs) when available, minimising the time decrypted data spends on disk.
- **sshpass:** the SSH password is passed via the `SSHPASS` environment variable rather than as a command-line argument, so it never appears in `ps aux`. SSH key authentication is strongly recommended.
- **Key rotation:** when changing your GPG key, push the new key to all servers with `crypTar --server push-key`.

---

## About

CrypTar is a Bash tool for automating backup archiving and data encryption. Built with ❤️ in Bash.
