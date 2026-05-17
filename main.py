import asyncio
import json
import re
import shlex
import shutil
import subprocess
import time
import uuid
import zipfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import quote

from fastapi import FastAPI, Form, HTTPException, Query, Request
from fastapi.responses import FileResponse, HTMLResponse, PlainTextResponse
from fastapi.templating import Jinja2Templates

app = FastAPI(title="NXYTDL")
templates = Jinja2Templates(directory="templates")
templates.env.filters["urlencode"] = lambda s: quote(str(s), safe="")

BASE_DIR = Path(__file__).parent
DATA_DIR = BASE_DIR / "data"
DOWNLOADS_DIR = Path.home() / "YouTubeDownloads"
ZIPS_DIR = DOWNLOADS_DIR / "zips"
SELECTION_FILE = DATA_DIR / "current_selection.json"
DOWNLOADS_FILE = DATA_DIR / "downloads.json"
LOG_FILE = BASE_DIR / "uvicorn.log"

PROXY = (
    json.loads((DATA_DIR / "config.json").read_text()).get("proxy_url", "")
    if (DATA_DIR / "config.json").exists()
    else ""
)

executor = ThreadPoolExecutor(max_workers=2)
jobs: dict[str, dict[str, Any]] = {}


# ── helpers ──────────────────────────────────────────────────────────────────

_EMOJI_RE = re.compile(
    "["
    "\U0001F600-\U0001F64F"
    "\U0001F300-\U0001F5FF"
    "\U0001F680-\U0001F6FF"
    "\U0001F1E0-\U0001F1FF"
    "\U00002600-\U000027BF"
    "\U0000FE00-\U0000FE0F"
    "\U0001F900-\U0001F9FF"
    "\U0001FA00-\U0001FAFF"
    "\U00002300-\U000023FF"
    "\U000024C2-\U00002BFF"
    "]+",
    flags=re.UNICODE,
)


def _strip_emojis(text: str) -> str:
    cleaned = _EMOJI_RE.sub("", text)
    return re.sub(r"\s{2,}", " ", cleaned).strip()


def _sanitize(name: str) -> str:
    return re.sub(r'[^\w\-. ]', '', name).strip()[:64] or "download"


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text())


def _write_json(path: Path, data: Any) -> None:
    path.write_text(json.dumps(data, indent=2))


def _fmt_size(b: int) -> str:
    mb = b / 1_048_576
    return f"{mb / 1024:.2f} GB" if mb >= 1024 else f"{mb:.1f} MB"


def _alias(quality: str) -> str:
    return {"720": "ytdl720", "mp3": "ytdlmp3"}.get(quality, "ytdl1080")


def _youtube_video_id(url: str) -> str | None:
    m = re.search(r'(?:v=|youtu\.be/)([a-zA-Z0-9_-]{11})', url)
    return m.group(1) if m else None


def _has_existing_download(dl_dir: Path, url: str) -> bool:
    """Return True if a complete file with the YouTube video ID exists in dl_dir."""
    vid_id = _youtube_video_id(url)
    if not vid_id or not dl_dir.exists():
        return False
    return any(
        f.is_file() and not f.name.endswith('.part') and f'[{vid_id}]' in f.name
        for f in dl_dir.iterdir()
    )


def _existing_file_count(dl_dir: Path) -> int:
    if not dl_dir.exists():
        return 0
    return sum(1 for f in dl_dir.iterdir() if f.is_file() and not f.name.endswith('.part'))


def _selection_ctx(sel: dict) -> dict:
    """Build template context for selection partials, including existing file count."""
    name = _sanitize(sel.get("name", ""))
    dl_dir = DOWNLOADS_DIR / name if name else None
    return {
        "selection": sel,
        "existing_count": _existing_file_count(dl_dir) if dl_dir else 0,
    }


# ── startup ───────────────────────────────────────────────────────────────────

