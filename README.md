# NXYTDL

```
  ███╗   ██╗██╗  ██╗██╗   ██╗████████╗██████╗ ██╗
  ████╗  ██║╚██╗██╔╝╚██╗ ██╔╝╚══██╔══╝██╔══██╗██║
  ██╔██╗ ██║ ╚███╔╝  ╚████╔╝    ██║   ██║  ██║██║
  ██║╚██╗██║ ██╔██╗   ╚██╔╝     ██║   ██║  ██║██║
  ██║ ╚████║██╔╝ ██╗   ██║      ██║   ██████╔╝███████╗
  ╚═╝  ╚═══╝╚═╝  ╚═╝   ╚═╝      ╚═╝   ╚═════╝ ╚══════╝
```

**A no-fuss YouTube downloader with a dark-theme web UI, real-time progress, proxy support, and automatic zip packaging.**

Built on FastAPI + HTMX — no JavaScript framework, no build step, no Electron. Just a Python server you run locally and a browser tab you keep open.

---

## What it does

NXYTDL gives you a persistent, queue-based download manager in a browser tab. You search, curate a list, pick a quality, and hit Download. The server streams yt-dlp output line-by-line back to the page so you can watch progress in real time. When a job finishes, the files are zipped and ready to serve as a single download.

- **Search YouTube** — yt-dlp powered search with title, thumbnail, and duration
- **Queue management** — add from search results, paste a URL, or drop in a full playlist
- **Three quality presets** — 1080p MKV, 720p MKV, MP3 audio
- **Real-time progress** — last five lines of yt-dlp output, stall detection after 20 s of silence
- **Smart deduplication** — skips videos already on disk (matched by `[VIDEO_ID]` in filename); zip append mode never overwrites existing files
- **Zip packaging** — every completed job is a `.zip` in `~/YouTubeDownloads/zips/` ready to serve or move
- **File browser** — browse, stream, download, or delete individual files and folders from the web UI
- **Proxy support** — route all yt-dlp traffic through a SOCKS5 proxy (configured in `data/config.json`)
- **Emoji stripping** — removes emoji characters from titles and filenames before saving

---

## Architecture

```
Browser (HTMX)
      │  fetch / htmx-swap
      ▼
FastAPI :8888
      │
      ├── Jinja2 templates (partial-swap pattern — no full page reloads)
      ├── JSON state (data/current_selection.json, data/downloads.json)
      │
      └── ThreadPoolExecutor
                │
                └── bash -i -c "ytdl1080 <url>"
                          │
                          └── yt-dlp ──SOCKS5──▶ Proxy ──▶ YouTube
                                    │
                                    └── ~/YouTubeDownloads/<name>/
                                                │
                                                └── zipfile ──▶ ~/YouTubeDownloads/zips/<name>.zip
```

**Single-file backend** — all routes, helpers, and state management live in `main.py`. Templates follow a partial-swap pattern: every mutating endpoint returns a rendered HTML fragment that JS injects into a named container div. No JSON API, no client-side state, no framework.

Heavy work (yt-dlp invocation, zipping) runs in a `ThreadPoolExecutor` so it never blocks the async event loop.

---

## Prerequisites

