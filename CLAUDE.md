# CLAUDE.md

## Run command

Use the management scripts (preferred):
```bash
./start.sh   # starts uvicorn in background, saves PID to .uvicorn.pid, logs to uvicorn.log
./stop.sh    # graceful SIGTERM → SIGKILL, escalates to sudo automatically if permission denied
```

Direct invocation (dev/debug only):
```bash
uvicorn main:app --host 0.0.0.0 --port 8888 --reload
```

Install dependencies first: `pip install -r requirements.txt`

**IMPORTANT — no `--reload` in `start.sh`.** After any change to `main.py`, run `./stop.sh && ./start.sh`. Without a restart, new routes don't exist and the old parameterized `DELETE /selection/{item_id}` route will catch POST requests to new paths, returning 405.

## Service management

- Port conflict: `start.sh` prompts to stop the existing process — does not hard-fail
- `stop.sh` auto-escalates to `sudo kill` when permission is denied
- PID tracked in `.uvicorn.pid`; logs append to `uvicorn.log`
- No systemd / auto-start on boot

## Architecture

Single-file FastAPI backend (`main.py`) serving HTMX-driven Jinja2 templates. No JS framework — all interactivity is HTMX + vanilla JS in `templates/index.html`.

**State** lives in JSON files under `data/`:
- `data/config.json` — proxy URL + Firefox profile path; **read once at module import** — restart after changing
- `data/current_selection.json` — active download queue `{name, quality, items: [{id, title, url, duration}]}`; `duration` is populated from search results, empty string for manual URL / playlist adds
- `data/downloads.json` — history of completed zips

**Templates** follow a partial-swap pattern. Every mutating endpoint returns a rendered HTML partial, not JSON. JS functions do `fetch()` calls and inject returned HTML into named container divs.

**Download flow:**
1. `POST /download/start` → spawns `_run_download` in `ThreadPoolExecutor`, returns `{job_id}`
2. JS inserts HTMX-polling div → `GET /download/progress/{job_id}` every 2 s
3. `_run_download` iterates items, calls `bash -i -c` for each URL via `Popen` (line-by-line output), zips folder into `~/YouTubeDownloads/zips/{name}.zip`. If that zip already exists, it is opened in **append mode** (`"a"`) and only new files (not already in the zip by filename) are added — no overwrite.
4. Before zipping, all files are renamed to strip emojis from their names
5. On job `done`, progress partial emits a `<script>` calling `refreshDownloads()` + `refreshSelection()`
6. **Selection is only cleared on full success (zero errors).** If any item fails, selection is preserved for retry.
7. **Items already on disk are skipped** — `_has_existing_download()` checks for `[VIDEO_ID]` in filenames before invoking yt-dlp.

## Endpoints

| Method | Path | Notes |
|--------|------|-------|
| GET | `/` | Full page |
| GET | `/log` | Serve `uvicorn.log` as plain text (new tab link in page footer) |
| POST | `/search` | yt-dlp search → `search_results.html` partial |
| GET | `/selection` | Selection partial |
| POST | `/selection/add` | Add items from search results |
| POST | `/selection/add-url` | Add single URL; looks up title via `asyncio.to_thread` + yt-dlp |
| POST | `/selection/add-playlist` | Enumerate full playlist via `yt-dlp --flat-playlist`, add all videos |
| DELETE | `/selection/{item_id}` | Remove one item |
| POST | `/download/start` | Start background download, returns `{job_id}` |
| GET | `/download/progress/{job_id}` | Poll job status (includes stall detection) |
| POST | `/download/zip-existing` | Zip files already on disk without re-downloading |
| GET | `/downloads` | Previous downloads partial |
| GET | `/downloads/{zip}/file` | Serve zip file |
| DELETE | `/downloads/{zip}` | Delete zip + extracted folder |
| GET | `/files` | Recursive file browser partial (HTMX lazy-loaded) |
| GET | `/files/download?p=` | Serve file as attachment (path relative to DOWNLOADS_DIR) |
| GET | `/files/play?p=` | Serve file inline (no Content-Disposition — browser plays it) |
| DELETE | `/files/single?p=` | Delete one file |
| DELETE | `/files/folder?p=` | Delete entire folder (shutil.rmtree) |
| DELETE | `/files/all` | Wipe all of ~/YouTubeDownloads, clear downloads.json |

## Key helpers

- **`_selection_ctx(sel)`** — builds context dict `{selection, existing_count}` for ALL selection-returning endpoints AND the index route. If you add a context variable used in `selection_table.html`, add it here, and also spread it into the `index` route with `**_selection_ctx(sel)`.
- **`_has_existing_download(dl_dir, url)`** — checks for `[VIDEO_ID]` in filenames (yt-dlp always embeds this). Used to skip re-downloads on retry.
- **`_resolve_safe(p)`** — validates a relative path stays within DOWNLOADS_DIR before file ops.
- **`_collect_files()`** — recursive file list grouped by folder for the file browser.
- **`_alias(quality)`** — maps quality string to bash alias name.