@app.on_event("startup")
async def startup() -> None:
    DATA_DIR.mkdir(exist_ok=True)
    DOWNLOADS_DIR.mkdir(exist_ok=True)
    ZIPS_DIR.mkdir(exist_ok=True)
    if not SELECTION_FILE.exists():
        _write_json(SELECTION_FILE, {"name": "", "quality": "mp3", "items": []})
    if not DOWNLOADS_FILE.exists():
        _write_json(DOWNLOADS_FILE, [])


# ── pages ─────────────────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    sel = _read_json(SELECTION_FILE)
    return templates.TemplateResponse(request, "index.html", {
        **_selection_ctx(sel),
        "downloads": _read_json(DOWNLOADS_FILE),
    })



@app.get("/log", response_class=PlainTextResponse)
async def view_log() -> PlainTextResponse:
    if not LOG_FILE.exists():
        return PlainTextResponse("Log file not found.", status_code=404)
    return PlainTextResponse(LOG_FILE.read_text(errors="replace"))


# ── search ────────────────────────────────────────────────────────────────────

@app.post("/search", response_class=HTMLResponse)
async def search(
    request: Request,
    query: str = Form(...),
    duration: str = Form(""),
    upload_date: str = Form(""),
    views: str = Form(""),
    advanced_filter: str = Form(""),
) -> HTMLResponse:
    # Build match-filters argument
    filters = []

    if advanced_filter.strip():
        # Use advanced filter if provided
        filters.append(advanced_filter.strip())
    else:
        # Build from dropdown filters
        if duration:
            filters.append(duration)
        if upload_date:
            filters.append(upload_date)
        if views:
            filters.append(views)

    match_filter_arg = ""
    if filters:
        # Combine multiple filters with AND (&)
        match_filter_arg = f'--match-filters "{" & ".join(filters)}"'

    cmd = (
        f'yt-dlp --proxy "{PROXY}" '
        f'ytsearch30:{shlex.quote(query)} '
        f'{match_filter_arg} '
        '--dump-json --flat-playlist --no-download 2>/dev/null'
    )
    results: list[dict] = []
    try:
        proc = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=45
        )
        for line in proc.stdout.strip().splitlines():
            try:
                d = json.loads(line)
                vid_id = d.get("id", "")
                if not vid_id:
                    continue
                results.append({
                    "id": vid_id,
                    "title": d.get("title", "Unknown"),
                    "url": f"https://www.youtube.com/watch?v={vid_id}",
                    "duration": d.get("duration_string", ""),
                    "channel": d.get("channel") or d.get("uploader", ""),
                })
            except json.JSONDecodeError:
                continue
    except subprocess.TimeoutExpired:
        pass

    return templates.TemplateResponse(request, "partials/search_results.html", {
        "results": results,
        "query": query,
    })


# ── selection ─────────────────────────────────────────────────────────────────

@app.get("/selection", response_class=HTMLResponse)
async def get_selection(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "partials/selection_table.html",
                                      _selection_ctx(_read_json(SELECTION_FILE)))


@app.post("/selection/add", response_class=HTMLResponse)
async def add_to_selection(request: Request, items: str = Form(...)) -> HTMLResponse:
    new_items: list[dict] = json.loads(items)
    sel = _read_json(SELECTION_FILE)
    existing = {i["url"] for i in sel["items"]}
    for item in new_items:
        if item["url"] not in existing:
            sel["items"].append({
                "id": str(uuid.uuid4()),
                "title": _strip_emojis(item["title"]),
                "url": item["url"],
                "duration": item.get("duration", ""),
            })
            existing.add(item["url"])
    _write_json(SELECTION_FILE, sel)
    return templates.TemplateResponse(request, "partials/selection_table.html",
                                      _selection_ctx(sel))


