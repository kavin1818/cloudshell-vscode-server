# code-server on Google Cloud Shell

Start [code-server](https://github.com/coder/code-server) (VS Code in the browser) inside [Google Cloud Shell](https://cloud.google.com/shell/docs), with a workspace folder you choose.

The Cloud Shell VM is ephemeral. Only `$HOME` is persisted. This script installs a standalone `code-server` build into `~/.local` so it survives session recycle, then binds it to Cloud Shell Web Preview.

## Features

- Detects an existing `code-server` binary before installing
- Standalone install into `$HOME` (not `apt`, which is lost on VM recycle)
- Opens the folder you pass as the workspace
- Default port `8080`; any Cloud Shell preview port in `2000–65000`
- Per-port PID, log, and metadata files
- `--status` and `--stop` for day-to-day operations
- Waits for `/healthz` before printing the preview URL

## Prerequisites

- A Google Cloud Shell session (bash 4+)
- `curl` (preinstalled on Cloud Shell)
- Network access to download the official installer on first run

## Quick start

In Cloud Shell:

```bash
chmod +x setup-code-server.sh
./setup-code-server.sh ~/my-project
```

Then open the printed preview URL, or use **Web Preview** in the Cloud Shell toolbar and select the port.

```bash
./setup-code-server.sh ~/my-project 3000
./setup-code-server.sh --port 8080 ~/my-project
```

The workspace directory is required. It is created if it does not already exist.

## Command reference

```text
./setup-code-server.sh [OPTIONS] WORKSPACE_DIR [PORT]
./setup-code-server.sh --status [--port PORT]
./setup-code-server.sh --stop [--port PORT]
```

| Option | Description |
| --- | --- |
| `WORKSPACE_DIR` | Directory opened as the VS Code workspace |
| `PORT` | Listen port (default `8080`) |
| `-p`, `--port PORT` | Same as positional port; wins if both are given |
| `--status` | Print running state, PID, workspace, and health |
| `--stop` | Stop the instance on the chosen port |
| `-h`, `--help` | Show usage |
| `-V`, `--version` | Show script version |

### Operations

```bash
./setup-code-server.sh --status
./setup-code-server.sh --status --port 3000
./setup-code-server.sh --stop
./setup-code-server.sh --stop --port 3000
```

`--status` exits `0` when code-server is running, `1` when it is not.

## How it works

1. Resolves `code-server` from `PATH`, then `~/.local/bin/code-server`.
2. If missing, downloads the [official installer](https://code-server.dev/install.sh) to a temp file and runs it with `--method=standalone`.
3. Stops any code-server already bound to the target port.
4. Starts:

   ```bash
   code-server \
     --bind-addr 0.0.0.0:<port> \
     --auth none \
     --trusted-origins "*" \
     --ignore-last-opened \
     <workspace>
   ```

5. Waits until `http://127.0.0.1:<port>/healthz` succeeds, then prints the preview URL.

`--ignore-last-opened` ensures the folder you passed is opened, not the last workspace.

If `WEB_HOST` is set (Cloud Shell), the script also exports `VSCODE_PROXY_URI` so the Ports panel can preview other local servers.

## Security

Cloud Shell Web Preview is already authenticated as your Google account and is not a public bind. The script therefore starts code-server with `--auth none`.

Do not run this with `--auth none` on a host that is reachable from the internet. If the environment does not look like Cloud Shell, the script warns and continues.

`--trusted-origins "*"` is required so websockets work behind the Cloud Shell preview hostname (`8080-….cloudshell.dev`).

## Files

State is stored per port under `~/.local/share/code-server-cloud-shell/`:

| File | Purpose |
| --- | --- |
| `code-server-<port>.pid` | Daemon PID |
| `code-server-<port>.log` | stdout/stderr |
| `code-server-<port>.meta` | Workspace, bind address, start time |

The standalone binary lives in `~/.local/bin/code-server`.

## Environment

| Variable | Meaning |
| --- | --- |
| `NO_COLOR` | Disable ANSI colors when set |
| `CODE_SERVER_READY_TIMEOUT` | Seconds to wait for `/healthz` (default `20`) |

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success (`--status`: process is running) |
| `1` | Runtime error (`--status`: not running) |
| `2` | Usage error |
| `3` | Requested port is in use by a non-code-server process |
| `4` | code-server started but did not become ready |

## Troubleshooting

**Preview page is blank or websockets fail.** Confirm you opened the Cloud Shell preview URL for the same port, not `localhost`. Check the log:

```bash
tail -n 50 ~/.local/share/code-server-cloud-shell/code-server-8080.log
```

**Port already in use.** Stop the existing instance, or choose another port:

```bash
./setup-code-server.sh --stop --port 8080
./setup-code-server.sh ~/my-project 8081
```

**code-server is gone after a new Cloud Shell session.** The VM was recycled and a previous install used `apt`. Re-run this script; the standalone install under `~/.local` is persistent.

**Install fails.** Confirm outbound HTTPS to `code-server.dev` is allowed, then retry.

## Uninstall

Stop the server, then remove the standalone install and this script’s state:

```bash
./setup-code-server.sh --stop
rm -f ~/.local/bin/code-server
rm -rf ~/.local/lib/code-server-* \
       ~/.local/share/code-server-cloud-shell \
       ~/.config/code-server
```
