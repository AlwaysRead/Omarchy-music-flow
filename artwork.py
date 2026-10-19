"""Bounded raster-artwork fetcher used by Artwork.qml. No shell execution."""
import base64
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import stat
import struct
import subprocess
import sys
from urllib.parse import unquote, urlsplit, urlunsplit

MAX_BYTES = 2 * 1024 * 1024
MAX_PIXELS = 4 * 1024 * 1024
MAX_DIMENSION = 4096
HOSTS = frozenset((
    "i.ytimg.com", "img.youtube.com", "static-cdn.jtvnw.net", "i.scdn.co",
    "image-cdn-ak.spotifycdn.com", "image-cdn-fa.spotifycdn.com", "mosaic.scdn.co",
    "lineup-images.scdn.co", "is1-ssl.mzstatic.com", "is2-ssl.mzstatic.com",
    "is3-ssl.mzstatic.com", "is4-ssl.mzstatic.com", "is5-ssl.mzstatic.com",
    "is-ssl.mzstatic.com", "i1.sndcdn.com", "a1.sndcdn.com", "f4.bcbits.com",
    "lastfm.freetls.fastly.net", "e-cdns-images.dzcdn.net", "cdns-images.dzcdn.net",
    "resources.tidal.com", "m.media-amazon.com", "images-na.ssl-images-amazon.com",
    "images.genius.com", "images.rapgenius.com",
))
RASTER_NAME = re.compile(r"^[a-f0-9]{64}\.(png|jpg|gif|webp|bmp)$")


def cache_root():
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    if not os.path.isabs(base):
        base = str(Path.home() / ".cache")
    return Path(base) / "omarchy" / "music-flow" / "artwork"


def open_directory(path, create=False):
    """Walk by directory descriptors; intermediate symlinks are not followed."""
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        parts = Path(path).parts[1:]
        for index, part in enumerate(parts):
            if part in ("", ".", ".."):
                raise ValueError("invalid directory")
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = child
            if create and index >= len(parts) - 3:
                if os.fstat(fd).st_uid != os.getuid():
                    raise ValueError("cache directory has another owner")
                os.fchmod(fd, 0o700)
        return fd
    except BaseException:
        os.close(fd)
        raise


def local_path(raw):
    parsed = urlsplit(raw)
    if parsed.scheme != "file" or parsed.netloc or parsed.query or parsed.fragment:
        raise ValueError("invalid local URI")
    path = unquote(parsed.path, errors="strict")
    if not path.startswith("/") or any(ord(c) < 32 or ord(c) == 127 or c == "\\" for c in path) or ".." in Path(path).parts:
        raise ValueError("invalid local path")
    home = Path.home()
    roots = [home / ".cache", cache_root().parents[2], Path("/tmp"), Path("/var/tmp"),
             Path("/usr/share/icons"), Path("/usr/share/pixmaps")]
    firefox = [home / ".config/mozilla/firefox/firefox-mpris", home / ".mozilla/firefox/firefox-mpris"]
    candidate = Path(path)
    allowed = any(candidate.is_relative_to(root) and candidate != root for root in roots)
    allowed = allowed or (candidate.parent in firefox and re.fullmatch(r"[A-Za-z0-9_-]+\.png", candidate.name))
    if not allowed:
        raise ValueError("local path outside artwork locations")
    return candidate


def read_local(raw):
    path = local_path(raw)
    directory = open_directory(path.parent)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid not in (0, os.getuid()) or not 4 <= info.st_size <= MAX_BYTES:
                raise ValueError("invalid artwork file")
            with os.fdopen(fd, "rb", closefd=False) as stream:
                data = stream.read(MAX_BYTES + 1)
            if len(data) > MAX_BYTES:
                raise ValueError("artwork grew beyond limit")
            return data
        finally:
            os.close(fd)
    finally:
        os.close(directory)


def read_https(raw):
    url = urlsplit(raw)
    if url.scheme != "https" or url.username or url.password or url.port not in (None, 443) or url.hostname not in HOSTS:
        raise ValueError("untrusted artwork host")
    if any(ord(c) <= 32 or ord(c) == 127 or c == "\\" for c in raw):
        raise ValueError("invalid artwork URL")
    addresses = list(dict.fromkeys(entry[4][0] for entry in socket.getaddrinfo(url.hostname, 443, type=socket.SOCK_STREAM)))
    if not addresses or any(not ipaddress.ip_address(address).is_global for address in addresses):
        raise ValueError("non-public artwork address")
    address = sorted(addresses, key=lambda item: ":" in item)[0]
    if ":" in address:
        address = "[" + address + "]"
    # Pin the checked address, disable curlrc/proxies, and never follow redirects.
    command = ["curl", "-q", "--silent", "--show-error", "--fail", "--noproxy", "*",
               "--connect-timeout", "3", "--max-time", "10", "--max-filesize", str(MAX_BYTES),
               "--proto", "=https", "--resolve", f"{url.hostname}:443:{address}",
               urlunsplit((url.scheme, url.netloc, url.path, url.query, ""))]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        data = process.stdout.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise ValueError("artwork exceeds byte limit")
        if process.wait(timeout=12) != 0:
            raise ValueError("artwork download failed")
        return data
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdout.close()