@app.post("/selection/add-url", response_class=HTMLResponse)
async def add_url_to_selection(request: Request, url: str = Form(...)) -> HTMLResponse:
    clean_url = url.strip()

    def _fetch_title() -> str:
        try:
            result = subprocess.run(
                ["yt-dlp", "--proxy", PROXY, "--print", "title",
                 "--no-playlist", "--no-warnings", clean_url],
                capture_output=True, text=True, timeout=30,
            )
            t = _strip_emojis(result.stdout.strip())
            return t if t else clean_url
        except Exception:
            return clean_url

    title = await asyncio.to_thread(_fetch_title)

    sel = _read_json(SELECTION_FILE)
    existing = {i["url"] for i in sel["items"]}
    if clean_url not in existing:
        sel["items"].append({"id": str(uuid.uuid4()), "title": title, "url": clean_url})
        _write_json(SELECTION_FILE, sel)
    return templates.TemplateResponse(request, "partials/selection_table.html",
                                      _selection_ctx(sel))


@app.post("/selection/add-playlist", response_class=HTMLResponse)
async def add_playlist_to_selection(request: Request, url: str = Form(...)) -> HTMLResponse:
    def _fetch_playlist() -> list[dict]:
        result = subprocess.run(
            ["yt-dlp", "--proxy", PROXY, "--flat-playlist",
             "--print", "%(id)s\t%(title)s",
             "--no-warnings", url.strip()],
            capture_output=True, text=True, timeout=120,
        )
        items = []
        for line in result.stdout.strip().splitlines():
            if "\t" not in line:
                continue
            vid_id, title = line.split("\t", 1)
            vid_id = vid_id.strip()
            title = _strip_emojis(title.strip())
            if vid_id and title:
                items.append({
                    "title": title,
                    "url": f"https://www.youtube.com/watch?v={vid_id}",
                })
        return items

    try:
        new_items = await asyncio.to_thread(_fetch_playlist)
    except Exception as exc:
        raise HTTPException(500, f"Playlist fetch failed: {exc}")

    if not new_items:
        raise HTTPException(422, "No videos found — check the URL or try again")

    sel = _read_json(SELECTION_FILE)
    existing = {i["url"] for i in sel["items"]}
    for item in new_items:
        if item["url"] not in existing:
            sel["items"].append({"id": str(uuid.uuid4()), **item})
            existing.add(item["url"])
    _write_json(SELECTION_FILE, sel)
    return templates.TemplateResponse(request, "partials/selection_table.html",
                                      _selection_ctx(sel))


@app.delete("/selection/{item_id}", response_class=HTMLResponse)
async def delete_selection_item(request: Request, item_id: str) -> HTMLResponse:
    sel = _read_json(SELECTION_FILE)
    sel["items"] = [i for i in sel["items"] if i["id"] != item_id]
    _write_json(SELECTION_FILE, sel)
    return templates.TemplateResponse(request, "partials/selection_table.html",
                                      _selection_ctx(sel))


@app.delete("/selection", response_class=HTMLResponse)
async def clear_selection(request: Request) -> HTMLResponse:
    sel = _read_json(SELECTION_FILE)
    sel["items"] = []
    _write_json(SELECTION_FILE, sel)
    return templates.TemplateResponse(request, "partials/selection_table.html",
                                      _selection_ctx(sel))


# ── download ──────────────────────────────────────────────────────────────────

@app.post("/download/start")
async def start_download(
    list_name: str = Form(...),
    quality: str = Form(...),
) -> dict:
    sel = _read_json(SELECTION_FILE)
    if not sel["items"]:
        raise HTTPException(400, "No items in selection")

    clean_name = _sanitize(list_name)
    if not clean_name:
        raise HTTPException(400, "Invalid list name")

    job_id = str(uuid.uuid4())
    items_snapshot = list(sel["items"])

    jobs[job_id] = {
        "status": "running",
        "list_name": clean_name,
        "quality": quality,
        "total": len(items_snapshot),
        "done": 0,
        "current": "",
        "current_lines": [],
        "last_update": time.time(),
        "errors": [],
    }

    sel["name"] = clean_name
    sel["quality"] = quality
    _write_json(SELECTION_FILE, sel)

    loop = asyncio.get_event_loop()
    loop.run_in_executor(executor, _run_download, job_id, clean_name, quality, items_snapshot)

    return {"job_id": job_id}


