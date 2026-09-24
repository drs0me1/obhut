#!/usr/bin/env python3
"""Klasör sınırları tanıtıcılarla korunan, bağımsız hesaplı sınırlı WebDAV.

Root olarak çalışmaz. Sembolik/çoklu sabit bağlantılar, gizli dosyalar ve bağlanan
alt dosya sistemleri sunulmaz. PUT/COPY tamamlanmadan hedef değiştirilmez. LOCK
ve PROPPATCH desteklenmez; desteklenmeyen işlemler başarılı gibi gösterilmez.
"""
import argparse
import base64
import contextlib
import email.utils
import http.server
import mimetypes
import os
import re
import secrets
import stat
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET

from master_shares import DIR_FLAGS, FILE_FLAGS, ShareError, identity, load, open_dir, parts, password_ok

MAX_UPLOAD = 64 * 1024 ** 3
CHUNK = 1024 * 1024
DAV = "{DAV:}"
ET.register_namespace("d", "DAV:")
READ_METHODS = ("OPTIONS", "GET", "HEAD", "PROPFIND")
WRITE_METHODS = ("PUT", "MKCOL", "DELETE", "MOVE", "COPY")


class DavError(Exception):
    def __init__(self, code, message="İstek reddedildi."):
        super().__init__(message)
        self.code = code


def check_stat(st, device):
    if st.st_dev != device or not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode)):
        raise DavError(403, "Bağlantı veya alt dosya sistemi sunulmaz.")
    if stat.S_ISREG(st.st_mode) and st.st_nlink != 1:
        raise DavError(403, "Çoklu sabit bağlantı sunulmaz.")