## Real-time download progress

`_run_download` uses `subprocess.Popen` (not `subprocess.run`) with `stderr=subprocess.STDOUT` and `bufsize=1`. Lines are read one-by-one; each non-empty line is appended to `job["current_lines"]` and the list is trimmed to the last 5: `job["current_lines"] = (job["current_lines"] + [line])[-5:]`. `job["last_update"]` (timestamp) is updated on every line. The progress endpoint computes `stalled = running && no output for >20s`. The template renders all 5 lines — older lines dim (`text-slate-500`), newest bright (`text-slate-300`), error lines red.

## Alias invocation

Aliases `ytdl1080`, `ytdl720`, `ytdlmp3` are defined in `~/.nxytdl_aliases`, sourced into `~/.bashrc` by `setup.sh`. Use `bash -i` so they're loaded:

```python
inner = f"cd {shlex.quote(str(dl_dir))} && {alias} {shlex.quote(url)}"
proc = subprocess.Popen(["bash", "-i", "-c", inner], stdout=PIPE, stderr=STDOUT, text=True, bufsize=1)
```

## Emoji stripping

`_strip_emojis(text)` via `_EMOJI_RE`. Applied to: search result titles, yt-dlp title lookups, downloaded filenames before zipping, playlist titles. Do not apply to URLs.

## Key paths

| Constant | Value |
|---|---|
| `DOWNLOADS_DIR` | `~/YouTubeDownloads/` |
| `ZIPS_DIR` | `~/YouTubeDownloads/zips/` |
| `SELECTION_FILE` | `data/current_selection.json` |
| `DOWNLOADS_FILE` | `data/downloads.json` |
| `LOG_FILE` | `BASE_DIR / "uvicorn.log"` |
| config | `data/config.json` (`proxy_url`, `firefox_profile`) |

## UI theme

Dark navy/slate (`#070e1c` body, `bg-slate-900` sections, `border-slate-800`). Search/download → blue-800, Add buttons → indigo-600, Play → indigo-900/40, Download links → green, Destructive → red, Neutral → slate-700. Search results checkboxes load **unchecked** by default.

## Known gotchas

**`{% include %}` partials share the parent context** — if `index.html` includes `selection_table.html`, the `index` route must pass ALL variables that the partial uses (e.g. `existing_count`). Use `**_selection_ctx(sel)` in the index route context dict. Missing variables cause `UndefinedError` at render time, not import time.

**`Query` import** — endpoints using query params need `from fastapi import Query`. Easy to miss when only `Form` was imported before.

**Buttons inside `<summary>` toggle the `<details>`** — wrap clickable non-toggle content in a `div` with `onclick="event.stopPropagation()"`.

**Starlette 0.36+ TemplateResponse** — request is first positional arg:
```python
templates.TemplateResponse(request, "template.html", {"key": value})  # correct
```

**Jinja2 + dict key `"items"`** — use bracket notation:
```jinja2
{% for item in selection['items'] %}   {# correct #}
{% for item in selection.items %}      {# wrong — iterates dict method #}
```

**No `--reload`** — new routes are invisible until restart. 405 from an existing parameterized route is the symptom.

**yt-dlp playlist URLs** — `--no-playlist` restricts title lookup to the single video even when URL has `&list=RD...`.

**Playlist prompt** — `_pendingPlaylistUrl` JS module-level var holds the raw URL; avoids URL encoding issues in onclick attributes. Prompt is rendered inline below the URL input via `showPlaylistPrompt()`.

## Adding a new quality option

1. Add alias definition in `~/.nxytdl_aliases` (or re-run `setup.sh`)
2. Add alias mapping in `_alias()` in `main.py`
3. Add `<option>` in `templates/partials/selection_table.html`

## Project status (as of 2026-04-29)

All application features complete and running. Deployment package added this session.

**App features:** Search, manual URL + playlist add, quality selection (MP3/720p/1080p), background download with real-time output (last 5 lines) + stall detection, skip already-downloaded (video ID matching), zip append (dedup by filename), emoji stripping, previous downloads list, full file browser (play/download/delete), duration column, log viewer.

**Deployment package (added 2026-04-29):**
- `setup.sh` — one-command installer: prereqs, pip deps, proxy config, Firefox auto-detect, `~/.nxytdl_aliases`, start
- `data/config.json` — proxy URL + Firefox profile; read at import time; `.gitignore` this file
- `DOCUMENTATION.md` — Mermaid architecture diagram, full flow docs, alias breakdown, troubleshooting, future ideas
- `PROXY` in `main.py` now reads from `data/config.json` (was hardcoded)
- Aliases live in `~/.nxytdl_aliases`, sourced by `.bashrc` (one `source` line — keeps `.bashrc` clean)

**Next steps:** Test real end-to-end download + alias invocation from subprocess context; test playlist add with a real URL; consider `.gitignore` for `data/config.json` and `data/*.json` state files.
