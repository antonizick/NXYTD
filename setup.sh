#!/usr/bin/env bash
# ==============================================================================
#  NXYTDL — Setup & Configuration
#  Run once from the project directory:  bash setup.sh
#  Re-run at any time to update proxy credentials or aliases.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Terminal colours ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()     { printf "  ${GREEN}✓${NC}  %s\n" "$*"; }
warn()   { printf "  ${YELLOW}⚠${NC}   %s\n" "$*"; }
err()    { printf "  ${RED}✗${NC}  %s\n" "$*" >&2; }
info()   { printf "  ${DIM}·${NC}  %s\n" "$*"; }
die()    { err "$*"; exit 1; }
prompt() { printf "  ${CYAN}?${NC}  %s" "$*"; }

divider() {
    printf "\n${CYAN}${BOLD}%s${NC}\n" "────────────────────────────────────────────────────────────"
}

step() {
    local num="$1"; shift
    divider
    printf "${CYAN}${BOLD}  STEP %s  ·  %s${NC}\n" "$num" "$*"
    divider
    echo
}

banner() {
    clear
    echo
    printf "${CYAN}${BOLD}"
    cat << 'EOF'
  ███╗   ██╗██╗  ██╗██╗   ██╗████████╗██████╗ ██╗
  ████╗  ██║╚██╗██╔╝╚██╗ ██╔╝╚══██╔══╝██╔══██╗██║
  ██╔██╗ ██║ ╚███╔╝  ╚████╔╝    ██║   ██║  ██║██║
  ██║╚██╗██║ ██╔██╗   ╚██╔╝     ██║   ██║  ██║██║
  ██║ ╚████║██╔╝ ██╗   ██║      ██║   ██████╔╝███████╗
  ╚═╝  ╚═══╝╚═╝  ╚═╝   ╚═╝      ╚═╝   ╚═════╝ ╚══════╝
EOF
    printf "${NC}"
    printf "  ${DIM}YouTube Downloader — Setup & Configuration${NC}\n"
    echo
}

# ── Sanity: must run from project directory ────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/main.py" ]] || \
    die "main.py not found. Run setup.sh from the NXYTDL project directory."

banner

echo -e "  This script will configure NXYTDL on your machine:\n"
echo -e "    1. Verify prerequisites (Python, yt-dlp, deno, ffmpeg)"
echo -e "    2. Install Python dependencies"
echo -e "    3. Create ~/YouTubeDownloads/ folder structure"
echo -e "    4. Configure your IPRoyal residential proxy"
echo -e "    5. Detect your Firefox browser profile"
echo -e "    6. Install download aliases into ~/.bashrc"
echo -e "    7. Start the NXYTDL web server"
echo
prompt "Press ENTER to begin, or Ctrl+C to abort…"
read -r


# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — Prerequisites
# ══════════════════════════════════════════════════════════════════════════════
step "1/7" "Checking Prerequisites"