def _run_download(job_id: str, list_name: str, quality: str, items: list) -> None:
    job = jobs[job_id]
    alias = _alias(quality)
    dl_dir = DOWNLOADS_DIR / list_name
    dl_dir.mkdir(parents=True, exist_ok=True)

    for i, item in enumerate(items):
        job["done"] = i
        job["current"] = item["title"]
        job["current_lines"] = []
        job["last_update"] = time.time()

        if _has_existing_download(dl_dir, item["url"]):
            job["current_lines"] = ["Already downloaded — skipping"]
            continue

        # bash -i sources ~/.bashrc so aliases are available
        inner = f"cd {shlex.quote(str(dl_dir))} && {alias} {shlex.quote(item['url'])}"
        last_output = ""
        try:
            proc = subprocess.Popen(
                ["bash", "-i", "-c", inner],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            for raw in proc.stdout:
                line = raw.rstrip()
                if line:
                    job["current_lines"] = (job["current_lines"] + [line])[-5:]
                    job["last_update"] = time.time()
                    last_output = line
            proc.wait()
            if proc.returncode != 0:
                snippet = (last_output or "unknown error")[-300:]
                job["errors"].append(f"{item['title']}: {snippet}")
        except Exception as exc:
            job["errors"].append(f"{item['title']}: {exc}")

    job["done"] = len(items)
    job["current"] = "Creating zip archive…"
    job["current_lines"] = []

    # Strip emojis from downloaded file names before zipping
    for f in list(dl_dir.iterdir()):
        if not f.is_file():
            continue
        # Split on first dot to preserve compound extensions (e.g. .info.json)
        head, _, tail = f.name.partition(".")
        clean_head = _strip_emojis(head) or "track"
        new_name = clean_head + ("." + tail if tail else "")
        if new_name != f.name:
            target = f.parent / new_name
            if not target.exists():
                f.rename(target)

    zip_path = ZIPS_DIR / f"{list_name}.zip"
    mode = "a" if zip_path.exists() else "w"
    try:
        with zipfile.ZipFile(zip_path, mode, zipfile.ZIP_STORED) as zf:
            existing_names = set(zf.namelist())
            for f in sorted(dl_dir.iterdir()):
                if f.is_file() and f.name not in existing_names:
                    zf.write(f, f.name)
            total_in_zip = len(zf.namelist())

        downloads = _read_json(DOWNLOADS_FILE)
        downloads = [d for d in downloads if d.get("zip_file") != f"{list_name}.zip"]
        downloads.insert(0, {
            "name": list_name,
            "zip_file": f"{list_name}.zip",
            "date": datetime.now().isoformat(),
            "size": zip_path.stat().st_size,
            "count": total_in_zip,
            "errors": len(job["errors"]),
        })
        _write_json(DOWNLOADS_FILE, downloads)
        if not job["errors"]:
            _write_json(SELECTION_FILE, {"name": "", "quality": "mp3", "items": []})
        job["status"] = "done"
    except Exception as exc:
        job["status"] = "error"
        job["errors"].append(f"Zip creation failed: {exc}")


@app.get("/download/progress/{job_id}", response_class=HTMLResponse)
async def get_progress(request: Request, job_id: str) -> HTMLResponse:
    job = jobs.get(job_id)
    if not job:
        return HTMLResponse('<p class="text-red-400 p-4">Job not found or server restarted.</p>')
    stall_seconds = int(time.time() - job.get("last_update", time.time()))
    stalled = job["status"] == "running" and stall_seconds > 20
    return templates.TemplateResponse(request, "partials/progress.html", {
        "job": job,
        "job_id": job_id,
        "stalled": stalled,
        "stall_seconds": stall_seconds,
    })


@app.post("/download/zip-existing", response_class=HTMLResponse)
async def zip_existing(request: Request, name: str = Form(...)) -> HTMLResponse:
    clean_name = _sanitize(name)
    if not clean_name:
        return HTMLResponse('<p class="text-red-400 p-4">Invalid name.</p>')
    dl_dir = DOWNLOADS_DIR / clean_name
    if not dl_dir.exists():
        return HTMLResponse(f'<p class="text-yellow-400 p-4">No download folder found for "{clean_name}".</p>')

    def _do_zip() -> int:
        for f in list(dl_dir.iterdir()):
            if not f.is_file() or f.name.endswith('.part'):
                continue
            head, _, tail = f.name.partition(".")
            clean_head = _strip_emojis(head) or "track"
            new_name = clean_head + ("." + tail if tail else "")
            if new_name != f.name:
                target = f.parent / new_name
                if not target.exists():
                    f.rename(target)

        files = sorted(f for f in dl_dir.iterdir() if f.is_file() and not f.name.endswith('.part'))
        if not files:
            return 0

        ZIPS_DIR.mkdir(parents=True, exist_ok=True)
        zip_path = ZIPS_DIR / f"{clean_name}.zip"
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_STORED) as zf:
            for f in files:
                zf.write(f, f.name)

        downloads = _read_json(DOWNLOADS_FILE)
        downloads = [d for d in downloads if d.get("zip_file") != f"{clean_name}.zip"]
        downloads.insert(0, {
            "name": clean_name,
            "zip_file": f"{clean_name}.zip",
            "date": datetime.now().isoformat(),
            "size": zip_path.stat().st_size,
            "count": len(files),
            "errors": 0,
        })
        _write_json(DOWNLOADS_FILE, downloads)
        return len(files)

    try:
        count = await asyncio.to_thread(_do_zip)
    except Exception as exc:
        return HTMLResponse(f'<p class="text-red-400 p-4">Zip failed: {exc}</p>')

    if count == 0:
        return HTMLResponse(f'<p class="text-yellow-400 p-4">No complete files found in "{clean_name}".</p>')

    zip_url = quote(f"{clean_name}.zip", safe="")
    return HTMLResponse(f'''
<div class="bg-green-950/50 border border-green-700 rounded-xl p-5 text-center space-y-3">
  <p class="text-green-400 font-semibold text-lg">Zipped {count} existing files!</p>
  <a href="/downloads/{zip_url}/file"
     class="inline-block bg-green-600 hover:bg-green-500 px-6 py-2.5 rounded-xl font-semibold transition shadow-lg">
    &#x2193; Download {clean_name}.zip
  </a>
</div>
<script>refreshDownloads(); refreshSelection();</script>
''')


