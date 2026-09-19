# code-server Manager

A security-focused Bash lifecycle manager for a single, user-owned [code-server](https://github.com/coder/code-server) instance. It starts code-server in a chosen workspace, maintains private state, and provides safe `start`, `stop`, and `status` operations.

## What it does

- Requires a non-default password of at least 12 characters; secrets are never printed or passed to code-server on its command line.
- Uses `0.0.0.0` by default so Cloud Shell's port proxy can reach it; restrict the surrounding network and use a TLS-terminating reverse proxy outside Cloud Shell.
- Writes configuration, logs, runtime state, and code-server data into owner-only directories and files.
- Uses a non-blocking lock and validates the PID's owner and command line before signalling it, avoiding global `pkill` behaviour.
- Handles stale PID files, performs a graceful shutdown, and only escalates to `SIGKILL` after 30 seconds.
- Emits newline-delimited JSON structured lifecycle logs to stderr and writes code-server output to a dedicated log file.

## Prerequisites

- Bash 4.1+ (the script re-executes under Bash even when launched with `sh`).
- `code-server`, `realpath`, `flock`, `stat`, `ps`, and standard GNU/Linux userland tools available on `PATH`.
- A local workspace directory you are authorized to read and write.

Install code-server using its official installation guidance before using this repository.

## Quick start

Make the script executable and start a workspace. The password is supplied through an environment variable so it does not appear in shell history or the process argument list:

```bash
chmod 700 code-server.sh
CODE_SERVER_PASSWORD='replace-with-a-long-unique-secret' \
  ./code-server.sh start --folder /srv/projects/my-app
```

In Google Cloud Shell, use the **Web Preview / Preview on port 8080** control after startup. The default `0.0.0.0` listener is required for Cloud Shell's port proxy. Outside Cloud Shell, use a TLS reverse proxy or bind to loopback and create an SSH tunnel.

```bash
ssh -L 8080:127.0.0.1:8080 user@server.example
```

Visit `http://127.0.0.1:8080` in the browser running the SSH client.

## Command reference

```text
./code-server.sh [start|stop|status] [options]
```

| Option | Purpose |
| --- | --- |
| `--folder PATH`, `-f PATH` | Workspace to open. Defaults to the current directory for `start`. |
| `--port PORT`, `-p PORT` | Listener port from 1 through 65535. Defaults to `8080`. |
| `--bind-addr ADDR`, `-b ADDR` | Listener hostname or IPv4 address. Defaults to `0.0.0.0` for Cloud Shell port proxy compatibility. |
| `--password-file FILE` | Reads a password from an owner-only regular file. Group/other permissions are rejected. |
| `--public` | Explicitly bind to `0.0.0.0` (the default). Use only with network access controls. |

`stop` and `status` do not need a password. `status` exits with code `3` when the managed instance is not running, which is useful for automation.

## Configuration and operations

The following environment variables mirror command-line options:

```bash
export CODE_SERVER_PASSWORD='replace-with-a-long-unique-secret'
export CODE_SERVER_PORT=8080
export CODE_SERVER_BIND_ADDR=0.0.0.0
export CODE_SERVER_STARTUP_TIMEOUT=15  # Optional: wait up to 1-300 seconds
./code-server.sh start
```

For non-interactive systems, store the secret in a file owned by the service user and mode `600` or stricter:

```bash
install -m 600 /dev/null "$HOME/.config/code-server-password"
printf '%s\n' 'replace-with-a-long-unique-secret' > "$HOME/.config/code-server-password"
./code-server.sh start --password-file "$HOME/.config/code-server-password"
```

By default, the manager uses these owner-only paths (honouring the corresponding XDG base-directory environment variables):

| Path | Contents |
| --- | --- |
| `~/.config/code-server/config.yaml` | code-server configuration, including its password; mode `600`. |
| `~/.local/state/code-server-manager/code-server.pid` | Managed process ID. |
| `~/.local/state/code-server-manager/code-server.log` | code-server stdout and stderr. |
| `~/.local/share/code-server-session` | code-server user data. |

Stop and inspect the managed process with:

```bash
./code-server.sh status
./code-server.sh stop
```

## Startup troubleshooting

The manager waits up to 15 seconds by default for code-server to remain running **and to accept an HTTP connection**. This prevents a false success when code-server exits shortly after its process starts. On failure, its structured error includes the exact command to inspect the service log:

```bash
tail -n 100 "$HOME/.local/state/code-server-manager/code-server.log"
```

Increase the wait for slow hosts or large extensions with `CODE_SERVER_STARTUP_TIMEOUT` (1 through 300 seconds). The script can be launched either directly or through `sh`; it immediately re-executes itself with Bash when necessary:

```bash
CODE_SERVER_PASSWORD='replace-with-a-long-unique-secret' sh code-server.sh -f /srv/projects/my-app
```

## Production deployment guidance

1. Run the script as a dedicated, unprivileged service account; do not run it as root.
2. In Cloud Shell, keep the default `0.0.0.0` listener so the managed port proxy works. Outside Cloud Shell, bind to `127.0.0.1` unless a reverse proxy provides HTTPS, authentication controls, and appropriate IP/network restrictions.
3. Protect backups because the generated config contains a password. Rotate the password by stopping the server and starting it with a new secret.
4. Use a supervisor such as systemd to restart the manager or invoke its `start` command at boot. Do not run concurrent manager invocations; the script deliberately rejects them.
5. Forward the JSON stderr logs and monitor `code-server.log` for service diagnostics.

## Verification

Run static syntax validation without starting code-server:

```bash
bash -n code-server.sh
```

If [ShellCheck](https://www.shellcheck.net/) is available, also run:

```bash
shellcheck code-server.sh
```

## License

This project is licensed under the [Apache License 2.0](LICENSE).