# ── Python 3.10+ ──────────────────────────────────────────────────────────────
PYTHON_BIN=""
for py in python3 python; do
    if command -v "$py" &>/dev/null; then
        ver=$("$py" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        major="${ver%%.*}"; minor="${ver#*.}"
        if [[ "$major" -ge 3 && "$minor" -ge 10 ]]; then
            PYTHON_BIN="$py"
            ok "Python $ver found  ($py)"
            break
        else
            warn "Python $ver is too old (need 3.10+) — skipping"
        fi
    fi
done
[[ -n "$PYTHON_BIN" ]] || die "Python 3.10+ is required. Install it from https://python.org and re-run."

# ── pip ───────────────────────────────────────────────────────────────────────
if "$PYTHON_BIN" -m pip --version &>/dev/null; then
    ok "pip found"
else
    warn "pip not found — attempting install via ensurepip…"
    "$PYTHON_BIN" -m ensurepip --upgrade || die "pip install failed. Install pip manually."
    ok "pip installed"
fi

# ── yt-dlp ────────────────────────────────────────────────────────────────────
if command -v yt-dlp &>/dev/null; then
    ok "yt-dlp $(yt-dlp --version) found"
else
    warn "yt-dlp not found — installing via pip…"
    "$PYTHON_BIN" -m pip install -q --user yt-dlp
    # Reload PATH so newly installed bin is visible
    export PATH="$HOME/.local/bin:$PATH"
    if command -v yt-dlp &>/dev/null; then
        ok "yt-dlp $(yt-dlp --version) installed"
    else
        die "yt-dlp install failed. Try: pip install yt-dlp"
    fi
fi

# ── deno ──────────────────────────────────────────────────────────────────────
if command -v deno &>/dev/null; then
    ok "deno $(deno --version | head -1) found"
else
    warn "deno not found — installing via official installer…"
    curl -fsSL https://deno.land/install.sh | sh -s -- --no-modify-path 2>/dev/null || true
    DENO_PATH="$HOME/.deno/bin"
    export PATH="$DENO_PATH:$PATH"
    if command -v deno &>/dev/null; then
        ok "deno installed"
        info "Add ~/.deno/bin to your PATH — setup will do this via .bashrc"
    else
        warn "deno install may have failed. yt-dlp aliases require deno for JS extraction."
        warn "Install manually: curl -fsSL https://deno.land/install.sh | sh"
    fi
fi

# ── ffmpeg ────────────────────────────────────────────────────────────────────
if command -v ffmpeg &>/dev/null; then
    ok "ffmpeg found"
else
    warn "ffmpeg not found — attempting apt install…"
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y -q ffmpeg 2>/dev/null && ok "ffmpeg installed" || \
            warn "ffmpeg install failed — MP3 extraction and format merging will not work."
    else
        warn "apt-get not available. Install ffmpeg manually for audio extraction to work."
    fi
fi


# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — Python dependencies
# ══════════════════════════════════════════════════════════════════════════════
step "2/7" "Installing Python Dependencies"

REQS_FILE="$SCRIPT_DIR/requirements.txt"
[[ -f "$REQS_FILE" ]] || die "requirements.txt not found in $SCRIPT_DIR"

info "Running: pip install -r requirements.txt"
"$PYTHON_BIN" -m pip install -q -r "$REQS_FILE" && ok "All Python packages installed" || \
    die "pip install failed. Check your internet connection and try again."


# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Directory structure
# ══════════════════════════════════════════════════════════════════════════════
step "3/7" "Creating Folder Structure"

mkdir -p ~/YouTubeDownloads/zips
ok "~/YouTubeDownloads/        (download root)"
ok "~/YouTubeDownloads/zips/   (zip archives)"

mkdir -p "$SCRIPT_DIR/data"
ok "$SCRIPT_DIR/data/           (app state)"


# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Proxy configuration
# ══════════════════════════════════════════════════════════════════════════════
step "4/7" "Proxy Configuration"

echo "  NXYTDL routes all YouTube traffic through an IPRoyal residential"
echo "  proxy, preventing IP blocks and rate limits on yt-dlp downloads."
echo

# Load existing values from config.json if present
CFG_FILE="$SCRIPT_DIR/data/config.json"
EXISTING_PROXY=""
if [[ -f "$CFG_FILE" ]]; then
    EXISTING_PROXY=$("$PYTHON_BIN" -c "
import json, sys
try:
    d = json.loads(open('$CFG_FILE').read())
    u = d.get('proxy_url','')
    print(u)
except:
    pass
" 2>/dev/null || true)
fi

# Parse existing proxy URL if present
PREV_HOST="geo.iproyal.com"
PREV_PORT="12321"
PREV_USER=""
PREV_PASS=""
if [[ -n "$EXISTING_PROXY" ]]; then
    # socks5://user:pass@host:port
    PREV_USER=$("$PYTHON_BIN" -c "
from urllib.parse import urlparse
u = urlparse('$EXISTING_PROXY')
print(u.username or '')
" 2>/dev/null || true)
    PREV_PASS=$("$PYTHON_BIN" -c "
from urllib.parse import urlparse
u = urlparse('$EXISTING_PROXY')
print(u.password or '')
" 2>/dev/null || true)
    PREV_HOST=$("$PYTHON_BIN" -c "
from urllib.parse import urlparse
u = urlparse('$EXISTING_PROXY')
print(u.hostname or 'geo.iproyal.com')
" 2>/dev/null || true)
    PREV_PORT=$("$PYTHON_BIN" -c "
from urllib.parse import urlparse
u = urlparse('$EXISTING_PROXY')
print(u.port or 12321)
" 2>/dev/null || true)
    info "Existing configuration detected — press ENTER to keep current values."
    echo
fi

prompt "Proxy hostname  [${PREV_HOST}]: "
read -r PROXY_HOST
PROXY_HOST="${PROXY_HOST:-$PREV_HOST}"

prompt "Proxy port      [${PREV_PORT}]: "
read -r PROXY_PORT
PROXY_PORT="${PROXY_PORT:-$PREV_PORT}"

prompt "Username        [${PREV_USER:-<required>}]: "
read -r PROXY_USER
PROXY_USER="${PROXY_USER:-$PREV_USER}"
[[ -n "$PROXY_USER" ]] || die "Proxy username is required."

prompt "Password        [${PREV_PASS:+<saved — press ENTER to keep>}${PREV_PASS:-<required>}]: "
read -rs PROXY_PASS_INPUT
echo
if [[ -n "$PROXY_PASS_INPUT" ]]; then
    PROXY_PASS="$PROXY_PASS_INPUT"
else
    PROXY_PASS="$PREV_PASS"
fi
[[ -n "$PROXY_PASS" ]] || die "Proxy password is required."

PROXY_URL="socks5://${PROXY_USER}:${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}"
echo
ok "Proxy URL: socks5://${PROXY_USER}:*****@${PROXY_HOST}:${PROXY_PORT}"


# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — Firefox profile detection
# ══════════════════════════════════════════════════════════════════════════════
step "5/7" "Firefox Browser Profile"

echo "  yt-dlp reads your Firefox cookies to bypass YouTube bot detection."
echo "  This enables age-restricted video access and reduces CAPTCHA blocks."
echo

# Load existing value
EXISTING_FF=""
if [[ -f "$CFG_FILE" ]]; then
    EXISTING_FF=$("$PYTHON_BIN" -c "
import json
try:
    d = json.loads(open('$CFG_FILE').read())
    print(d.get('firefox_profile',''))
except:
    pass
" 2>/dev/null || true)
fi

FF_COOKIES=""

# Auto-detect WSL Firefox UWP profile
detect_firefox_profile() {
    local win_users="/mnt/c/Users"
    [[ -d "$win_users" ]] || return 0

    # UWP store version (Microsoft Store install)
    for p in "$win_users"/*/AppData/Local/Packages/Mozilla.Firefox_*/LocalCache/Roaming/Mozilla/Firefox/Profiles/*.default-release; do
        [[ -d "$p" ]] && { echo "firefox:$p"; return; }
    done

    # Traditional install
    for p in "$win_users"/*/AppData/Roaming/Mozilla/Firefox/Profiles/*.default-release; do
        [[ -d "$p" ]] && { echo "firefox:$p"; return; }
    done

    # Linux native Firefox
    for p in ~/.mozilla/firefox/*.default-release; do
        [[ -d "$p" ]] && { echo "firefox:$p"; return; }
    done
}

AUTO_DETECTED="$(detect_firefox_profile || true)"

if [[ -n "$EXISTING_FF" ]]; then
    info "Existing profile: $EXISTING_FF"
    prompt "Keep this profile? [Y/n]: "
    read -r keep
    if [[ "${keep,,}" != "n" ]]; then
        FF_COOKIES="$EXISTING_FF"
        ok "Keeping existing Firefox profile."
    fi
fi

if [[ -z "$FF_COOKIES" && -n "$AUTO_DETECTED" ]]; then
    info "Auto-detected: $AUTO_DETECTED"
    prompt "Use this profile? [Y/n]: "
    read -r use_auto
    if [[ "${use_auto,,}" != "n" ]]; then
        FF_COOKIES="$AUTO_DETECTED"
        ok "Firefox profile set."
    fi
    # FIXME: legacy fallback using stale `keep` variable — only reachable if user typed "n" above
    # if [[ "${keep,,}" != "n" ]]; then
    #     FF_COOKIES="$AUTO_DETECTED"
    #     ok "Firefox profile set."
    # fi
fi

if [[ -z "$FF_COOKIES" ]]; then
    echo
    echo "  Could not auto-detect a Firefox profile."
    echo "  Enter the path to your Firefox profile directory."
    echo "  Example (WSL): /mnt/c/Users/YourName/AppData/Roaming/Mozilla/Firefox/Profiles/abc123.default-release"
    echo "  Leave blank to skip cookie auth (some videos may be unavailable)."
    echo
    prompt "Firefox profile path (or ENTER to skip): "
    read -r ff_path
    if [[ -n "$ff_path" ]]; then
        FF_COOKIES="firefox:${ff_path}"
        ok "Firefox profile set."
    else
        warn "No Firefox profile configured — downloads will proceed without cookies."
    fi
fi


# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — Write config.json & install .bashrc aliases
# ══════════════════════════════════════════════════════════════════════════════
step "6/7" "Writing Configuration & Installing Aliases"

# ── Write data/config.json ────────────────────────────────────────────────────
"$PYTHON_BIN" - << PYEOF
import json, pathlib
cfg = {
    "proxy_url": "$PROXY_URL",
    "firefox_profile": "$FF_COOKIES",
}
path = pathlib.Path("$CFG_FILE")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(cfg, indent=2) + "\n")
PYEOF
ok "data/config.json written"

# ── Remove previous NXYTDL managed block from .bashrc (if any) ───────────────
"$PYTHON_BIN" - << 'PYEOF'
import re, pathlib
rc = pathlib.Path.home() / '.bashrc'
if rc.exists():
    text = rc.read_text()
    cleaned = re.sub(
        r'\n# >>> NXYTDL managed block.*?# <<< NXYTDL managed block <<<',
        '',
        text,
        flags=re.DOTALL
    )
    if cleaned != text:
        rc.write_text(cleaned)
PYEOF

# ── Build alias definitions ───────────────────────────────────────────────────
COMMON_FLAGS="--extractor-args 'youtube:player_client=web,web_safari,web_embedded,android_vr'"
COMMON_FLAGS+=" --js-runtimes deno"
COMMON_FLAGS+=" --remote-components ejs:github"
COMMON_FLAGS+=" --sleep-interval 5 --max-sleep-interval 12"
COMMON_FLAGS+=" --concurrent-fragments 8"

if [[ -n "$FF_COOKIES" ]]; then
    COOKIE_FLAG="--cookies-from-browser \"${FF_COOKIES}\""
else
    COOKIE_FLAG=""
fi

PROXY_FLAG="--proxy \"${PROXY_URL}\""

# Write to a separate file so .bashrc stays clean
ALIASES_FILE="$HOME/.nxytdl_aliases"

cat > "$ALIASES_FILE" << ALIASES_EOF
# NXYTDL aliases — managed by setup.sh ($(date '+%Y-%m-%d'))
# Edit via: bash $SCRIPT_DIR/setup.sh

# Generic — best available quality, MKV container
alias ytdl='yt-dlp $PROXY_FLAG \\
             $COMMON_FLAGS \\
             ${COOKIE_FLAG:+$COOKIE_FLAG \\}
             --merge-output-format mkv'

# 1080p video (recommended default)
alias ytdl1080='yt-dlp $PROXY_FLAG \\
                 $COMMON_FLAGS \\
                 ${COOKIE_FLAG:+$COOKIE_FLAG \\}
                 --merge-output-format mkv \\
                 -f "bestvideo[height<=1080]+bestaudio/best"'

# 720p video (faster, smaller files)
alias ytdl720='yt-dlp $PROXY_FLAG \\
                $COMMON_FLAGS \\
                ${COOKIE_FLAG:+$COOKIE_FLAG \\}
                --merge-output-format mkv \\
                -f "bestvideo[height<=720]+bestaudio/best"'

# Audio only — MP3 at best quality
alias ytdlmp3='yt-dlp $PROXY_FLAG \\
                $COMMON_FLAGS \\
                ${COOKIE_FLAG:+$COOKIE_FLAG \\}
                -f "bestaudio/best" \\
                --extract-audio --audio-format mp3 --audio-quality 0'
ALIASES_EOF

ok "~/.nxytdl_aliases written"

# ── Source file from .bashrc (idempotent) ─────────────────────────────────────
BASHRC="$HOME/.bashrc"
SOURCE_LINE='[[ -f ~/.nxytdl_aliases ]] && source ~/.nxytdl_aliases'
NXYTDL_MARK="# NXYTDL"

if ! grep -qF "nxytdl_aliases" "$BASHRC" 2>/dev/null; then
    printf '\n%s\n%s\n' "$NXYTDL_MARK" "$SOURCE_LINE" >> "$BASHRC"
    ok "~/.bashrc updated to source aliases"
else
    ok "~/.bashrc already sources aliases (no change needed)"
fi

# Ensure deno is in PATH in .bashrc if it was just installed
DENO_ENV_LINE='. "$HOME/.deno/env"'
if [[ -f "$HOME/.deno/env" ]] && ! grep -qF '.deno/env' "$BASHRC" 2>/dev/null; then
    printf '\n# deno\n%s\n' "$DENO_ENV_LINE" >> "$BASHRC"
    ok "~/.bashrc updated to source deno env"
fi


# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — Start the server
# ══════════════════════════════════════════════════════════════════════════════
step "7/7" "Starting NXYTDL"

START_SH="$SCRIPT_DIR/start.sh"
if [[ ! -f "$START_SH" ]]; then
    warn "start.sh not found — skipping auto-start."
else
    chmod +x "$START_SH" "$SCRIPT_DIR/stop.sh" 2>/dev/null || true
    prompt "Start the NXYTDL server now? [Y/n]: "
    read -r do_start
    if [[ "${do_start,,}" != "n" ]]; then
        bash "$START_SH"
    else
        info "Skipped. Start manually with: ./start.sh"
    fi
fi


# ══════════════════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════════════════
divider
printf "\n  ${GREEN}${BOLD}Setup complete!${NC}\n\n"

echo "  Quick reference:"
echo
printf "  ${CYAN}Access the UI${NC}\n"
echo "    http://localhost:8888     (from this machine)"
echo "    http://$(hostname -I | awk '{print $1}'):8888  (from another device on your network)"
echo
printf "  ${CYAN}Server management${NC}\n"
echo "    ./start.sh    — start in background"
echo "    ./stop.sh     — graceful stop"
echo "    ./start.sh    — will prompt to restart if already running"
echo
printf "  ${CYAN}Reconfigure${NC}\n"
echo "    bash setup.sh — re-run at any time to update proxy/aliases"
echo
printf "  ${CYAN}Aliases (after: source ~/.bashrc)${NC}\n"
echo "    ytdl1080 <url>    — 1080p MKV"
echo "    ytdl720  <url>    — 720p MKV"
echo "    ytdlmp3  <url>    — MP3 audio"
echo
printf "  ${CYAN}Logs${NC}\n"
echo "    tail -f $SCRIPT_DIR/uvicorn.log"
echo "    Or open the log link in the UI footer."
echo
warn "Reload your shell to activate aliases: source ~/.bashrc"
divider
echo