# ── previous downloads ────────────────────────────────────────────────────────

@app.get("/downloads", response_class=HTMLResponse)
async def get_downloads_partial(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "partials/downloads_table.html", {
        "downloads": _read_json(DOWNLOADS_FILE),
    })


@app.get("/downloads/{zip_file}/file")
async def serve_zip(zip_file: str) -> FileResponse:
    path = ZIPS_DIR / zip_file
    if not path.exists() or path.suffix != ".zip":
        raise HTTPException(404, "File not found")
    return FileResponse(path, filename=zip_file, media_type="application/zip")


@app.delete("/downloads/{zip_file}", response_class=HTMLResponse)
async def delete_download(request: Request, zip_file: str) -> HTMLResponse:
    zip_path = ZIPS_DIR / zip_file
    if zip_path.exists():
        zip_path.unlink()
    folder = DOWNLOADS_DIR / zip_file.removesuffix(".zip")
    if folder.exists() and folder.is_dir():
        shutil.rmtree(folder)
    downloads = _read_json(DOWNLOADS_FILE)
    downloads = [d for d in downloads if d.get("zip_file") != zip_file]
    _write_json(DOWNLOADS_FILE, downloads)
    return templates.TemplateResponse(request, "partials/downloads_table.html", {
        "downloads": downloads,
    })


# ── file browser ──────────────────────────────────────────────────────────────