| Dependency | Why |
|---|---|
| Python 3.10+ | Runtime |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Download engine |
| [ffmpeg](https://ffmpeg.org/) | Audio/video muxing |

---

## Installation

```bash
git clone https://github.com/yourname/nxytdl.git
cd nxytdl
bash setup.sh
```

`setup.sh` is a one-command installer that:

1. Verifies prerequisites (Python, yt-dlp, ffmpeg)
2. Installs Python dependencies (`pip install -r requirements.txt`)
3. Creates `~/YouTubeDownloads/` and `~/YouTubeDownloads/zips/`
4. Prompts for proxy credentials and writes `data/config.json`
5. Installs bash aliases (`~/.nxytdl_aliases`, sourced from `~/.bashrc`)
6. Starts the server

Re-run `setup.sh` at any time to update proxy credentials or regenerate aliases.

### Manual install

```bash
pip install -r requirements.txt

# Create data/config.json
cat > data/config.json <<'EOF'
{
  "proxy_url": "socks5://user:pass@host:port",
  "firefox_profile": ""
}
EOF

./start.sh
```

Open **http://localhost:8888** in your browser.

---

## Running the server

```bash
./start.sh   # start in background, PID → .uvicorn.pid, logs → uvicorn.log
./stop.sh    # graceful SIGTERM → SIGKILL, auto-escalates to sudo if needed
```

View logs live:

```bash
tail -f uvicorn.log
```

Or open the **Log** link in the page footer for a plain-text view in a new tab.

> **After any change to `main.py`**, run `./stop.sh && ./start.sh`. The server does not hot-reload — new routes won't exist until restart.

---

## Configuration

All runtime config lives in `data/config.json` (excluded from git — see `.gitignore`):

```json
{
  "proxy_url": "socks5://user:pass@host:port",
  "firefox_profile": "firefox:/path/to/Firefox/Profiles/xxxx.default-release"
}
```

| Key | Purpose |
|---|---|
| `proxy_url` | SOCKS5 proxy passed to every yt-dlp invocation. Leave empty to download directly. |
| `firefox_profile` | Firefox profile path for cookie-authenticated downloads (passed to yt-dlp `--cookies-from-browser`). Leave empty to skip. |

Config is read once at server startup. Restart after any change.

---

## Quality presets

Aliases are defined in `~/.nxytdl_aliases` and invoked via `bash -i -c`:

| Alias | Format | Notes |
|---|---|---|
| `ytdl1080` | MKV 1080p | Best video up to 1080p + best audio, merged with ffmpeg |
| `ytdl720` | MKV 720p | Best video up to 720p + best audio |
| `ytdlmp3` | MP3 320kbps | Audio-only |

To add a new quality preset:

1. Add the alias to `~/.nxytdl_aliases` (or re-run `setup.sh`)
2. Add the mapping in `_alias()` in `main.py`
3. Add the `<option>` in `templates/partials/selection_table.html`
4. Restart the server

---

## API reference

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | Full page |
| `GET` | `/log` | Serve `uvicorn.log` as plain text |
| `POST` | `/search` | yt-dlp search → `search_results.html` partial |
| `GET` | `/selection` | Selection partial |
| `POST` | `/selection/add` | Add items from search results |
| `POST` | `/selection/add-url` | Add single URL (title resolved via yt-dlp) |
| `POST` | `/selection/add-playlist` | Enumerate full playlist, add all videos |
| `DELETE` | `/selection/{item_id}` | Remove one item |
| `POST` | `/download/start` | Start background download, returns `{job_id}` |
| `GET` | `/download/progress/{job_id}` | Poll job status (includes stall detection) |
| `POST` | `/download/zip-existing` | Zip files already on disk without re-downloading |
| `GET` | `/downloads` | Previous downloads partial |
| `GET` | `/downloads/{zip}/file` | Serve zip file |
| `DELETE` | `/downloads/{zip}` | Delete zip + extracted folder |
| `GET` | `/files` | Recursive file browser partial |
| `GET` | `/files/download?p=` | Serve file as attachment |
| `GET` | `/files/play?p=` | Serve file inline (browser plays it) |
| `DELETE` | `/files/single?p=` | Delete one file |
| `DELETE` | `/files/folder?p=` | Delete entire folder |
| `DELETE` | `/files/all` | Wipe all of `~/YouTubeDownloads/`, clear `downloads.json` |

---

## Project layout

```
nxytdl/
├── main.py                         # FastAPI application (all routes + helpers)
├── setup.sh                        # One-command installer
├── start.sh                        # Background server start (PID tracking)
├── stop.sh                         # Graceful stop with sudo escalation
├── requirements.txt                # Python dependencies
├── data/
│   ├── config.json                 # !! NOT committed — contains credentials
│   ├── current_selection.json      # Active download queue (runtime state)
│   └── downloads.json              # Completed zip history (runtime state)
└── templates/
    ├── index.html                  # Full-page shell
    └── partials/
        ├── search_results.html     # Search result rows
        ├── selection_table.html    # Download queue table
        ├── progress.html           # Download progress / stall indicator
        ├── downloads_table.html    # Completed downloads list
        └── files_table.html        # Recursive file browser
```

---

## Download flow

```
POST /download/start
  └─▶ _run_download() in ThreadPoolExecutor
        ├── For each item in selection:
        │     ├── _has_existing_download() — skip if [VIDEO_ID] already on disk
        │     └── bash -i -c "cd <dir> && ytdl1080 <url>"
        │           └── Popen line-by-line → job["current_lines"] (last 5)
        ├── Strip emojis from all filenames
        └── zipfile.ZipFile (append mode — skip files already in zip by name)

GET /download/progress/{job_id}   (polled every 2s by HTMX)
  └─▶ returns progress partial
        ├── running: last 5 output lines (older lines dim, newest bright, errors red)
        ├── stalled: if running && no output for >20s
        └── done: emits <script> calling refreshDownloads() + refreshSelection()
```

Selection is only cleared on full success (zero errors). If any item fails, selection is preserved for retry.

---

## Troubleshooting

**405 on what should be a new route** — the server still has the old binary loaded. Run `./stop.sh && ./start.sh`.

**yt-dlp not found in subprocess** — aliases are defined in `~/.nxytdl_aliases`. The server uses `bash -i -c` to source them; if your `.bashrc` doesn't source `~/.nxytdl_aliases`, re-run `setup.sh`.

**Download stalls immediately** — check `uvicorn.log` for proxy connection errors. Verify `proxy_url` in `data/config.json`.

**"UndefinedError" in a Jinja2 template** — a partial is trying to use a variable the parent route didn't pass. All selection-related partials use `_selection_ctx(sel)`; spread it with `**_selection_ctx(sel)` in the `index` route.

---

## License

MIT

---

## Screenshots

![NXYTDL Screenshot](https://drive.google.com/uc?export=view&id=1CgB0cHnmADpx_0UH9f8_K8GUiQmjC8aw)