def etag(st):
    return '"%x-%x-%x"' % (st.st_ino, st.st_size, st.st_mtime_ns)


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "Konsol-WebDAV"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(60)

    def end_headers(self):
        self.response_started = True
        super().end_headers()

    def log_message(self, *args):
        pass  # Never log Authorization, credentials or attacker-controlled request lines.

    def send(self, code, body=b"", headers=None):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def live(self):
        if self.item["expires"] and time.time() >= self.item["expires"]:
            raise DavError(403, "Paylaşımın süresi doldu.")

    def authenticate(self):
        match = re.match(r"^/s/([0-9a-f]{24})(?:/|$)", self.path)
        self.item = next((i for i in self.server.config["items"]
                          if match and i["id"] == match.group(1)), None)
        raw = self.headers.get("Authorization", "")
        if len(raw) > 2048:
            raise DavError(401)
        try:
            kind, value = raw.split(" ", 1)
            user, password = base64.b64decode(value, validate=True).decode("utf-8").split(":", 1)
        except (ValueError, UnicodeError):
            raise DavError(401)
        item = self.item
        if (kind.lower() != "basic" or not item or item["paused"] or user != item["username"]
                or len(password) > 256 or not password_ok(item, password)):
            raise DavError(401)
        self.live()
        if self.headers.get("Origin") or self.headers.get("Sec-Fetch-Site") == "cross-site":
            raise DavError(403)
        self.prefix = "/s/" + item["id"] + "/"
        if self.command not in READ_METHODS + WRITE_METHODS:
            raise DavError(405)
        if item["permission"] == "ro" and self.command not in READ_METHODS:
            raise DavError(403, "Bu hesap salt okunur.")
        # Chosen root is re-opened O_NOFOLLOW for every request, then identity checked.
        self.rootfd = open_dir(self.server.config["root"], parts(item["path"]))
        if identity(self.rootfd) != item["identity"]:
            raise DavError(410, "Klasör taşındı veya değiştirildi; yönetici paylaşımı güncellemeli.")
        self.device = os.fstat(self.rootfd).st_dev

    def path_parts(self, raw, destination=False):
        parsed = urllib.parse.urlsplit(raw)
        if destination:
            if parsed.netloc and (parsed.netloc.lower() != self.headers.get("Host", "").lower()
                                  or parsed.scheme not in ("http", "https")):
                raise DavError(403, "Başka bir adrese taşınamaz.")
        elif parsed.netloc or parsed.scheme:
            raise DavError(400)
        if parsed.query or parsed.fragment or re.search(r"%(?:2f|5c|00)", parsed.path, re.I):
            raise DavError(400)
        if parsed.path == self.prefix[:-1]:
            return []
        if not parsed.path.startswith(self.prefix):
            raise DavError(403, "Başka bir paylaşıma erişilemez.")
        try:
            pp = parts(urllib.parse.unquote(parsed.path[len(self.prefix):], errors="strict"), empty=True)
            if self.server.config.get("temp_name") in pp:
                raise DavError(403)
            return pp
        except (ShareError, UnicodeError):
            raise DavError(403)

    def folder(self, pp):
        fd = open_dir(self.rootfd, pp)
        try:
            check_stat(os.fstat(fd), self.device)
        except BaseException:
            os.close(fd)
            raise
        return fd

    def stat_path(self, pp):
        if not pp:
            return os.fstat(self.rootfd)
        with contextlib.ExitStack() as stack:
            fd = self.folder(pp[:-1])
            stack.callback(os.close, fd)
            st = os.stat(pp[-1], dir_fd=fd, follow_symlinks=False)
            check_stat(st, self.device)
            return st

    def body(self, limit):
        chunks, total = [], 0
        for chunk in self.body_chunks(limit):
            chunks.append(chunk)
            total += len(chunk)
        return b"".join(chunks)

    def body_chunks(self, limit):
        transfer = self.headers.get("Transfer-Encoding", "").lower()
        lengths = self.headers.get_all("Content-Length", [])
        if len(lengths) > 1 or (transfer and lengths) or transfer not in ("", "chunked"):
            raise DavError(400)
        if not transfer:
            try:
                left = int(lengths[0]) if lengths else 0
            except ValueError:
                raise DavError(400)
            if left < 0 or left > limit:
                raise DavError(413)
            while left:
                self.live()
                data = self.rfile.read(min(CHUNK, left))
                if not data:
                    raise DavError(400, "Yükleme yarıda kesildi.")
                left -= len(data)
                yield data
            return
        total = 0
        while True:
            line = self.rfile.readline(128)
            if not re.fullmatch(rb"[0-9a-fA-F]{1,16}\r\n", line):
                raise DavError(400)
            size = int(line.strip(), 16)
            if total + size > limit:
                raise DavError(413)
            if not size:
                if self.rfile.read(2) != b"\r\n":
                    raise DavError(400)
                return
            total += size
            left = size
            while left:
                self.live()
                data = self.rfile.read(min(CHUNK, left))
                if not data:
                    raise DavError(400)
                left -= len(data)
                yield data
            if self.rfile.read(2) != b"\r\n":
                raise DavError(400)

    def preconditions(self, st):
        tag = etag(st) if st else ""
        if self.headers.get("If-Match") and self.headers["If-Match"] not in (tag, "*" if st else ""):
            raise DavError(412)
        if self.headers.get("If-None-Match") in (tag, "*") and st:
            raise DavError(412)
        # No DAV locks: do not silently ignore a client's lock condition.
        if self.headers.get("If"):
            raise DavError(412)

    def target_stat(self, fd, name):
        try:
            st = os.stat(name, dir_fd=fd, follow_symlinks=False)
            check_stat(st, self.device)
            return st
        except FileNotFoundError:
            return None

    def get(self, pp):
        st = self.stat_path(pp)
        if stat.S_ISDIR(st.st_mode):
            self.send(200, "Klasör paylaşımı. WebDAV istemcisiyle bağlanın.\n".encode())
            return
        parent = self.folder(pp[:-1])
        try:
            fd = os.open(pp[-1], FILE_FLAGS, dir_fd=parent)
        finally:
            os.close(parent)
        with os.fdopen(fd, "rb") as stream:
            st = os.fstat(stream.fileno())
            check_stat(st, self.device)
            tag = etag(st)
            if self.headers.get("If-None-Match") == tag:
                self.send(304, headers={"ETag": tag})
                return
            self.preconditions(st)
            start, end, code = 0, st.st_size - 1, 200
            raw_range = self.headers.get("Range", "")
            if raw_range and self.headers.get("If-Range", tag) == tag:
                match = re.fullmatch(r"bytes=(\d*)-(\d*)", raw_range)
                if not match or not any(match.groups()) or not st.st_size:
                    raise DavError(416)
                a, b = match.groups()
                start = int(a) if a else max(0, st.st_size - int(b))
                end = min(st.st_size - 1, int(b)) if a and b else st.st_size - 1
                if start > end:
                    raise DavError(416)
                code = 206
            length = max(0, end - start + 1)
            self.send_response(code)
            self.send_header("Content-Length", str(length))
            self.send_header("Content-Type", mimetypes.guess_type(pp[-1])[0] or "application/octet-stream")
            self.send_header("ETag", tag)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Last-Modified", email.utils.formatdate(st.st_mtime, usegmt=True))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "sandbox; default-src 'none'")
            if code == 206:
                self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, st.st_size))
            self.end_headers()
            if self.command == "HEAD":
                return
            stream.seek(start)
            while length:
                self.live()
                data = stream.read(min(CHUNK, length))
                if not data:
                    self.close_connection = True
                    break
                self.wfile.write(data)
                length -= len(data)

    def propfind(self, pp):
        depth = self.headers.get("Depth", "infinity")
        if depth not in ("0", "1"):
            raise DavError(403, "Depth 0 veya 1 kullanın.")
        raw = self.body(65536)
        requested = None
        if raw:
            if b"<!" in raw:
                raise DavError(400)
            try:
                doc = ET.fromstring(raw)
            except ET.ParseError:
                raise DavError(400)
            prop = doc.find(DAV + "prop")
            if prop is not None:
                requested = [p.tag for p in prop]
        st = self.stat_path(pp)
        entries = [(pp, st)]
        if depth == "1" and stat.S_ISDIR(st.st_mode):
            fd = self.folder(pp)
            try:
                names = os.listdir(fd)
                if len(names) > 10000:
                    raise DavError(507, "Bu klasörde çok fazla öge var.")
                for name in sorted(names):
                    try:
                        if name == self.server.config.get("temp_name"):
                            continue
                        parts(name)
                        child = self.target_stat(fd, name)
                        if child:
                            entries.append((pp + [name], child))
                    except (OSError, ShareError, DavError):
                        continue
            finally:
                os.close(fd)
        root = ET.Element(DAV + "multistatus")
        for path, info in entries:
            response = ET.SubElement(root, DAV + "response")
            href = self.prefix + "/".join(urllib.parse.quote(p, safe="") for p in path)
            directory = stat.S_ISDIR(info.st_mode)
            if directory and not href.endswith("/"):
                href += "/"
            ET.SubElement(response, DAV + "href").text = href
            props = {DAV + "displayname": path[-1] if path else self.item["name"],
                     DAV + "resourcetype": None, DAV + "getcontentlength": str(info.st_size if not directory else 0),
                     DAV + "getlastmodified": email.utils.formatdate(info.st_mtime, usegmt=True),
                     DAV + "getetag": etag(info),
                     DAV + "getcontenttype": "httpd/unix-directory" if directory else (mimetypes.guess_type(path[-1])[0] or "application/octet-stream")}
            for status, keys in (("200 OK", [k for k in (requested or props) if k in props]),
                                 ("404 Not Found", [k for k in (requested or []) if k not in props])):
                if not keys:
                    continue
                pstat = ET.SubElement(response, DAV + "propstat")
                pnode = ET.SubElement(pstat, DAV + "prop")
                for key in keys:
                    elem = ET.SubElement(pnode, key)
                    if status.startswith("200"):
                        elem.text = props[key]
                        if key == DAV + "resourcetype" and directory:
                            ET.SubElement(elem, DAV + "collection")
                ET.SubElement(pstat, DAV + "status").text = "HTTP/1.1 " + status
        body = ET.tostring(root, encoding="utf-8", xml_declaration=True)
        self.send_response(207)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def remove_tree(self, fd, name, budget):
        budget[0] -= 1
        self.live()
        if budget[0] < 0:
            raise DavError(507)
        st = self.target_stat(fd, name)
        if st is None:
            raise DavError(404)
        if stat.S_ISDIR(st.st_mode):
            child = os.open(name, DIR_FLAGS, dir_fd=fd)
            try:
                for leaf in os.listdir(child):
                    # Hidden files may be removed along with their parent, never followed.
                    self.remove_tree(child, leaf, budget)
            finally:
                os.close(child)
            os.rmdir(name, dir_fd=fd)
        else:
            os.unlink(name, dir_fd=fd)

    def write(self, pp):
        if not pp:
            raise DavError(403, "Paylaşım kökü değiştirilemez.")
        with self.server.mutation_lock, contextlib.ExitStack() as stack:
            parent = self.folder(pp[:-1])
            stack.callback(os.close, parent)
            st = self.target_stat(parent, pp[-1])
            self.preconditions(st)
            if self.command == "MKCOL":
                if self.body(65536):
                    raise DavError(415)
                os.mkdir(pp[-1], 0o775, dir_fd=parent)
                self.send(201)
            elif self.command == "DELETE":
                self.remove_tree(parent, pp[-1], [100000])
                self.send(204)
            elif self.command in ("MOVE", "COPY"):
                if st is None:
                    raise DavError(404)
                dest = self.path_parts(self.headers.get("Destination", ""), destination=True)
                if not dest or dest == pp or dest[:len(pp)] == pp:
                    raise DavError(403)
                dfd = self.folder(dest[:-1])
                stack.callback(os.close, dfd)
                existing = self.target_stat(dfd, dest[-1])
                if self.headers.get("Overwrite", "T") not in ("T", "F"):
                    raise DavError(400)
                if existing and self.headers.get("Overwrite") == "F":
                    raise DavError(412)
                self.live()
                if self.command == "MOVE":
                    os.rename(pp[-1], dest[-1], src_dir_fd=parent, dst_dir_fd=dfd)
                else:
                    # Deliberately refuse directory COPY instead of partial recursive success.
                    if stat.S_ISDIR(st.st_mode):
                        raise DavError(501, "Klasör COPY desteklenmiyor; dosya kopyalanabilir.")
                    src = os.open(pp[-1], FILE_FLAGS, dir_fd=parent)
                    with os.fdopen(src, "rb") as stream:
                        check_stat(os.fstat(stream.fileno()), self.device)
                        self.atomic_put(dfd, dest[-1], iter(lambda: stream.read(CHUNK), b""))
                self.send(204 if existing else 201)
            elif self.command == "PUT":
                if st and stat.S_ISDIR(st.st_mode):
                    raise DavError(405)
                if not self.headers.get("Content-Length") and not self.headers.get("Transfer-Encoding"):
                    raise DavError(411)
                self.atomic_put(parent, pp[-1], self.body_chunks(MAX_UPLOAD))
                self.send(204 if st else 201)

    def atomic_put(self, parent, name, chunks):
        temp = ".webdav-" + secrets.token_hex(12)
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o664, dir_fd=parent)
        try:
            with os.fdopen(fd, "wb") as stream:
                for chunk in chunks:
                    self.live()
                    stream.write(chunk)
                stream.flush()
                os.fsync(stream.fileno())
            self.live()
            os.rename(temp, name, src_dir_fd=parent, dst_dir_fd=parent)
            os.fsync(parent)
        finally:
            try:
                os.unlink(temp, dir_fd=parent)
            except FileNotFoundError:
                pass

    def dispatch(self):
        self.rootfd = None
        self.response_started = False
        try:
            self.authenticate()
            pp = self.path_parts(self.path)
            if self.command == "OPTIONS":
                self.send(200, headers={"DAV": "1", "Allow": ", ".join(READ_METHODS + (WRITE_METHODS if self.item["permission"] == "rw" else ()))})
            elif self.command in ("GET", "HEAD"):
                self.get(pp)
            elif self.command == "PROPFIND":
                self.propfind(pp)
            else:
                self.write(pp)
        except (OSError, ShareError, DavError, ValueError) as err:
            self.close_connection = True
            code = err.code if isinstance(err, DavError) else 404 if isinstance(err, FileNotFoundError) else 403
            extra = {"WWW-Authenticate": 'Basic realm="Klasor-%s", charset="UTF-8"' % (self.item["id"] if getattr(self, "item", None) else "WebDAV")} if code == 401 else {}
            if not self.response_started:
                try:
                    self.send(code, (str(err) if isinstance(err, DavError) else "İstek gerçekleştirilemedi.").encode(), extra)
                except OSError:
                    pass
        finally:
            if self.rootfd is not None:
                os.close(self.rootfd)

    do_GET = do_HEAD = do_OPTIONS = do_PROPFIND = dispatch
    do_PUT = do_MKCOL = do_DELETE = do_MOVE = do_COPY = dispatch
    do_LOCK = do_UNLOCK = do_PROPPATCH = do_POST = dispatch


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    # Bound concurrent connections and expensive password verification.
    def __init__(self, address, config):
        self.config = config
        self.mutation_lock = threading.Lock()
        self.slots = threading.BoundedSemaphore(16)
        super().__init__(address, Handler)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry", required=True)
    parser.add_argument("--port", required=True, type=int)
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("WebDAV root olarak çalıştırılamaz.")
    Server(("127.0.0.1", args.port), load(args.registry)).serve_forever()


if __name__ == "__main__":
    main()