def _collect_files() -> list[dict]:
    """Recursively list all non-.part files under DOWNLOADS_DIR, grouped by folder."""
    from collections import defaultdict
    flat: list[dict] = []
    try:
        for f in sorted(DOWNLOADS_DIR.rglob("*")):
            if not f.is_file() or f.name.endswith(".part"):
                continue
            rel = f.relative_to(DOWNLOADS_DIR)
            folder = str(rel.parent) if len(rel.parts) > 1 else ""
            st = f.stat()
            flat.append({
                "name": f.name,
                "rel_path": "/".join(rel.parts),
                "folder": folder,
                "size": st.st_size,
                "size_fmt": _fmt_size(st.st_size),
            })
    except Exception:
        pass

    groups: dict[str, list] = defaultdict(list)
    for item in flat:
        groups[item["folder"]].append(item)

    total_files = len(flat)
    total_bytes = sum(f["size"] for f in flat)
    return {
        "groups": [
            {"folder": k or "(root)", "files": v}
            for k, v in sorted(groups.items())
        ],
        "total_files": total_files,
        "total_size": _fmt_size(total_bytes) if total_bytes else "0 MB",
    }


def _resolve_safe(rel_path: str) -> Path:
    target = (DOWNLOADS_DIR / rel_path).resolve()
    if not str(target).startswith(str(DOWNLOADS_DIR.resolve())):
        raise HTTPException(403, "Path not allowed")
    return target


@app.get("/files", response_class=HTMLResponse)
async def get_files(request: Request) -> HTMLResponse:
    data = await asyncio.to_thread(_collect_files)
    return templates.TemplateResponse(request, "partials/files_table.html", data)


@app.get("/files/download")
async def download_single_file(p: str = Query(...)) -> FileResponse:
    target = _resolve_safe(p)
    if not target.exists() or not target.is_file():
        raise HTTPException(404, "File not found")
    return FileResponse(target, filename=target.name)


@app.get("/files/play")
async def play_single_file(p: str = Query(...)) -> FileResponse:
    target = _resolve_safe(p)
    if not target.exists() or not target.is_file():
        raise HTTPException(404, "File not found")
    return FileResponse(target)  # no filename → inline, browser plays it


@app.delete("/files/folder", response_class=HTMLResponse)
async def delete_folder(request: Request, p: str = Query(...)) -> HTMLResponse:
    target = _resolve_safe(p)
    if target.resolve() == DOWNLOADS_DIR.resolve():
        raise HTTPException(403, "Cannot delete the root downloads directory")

    def _do() -> None:
        if target.exists():
            if target.is_dir():
                shutil.rmtree(target)
            else:
                target.unlink()

    await asyncio.to_thread(_do)
    data = await asyncio.to_thread(_collect_files)
    return templates.TemplateResponse(request, "partials/files_table.html", data)


@app.delete("/files/single", response_class=HTMLResponse)
async def delete_single_file(request: Request, p: str = Query(...)) -> HTMLResponse:
    target = _resolve_safe(p)
    if target.exists() and target.is_file():
        target.unlink()
    data = await asyncio.to_thread(_collect_files)
    return templates.TemplateResponse(request, "partials/files_table.html", data)


@app.delete("/files/all", response_class=HTMLResponse)
async def delete_all_files(request: Request) -> HTMLResponse:
    def _wipe() -> None:
        for item in list(DOWNLOADS_DIR.iterdir()):
            if item.is_dir():
                shutil.rmtree(item)
            else:
                item.unlink()
        ZIPS_DIR.mkdir(exist_ok=True)
        _write_json(DOWNLOADS_FILE, [])

    try:
        await asyncio.to_thread(_wipe)
    except Exception as exc:
        return HTMLResponse(f'<p class="text-red-400 p-4">Delete failed: {exc}</p>')

    data = await asyncio.to_thread(_collect_files)
    return templates.TemplateResponse(request, "partials/files_table.html", data)