def image_dimensions(data):
    """Read bounded raster headers before passing any bytes to Qt's decoder."""
    if not 4 <= len(data) <= MAX_BYTES:
        raise ValueError("invalid artwork size")
    if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 33 and data[12:16] == b"IHDR":
        return "png", *struct.unpack(">II", data[16:24])
    if data[:6] in (b"GIF87a", b"GIF89a") and len(data) >= 13:
        return "gif", *struct.unpack("<HH", data[6:10])
    if data.startswith(b"BM") and len(data) >= 54 and struct.unpack("<I", data[14:18])[0] >= 40:
        width, height = struct.unpack("<ii", data[18:26])
        return "bmp", width, abs(height)
    if data.startswith(b"\xff\xd8"):
        position = 2
        while position < len(data):
            if data[position] != 255:
                break
            while position < len(data) and data[position] == 255:
                position += 1
            if position >= len(data):
                break
            marker = data[position]
            position += 1
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                continue
            if marker in (0xD9, 0xDA) or position + 2 > len(data):
                break
            length = int.from_bytes(data[position:position + 2], "big")
            if length < 2 or position + length > len(data):
                break
            if marker in (0xC0, 0xC1, 0xC2) and length >= 8:
                height, width = struct.unpack(">HH", data[position + 3:position + 7])
                return "jpg", width, height
            position += length
    if data.startswith(b"RIFF") and len(data) >= 30 and data[8:12] == b"WEBP":
        kind, payload = data[12:16], data[20:]
        if kind == b"VP8X" and len(payload) >= 10:
            return "webp", 1 + int.from_bytes(payload[4:7], "little"), 1 + int.from_bytes(payload[7:10], "little")
        if kind == b"VP8L" and len(payload) >= 5 and payload[0] == 0x2F:
            bits = int.from_bytes(payload[1:5], "little")
            return "webp", 1 + (bits & 0x3FFF), 1 + ((bits >> 14) & 0x3FFF)
        if kind == b"VP8 " and len(payload) >= 10 and payload[3:6] == b"\x9d\x01\x2a":
            width, height = struct.unpack("<HH", payload[6:10])
            return "webp", width & 0x3FFF, height & 0x3FFF
    raise ValueError("unsupported or malformed raster header")


def store(data):
    extension, width, height = image_dimensions(data)
    if not (0 < width <= MAX_DIMENSION and 0 < height <= MAX_DIMENSION and width * height <= MAX_PIXELS):
        raise ValueError("artwork dimensions exceed limit")
    path = cache_root()
    directory = open_directory(path, create=True)
    name = hashlib.sha256(data).hexdigest() + "." + extension
    try:
        info = os.fstat(directory)
        if info.st_uid != os.getuid():
            raise ValueError("cache has another owner")
        os.fchmod(directory, 0o700)
        temporary = ".artwork-" + secrets.token_hex(16)
        try:
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=directory)
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
        finally:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass
        # Delete only old, recognized cache files; leave concurrent requests alone.
        cached = []
        for entry in os.listdir(directory):
            if RASTER_NAME.fullmatch(entry):
                try:
                    info = os.stat(entry, dir_fd=directory, follow_symlinks=False)
                except FileNotFoundError:
                    continue
                if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid():
                    cached.append((info.st_mtime, entry))
        for modified, entry in sorted((item for item in cached if item[1] != name), reverse=True)[31:]:
            if entry != name:
                try:
                    os.unlink(entry, dir_fd=directory)
                except FileNotFoundError:
                    pass
        return (path / name).as_uri()
    finally:
        os.close(directory)


def fetch(raw):
    if raw.startswith("data:"):
        if len(raw) > 256 * 1024:
            raise ValueError("inline artwork exceeds limit")
        match = re.fullmatch(r"data:image/(?:png|jpeg|jpg|gif|webp|bmp);base64,([A-Za-z0-9+/]*={0,2})", raw, re.I)
        if not match:
            raise ValueError("invalid inline artwork")
        data = base64.b64decode(match[1], validate=True)
    else:
        if len(raw) > 2048 or any(ord(c) < 32 or ord(c) == 127 for c in raw):
            raise ValueError("invalid artwork URI")
        data = read_local(raw) if raw.startswith("file:") else read_https(raw)
    return store(data)


def interrupted(signum, frame):
    raise SystemExit(1)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        if len(sys.argv) == 2:
            source = sys.argv[1]
        elif len(sys.argv) == 1:
            request = sys.stdin.buffer.readline(256 * 1024 + 4096)
            if not request.endswith(b"\n"):
                raise ValueError("invalid artwork request")
            source = json.loads(request)["source"]
        else:
            raise ValueError("one artwork request required")
        if not isinstance(source, str):
            raise ValueError("invalid artwork request")
        print(json.dumps({"url": fetch(source)}))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        # Avoid logging player URLs, user paths, or metadata to the shell journal.
        sys.exit(1)
