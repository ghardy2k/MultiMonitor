# MultiMonitor

A portable Windows performance dashboard. One PowerShell script serves a browser UI and reads performance counters from the local machine and from remote Windows hosts. No install, no runtime, no database.

It is meant for watching a small farm — web servers, SQL servers, app boxes — from one screen, with live charts, thresholds, and saved layouts.

## What you get

- A single-page dashboard (`dashboard.html`) with light and dark themes.
- Live charts for CPU, memory, disk, network, IIS / ASP.NET, and SQL Server counters.
- Per-machine metric sets, warning and critical thresholds, and a compare view.
- Saved dashboard configs as JSON files in `configs/`.
- A tiny HTTP agent (`MultiMonitor.ps1`) that exposes those counters as JSON.

Built-in layouts cover essentials, a web server, a SQL server, and a deeper counter set. You can also add a custom counter path, such as connections on a named IIS site.

## Requirements

- Windows
- Windows PowerShell 5.1 or later (the one that ships with Windows)
- For remote machines, the account running the agent needs to be in **Performance Monitor Users** or **Administrators** on the target, and the **Remote Registry** service must be running there

Nothing else to install.

## Run it

From this folder:

```bat
Start-MultiMonitor.cmd
```

Or directly:

```powershell
.\MultiMonitor.ps1
```

That listens on `http://localhost:8765/` and opens the dashboard. Extra arguments are passed through:

```bat
Start-MultiMonitor.cmd -Port 9000 -NoBrowser
```

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-Port` | `8765` | TCP port |
| `-NoBrowser` | off | Do not open the dashboard on start |
| `-AllowRemote` | off | Listen on all interfaces so other machines can use this one as an agent |
| `-ApiKey` | empty | Shared secret callers must send in the `X-MM-Key` header |
| `-MaxThreads` | `16` | Request workers (2–64) |

`-AllowRemote` requires `-ApiKey`. The agent will refuse to start without one, so it is not left open on the network. Listening on `http://+:PORT/` also needs an elevated prompt, or a URL reservation:

```bat
netsh http add urlacl url=http://+:8765/ user=DOMAIN\user
```

```powershell
.\MultiMonitor.ps1 -AllowRemote -ApiKey 'choose-a-secret' -Port 9000 -NoBrowser
```

## HTTP API

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/ping` | Agent identity and health |
| `POST` | `/api/sample` | Read counters. Body: `{ "computer", "paths" }` |
| `GET` | `/api/sysinfo?computer=NAME` | OS, CPU, RAM, disks via CIM |
| `GET` | `/api/sets?computer=NAME` | Counter-set catalog |
| `GET` | `/api/configs` | List saved dashboard configs |
| `GET` | `/api/configs/NAME` | Read one config |
| `PUT` | `/api/configs/NAME` | Save a config (JSON body) |

Remote reads use the Windows identity of the account running the script (`Get-Counter -ComputerName` and CIM). One slow host does not block the rest of the dashboard; requests run on a worker pool.

## Configs

Configs live in `configs/` and use schema `multimonitor-config`. `configs/sample-webfarm.json` is a starting point: this PC, a web server, and a SQL server, plus one custom IIS counter.

The dashboard can list, load, and save these files through the API. Host names in the sample (`WEB01`, `SQL01`) are placeholders.

## Files

| File | Role |
| --- | --- |
| `MultiMonitor.ps1` | Agent and HTTP server |
| `Start-MultiMonitor.cmd` | Double-click launcher |
| `dashboard.html` | The UI |
| `configs/` | Saved dashboards |
| `sample.txt` | Placeholder note, not required to run |

## Security

By default the agent binds to localhost only. Turn on remote access only with an API key, and only on a network you trust. The key is a shared header secret, not a user login. Do not commit real hub keys or production host names if you publish a copy of your configs.
