# kcrun

`kcrun` reads secrets from the macOS Keychain, sets them as environment variables, and starts a command with those variables available. It is a small Swift command-line tool with no third-party dependencies.

[![Build and test](https://github.com/yutayamate/kcrun/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/yutayamate/kcrun/actions/workflows/build.yml) [![Latest release](https://img.shields.io/github/v/release/yutayamate/kcrun)](https://github.com/yutayamate/kcrun/releases/latest) [![License](https://img.shields.io/github/license/yutayamate/kcrun)](LICENSE)

## Use kcrun

Save each secret as a generic password in Keychain. The service name identifies the item when you run `kcrun`:

```sh
security add-generic-password -a "$USER" -s example-mcp-api-key1 -w
security add-generic-password -a "$USER" -s example-mcp-api-key2 -w
```

With no value after `-w`, `security` prompts for the secret instead of putting it in shell history. Give each item a unique service name; `kcrun` selects the first generic-password item matching that name.

Pass one or more environment-variable mappings, then `--`, then the command to run:

```sh
kcrun run \
  --env MCP_API_KEY1=example-mcp-api-key1 \
  --env MCP_API_KEY2=example-mcp-api-key2 \
  -- my-tool --option value
```

`NAME` must be a valid environment-variable name. Existing environment variables are inherited, and values loaded from Keychain override matching names. The command and its arguments follow `--`. The previous invocation without `run` remains supported. Run `kcrun --help` for a concise usage summary.

## Generate HTTP headers

For HTTP MCP servers, `kcrun generate` can return Keychain values as a JSON object suitable for Codex's `http_headers_helper`. The `--format`, `--header`, and `--bearer` options are only available to `generate`. Use `--header NAME=SERVICE` for a header whose value is the Keychain item as stored. Use `--bearer SERVICE` to create an `Authorization` header with the `Bearer ` scheme. Both header options can be repeated. `--format` selects the output format; `json` is currently the only supported value and the default:

```sh
kcrun generate --format json \
  --header X-API-Key=example-mcp-api-key1 \
  --bearer example-mcp-access-token
```

The command prints JSON to stdout, for example:

```json
{"Authorization":"Bearer …","X-API-Key":"…"}
```

Configure Codex to run it as the helper:

```toml
[mcp_servers.example]
url = "http://localhost:4444/mcp"
http_headers_helper = "/absolute/path/to/kcrun generate --format json --bearer grafana_service_account_token"
```

Replace the path with the location of the `kcrun` executable. The helper output necessarily contains the header values so Codex can send them; `generate` writes only JSON to stdout and sends errors to stderr. It resolves all requested Keychain items before writing output, so a failed lookup does not produce partial JSON. Do not redirect or log the generated output.

## Shell completion

`kcrun` can print completion code directly, so the shell can load it without you copying or opening a completion file. Add this to `~/.zshrc`:

```sh
command -v kcrun > /dev/null 2>&1 && source <(kcrun completion zsh)
```

For Bash, add this to `~/.bashrc`:

```sh
command -v kcrun > /dev/null 2>&1 && source <(kcrun completion bash)
```

Open a new shell or reload the relevant configuration file. Completion suggests kcrun options and command names after `--`; it does not query Keychain items.

## Secure an MCP server configuration

Codex can start a local stdio MCP server from `~/.codex/config.toml`. If the server needs a secret, a direct configuration may put its value in the file's `env` table:

```toml
[mcp_servers.example]
command = "/absolute/path/to/example-mcp-server"
args = ["--stdio"]
env = {
  MCP_API_KEY1 = "DANGEROUS_HARDCODED_SECRET_1",
  MCP_API_KEY2 = "DANGEROUS_HARDCODED_SECRET_2",
}
```

This is convenient, but the secret is stored in plain text in the Codex configuration file. To move it to macOS Keychain, save it as a generic password. Use the same account name used by `kcrun` (normally `$USER`):

```sh
security add-generic-password -a "$USER" -s example-mcp-api-key1 -w
security add-generic-password -a "$USER" -s example-mcp-api-key2 -w
```

With no value after `-w`, `security` prompts for the secret. Then replace the MCP entry's `command` and `args` with the following, removing the old `env` table:

```toml
[mcp_servers.example]
command = "/absolute/path/to/kcrun"
args = [
  "--env",
  "MCP_API_KEY1=example-mcp-api-key1",
  "--env",
  "MCP_API_KEY2=example-mcp-api-key2",
  "--",
  "/absolute/path/to/example-mcp-server",
  "--stdio",
]
```

Keep the server's existing arguments after `--`, and replace `/absolute/path/to/...` with the paths on your Mac. The left side of the `--env` mapping is the variable name the server expects; the right side is the Keychain service name. Codex starts `kcrun`, which reads the secret and starts the MCP server with both `MCP_API_KEY1` and `MCP_API_KEY2` set. The secret value is no longer stored in `~/.codex/config.toml`.

See the [Codex configuration reference](https://developers.openai.com/codex/config-reference/) for local MCP server settings.

## What kcrun does

`kcrun run` reads every requested Keychain item before starting the command. If a mapping is invalid, a value cannot be read, or a Keychain item is missing, the command is not started. Secret values are not printed by `run`; diagnostics go to stderr, and stdout is left for the command. `kcrun` replaces itself with the command, so the command's exit status is returned directly. `generate` is a separate helper mode: it prints the requested headers as JSON to stdout.

## Security considerations

### What this helps protect against

Credentials can end up in local project files and tool settings. Examples include `.env` files; Codex's `~/.codex/config.toml` when an MCP server's `env` table contains secret values; and shell history when credentials are typed directly into commands. The AWS CLI stores access keys in the plaintext `~/.aws/credentials` file by default. SSH private keys are also often kept as files under `~/.ssh`. [Codex configuration reference](https://developers.openai.com/codex/config-reference/), [AWS shared config and credentials files](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html), [MITRE ATT&CK: credentials in files](https://attack.mitre.org/techniques/T1552/001/), [shell history](https://attack.mitre.org/techniques/T1552/003/), and [private keys](https://attack.mitre.org/techniques/T1552/004/).

Keeping a secret in Keychain and supplying it only when starting a command can reduce its exposure to bulk collection of project and configuration files. The secret value is not included in `kcrun`'s command-line arguments or written by `kcrun` to a configuration file.

### What this does not protect against

This is a way to reduce where secrets are stored; it does not make a compromised Mac safe. Information stealers commonly target saved browser credentials, cookies, and other session data. Although browser password databases may be encrypted, malware running as the logged-in user can sometimes extract credentials from them. Attackers also target local credential files, private keys, shell history, and macOS Keychain itself. [MITRE ATT&CK: browser credentials](https://attack.mitre.org/techniques/T1555/003/), [Keychain](https://attack.mitre.org/techniques/T1555/001/), and the [Australian Cyber Security Centre's information-stealer guidance](https://www.cyber.gov.au/guidance/learn-about-information-stealer-malware).

With `run`, the secret must be present in the child process's environment while it runs. The child and its descendants can read it, and software with sufficient access may inspect process environments. A child can also log or transmit the value. With `generate`, the secret is emitted as JSON to stdout for the helper protocol and is then available to the caller. Keychain access controls, a secure macOS account, and trust in the consuming program remain essential.

## Build from source

You need Swift Command Line Tools; the full Xcode application is not required. From the repository root, run:

```sh
swiftc -O -framework Security Sources/kcrun/main.swift -o kcrun
```

The resulting `kcrun` executable is created in the current directory.

## Automated builds and tests

GitHub Actions builds and tests the project on macOS for branch pushes, pull requests, and manual runs. Tagged releases build and test native Intel (`x86_64`) and Apple Silicon (`arm64`) binaries. Each GitHub Release includes both binaries, an SPDX JSON SBOM and a Sigstore bundle for each, and `SHA256SUMS`.

To download the latest release and verify its checksums, cosign signature, and GitHub provenance for your Mac's architecture, install the GitHub CLI and cosign, then run:

```sh
mkdir -p "$HOME/Downloads/kcrun"
gh release download --repo yutayamate/kcrun \
  --pattern 'kcrun-macos-*' \
  --pattern SHA256SUMS \
  --dir "$HOME/Downloads/kcrun"
cd "$HOME/Downloads/kcrun"
shasum -a 256 -c SHA256SUMS
binary="kcrun-macos-$(uname -m)"
cosign verify-blob "$binary" \
  --bundle "$binary.sigstore.json" \
  --certificate-identity-regexp '^https://github.com/yutayamate/kcrun/.github/workflows/release.yml@refs/tags/v.*$' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
gh attestation verify "$binary" --repo yutayamate/kcrun
```

`gh release download` without a tag selects the latest release. Cosign verifies the binary's integrity and that it was signed by this repository's tagged release workflow. The GitHub attestation check verifies that GitHub linked the binary to this repository's release build. Cosign signatures do not replace Apple Developer ID code signing or notarization; the binaries are not Apple Developer ID signed or notarized.

Run the integration tests locally on macOS after building:

```sh
Tests/integration.sh ./kcrun
```

The tests create Keychain items containing dummy values, check multiple environment mappings, verify stdout and child exit status, and confirm that a missing item does not start the command. The temporary items are deleted when the tests finish.

## License

MIT. See [LICENSE](LICENSE).
