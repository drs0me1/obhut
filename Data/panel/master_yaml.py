#!/usr/bin/env python3
"""A YAML subset reader for Compose and Kubernetes files (rebuild, DD-271 K4); standard library only.

It reads what such files use: block mappings and sequences (a sequence may sit at its key's own
indentation), plain, single- and double-quoted scalars, the flow forms [...] and {...} (also across
lines), literal (|) and folded (>) block scalars with chomping and indentation indicators, comments, and
several documents separated by ---. Scalars follow the YAML 1.2 core schema: null and ~ are None,
true/false are booleans (yes/no/on/off stay text), decimal, 0o and 0x integers and floats are numbers,
anything else is text, so 8080:8080 is the string "8080:8080". Mapping keys stay the text they were
written as. Everything else stops with its line instead of being guessed: anchors, aliases, merge keys,
tags, complex keys, directives, duplicate keys, tabs used for indentation, plain or quoted scalars that
run over several lines, content after ---. Mappings and sequences carry the line of each key and item so
that a caller can point at the file.
"""
import re

LIMIT_BYTES = 262144
MAX_DEPTH = 64
MAX_NODES = 100000

_ESCAPES = {"0": "\0", "a": "\a", "b": "\b", "t": "\t", "\t": "\t", "n": "\n", "v": "\v", "f": "\f",
            "r": "\r", "e": "\x1b", " ": " ", '"': '"', "/": "/", "\\": "\\", "N": "\x85", "_": "\xa0",
            "L": " ", "P": " "}
_HEX = {"x": 2, "u": 4, "U": 8}
_INT = re.compile(r"[-+]?[0-9]+\Z")
_OCT = re.compile(r"0o[0-7]+\Z")
_HEXINT = re.compile(r"0x[0-9a-fA-F]+\Z")
_FLOAT = re.compile(r"[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?\Z")


class YamlError(ValueError):
    """A reading error; str() is a Turkish message without the place, which is in line and column."""

    def __init__(self, message, line, column=1):
        super().__init__(message)
        self.line = line
        self.column = column


class Map(dict):
    """A mapping with the line of its first key and of every key."""

    def __init__(self, line=0):
        super().__init__()
        self.line = line
        self.key_lines = {}


class Seq(list):
    """A sequence with the line where it starts and the line of every item."""

    def __init__(self, line=0):
        super().__init__()
        self.line = line
        self.item_lines = []


def resolve(text):
    """A plain scalar's value under the YAML 1.2 core schema."""
    if text in ("", "~", "null", "Null", "NULL"):
        return None
    if text in ("true", "True", "TRUE"):
        return True
    if text in ("false", "False", "FALSE"):
        return False
    if _INT.match(text):
        return int(text, 10)
    if _OCT.match(text):
        return int(text[2:], 8)
    if _HEXINT.match(text):
        return int(text[2:], 16)
    if _FLOAT.match(text):
        return float(text)
    if text in (".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF"):
        return float("inf")
    if text in ("-.inf", "-.Inf", "-.INF"):
        return float("-inf")
    if text in (".nan", ".NaN", ".NAN"):
        return float("nan")
    return text


class _Document:
    """Reads one document from lines[start:end]; positions are 0-based line indexes."""

    def __init__(self, lines, start, end):
        self.lines = lines
        self.start = start
        self.end = end
        self.depth = 0
        self.nodes = 0

    # ---- errors and lines
    def fail(self, message, i, column=0):
        raise YamlError(message, i + 1, column + 1)

    def blank(self, i):
        text = self.lines[i].lstrip(" \t")
        return text == "" or text.startswith("#")

    def next_content(self, i):
        while i < self.end and self.blank(i):
            i += 1
        return i

    def indent(self, i):
        line = self.lines[i]
        n = len(line) - len(line.lstrip(" "))
        if line[n:n + 1] == "\t":
            self.fail("Girintide sekme karakteri var; boşluk kullanın.", i, n)
        return n

    def enter(self, i):
        self.depth += 1
        if self.depth > MAX_DEPTH:
            self.fail("Dosya çok derin iç içe (en çok %d düzey)." % MAX_DEPTH, i)

    def count(self, i):
        self.nodes += 1
        if self.nodes > MAX_NODES:
            self.fail("Dosyada çok fazla öge var.", i)

    @staticmethod
    def is_item(text):
        return text == "-" or text.startswith("- ") or text.startswith("-\t")

    # ---- the document
    def read(self):
        i = self.next_content(self.start)
        if i >= self.end:
            return None
        value, i = self.block(i, 0)
        i = self.next_content(i)
        if i < self.end:
            self.fail("Beklenmeyen içerik.", i, self.indent(i))
        return value

    def block(self, i, min_indent):
        """The block node starting at the next content line, if it is indented at least min_indent."""
        i = self.next_content(i)
        if i >= self.end:
            return None, i
        ind = self.indent(i)
        if ind < min_indent:
            return None, i
        text = self.lines[i][ind:]
        if self.is_item(text):
            return self.sequence(i, ind)
        if self.split_key(i, ind) is not None:
            return self.mapping(i, ind)
        return self.inline(i, ind, min_indent - 1)

    def sequence(self, i, ind):
        self.enter(i)
        seq = Seq(i + 1)
        while True:
            i = self.next_content(i)
            if i >= self.end:
                break
            cur = self.indent(i)
            if cur < ind:
                break
            if cur > ind:
                self.fail("Beklenmeyen girinti.", i, cur)
            text = self.lines[i][ind:]
            if not self.is_item(text):
                break
            self.count(i)
            rest = text[1:]
            col = ind + 1 + (len(rest) - len(rest.lstrip(" ")))
            if rest.lstrip(" ").startswith("\t"):
                self.fail("Liste işaretinden sonra sekme var; boşluk kullanın.", i, col)
            seq.item_lines.append(i + 1)
            after = self.lines[i][col:]
            if after == "" or after.startswith("#"):
                value, i = self.block(i + 1, ind + 1)
            else:
                # The item's content stands at its own column, as if the "- " were indentation.
                self.lines[i] = " " * col + self.lines[i][col:]
                value, i = self.block(i, col)
            seq.append(value)
        self.depth -= 1
        return seq, i

    def mapping(self, i, ind):
        self.enter(i)
        result = Map(i + 1)
        while True:
            i = self.next_content(i)
            if i >= self.end:
                break
            cur = self.indent(i)
            if cur < ind:
                break
            if cur > ind:
                self.fail("Beklenmeyen girinti.", i, cur)
            text = self.lines[i][ind:]
            if self.is_item(text):
                self.fail("Liste öğesi burada beklenmiyordu.", i, ind)
            split = self.split_key(i, ind)
            if split is None:
                self.unsupported(i, ind)
                self.fail("Eşleme anahtarı bekleniyordu.", i, ind)
            key, col = split
            if key == "<<":
                self.fail("Birleştirme anahtarı (<<) desteklenmiyor.", i, ind)
            if key in result:
                self.fail("Aynı anahtar iki kez yazılmış: %s" % key, i, ind)
            self.count(i)
            result.key_lines[key] = i + 1
            rest = self.lines[i][col:]
            if rest == "" or rest.startswith("#"):
                j = self.next_content(i + 1)
                if j < self.end and self.indent(j) == ind and self.is_item(self.lines[j][ind:]):
                    value, i = self.sequence(j, ind)
                else:
                    value, i = self.block(i + 1, ind + 1)
            else:
                value, i = self.inline(i, col, ind)
            result[key] = value
        self.depth -= 1
        return result, i

    def split_key(self, i, ind):
        """(key, value column) when the line at indentation ind is a mapping entry, else None."""
        line = self.lines[i]
        text = line[ind:]
        if text.startswith("?") and (len(text) == 1 or text[1] in " \t"):
            self.fail("Karmaşık anahtar (?) desteklenmiyor.", i, ind)
        if text[:1] in ("'", '"'):
            key, k = self.quoted(i, ind)
            while k < len(line) and line[k] in " \t":
                k += 1
            if k < len(line) and line[k] == ":" and (k + 1 == len(line) or line[k + 1] in " \t"):
                return key, self.value_column(line, k + 1)
            return None
        if text[:1] in ("[", "{", "&", "*", "!", "|", ">", "%", "@", "`", "#"):
            return None
        k = ind
        while k < len(line):
            c = line[k]
            if c == "#" and k > ind and line[k - 1] in " \t":
                return None
            if c == ":" and (k + 1 == len(line) or line[k + 1] in " \t"):
                key = line[ind:k].rstrip(" \t")
                if not key:
                    return None
                return key, self.value_column(line, k + 1)
            k += 1
        return None

    @staticmethod
    def value_column(line, k):
        while k < len(line) and line[k] in " \t":
            k += 1
        return k

    def unsupported(self, i, col):
        """Stop on an indicator this reader refuses, naming it."""
        c = self.lines[i][col:col + 1]
        if c == "&":
            self.fail("Çapa (&) desteklenmiyor.", i, col)
        if c == "*":
            self.fail("Takma ad (*) desteklenmiyor.", i, col)
        if c == "!":
            self.fail("Etiket (!) desteklenmiyor.", i, col)
        if c in ("@", "`"):
            self.fail("Ayrılmış karakterle (%s) başlayan metin tırnak içine alınmalı." % c, i, col)
        if c == "%":
            self.fail("YAML yönergesi (%) desteklenmiyor.", i, col)

    # ---- a value written on its line
    def inline(self, i, col, parent):
        """The value starting at column col of line i; parent is the indentation it belongs under."""
        line = self.lines[i]
        c = line[col:col + 1]
        self.count(i)
        self.unsupported(i, col)
        if c in ("|", ">"):
            return self.block_scalar(i, col, parent)
        if c in ("[", "{"):
            value, li, ci = _Flow(self, i, col).read()
            rest = self.lines[li][ci:].lstrip(" \t")
            if rest and not rest.startswith("#"):
                self.fail("Beklenmeyen içerik.", li, ci)
            self.no_continuation(li + 1, parent)
            return value, li + 1
        if c in ("'", '"'):
            value, k = self.quoted(i, col)
            rest = line[k:].lstrip(" \t")
            if rest and not rest.startswith("#"):
                if rest.startswith(":"):
                    self.fail("Bir satırda iç içe eşleme desteklenmiyor.", i, k)
                self.fail("Beklenmeyen içerik.", i, k)
            self.no_continuation(i + 1, parent)
            return value, i + 1
        if self.is_item(line[col:]):
            self.fail("Liste öğesi burada beklenmiyordu.", i, col)
        if c in (",", "]", "}"):
            self.fail("Beklenmeyen karakter: %s" % c, i, col)
        text = self.plain_text(line, col)
        if re.search(r":(\s|$)", text):
            self.fail("Bir satırda iç içe eşleme desteklenmiyor.", i, col)
        self.no_continuation(i + 1, parent)
        return resolve(text), i + 1

    @staticmethod
    def plain_text(line, col):
        k = col
        while k < len(line):
            if line[k] == "#" and line[k - 1] in " \t":
                break
            k += 1
        return line[col:k].rstrip(" \t")

    def no_continuation(self, i, parent):
        j = self.next_content(i)
        if j < self.end and self.indent(j) > parent:
            self.fail("Çok satırlı düz ya da tırnaklı metin desteklenmiyor; tırnak içinde tek satır ya da | kullanın.", j, self.indent(j))

    def quoted(self, i, col):
        """A quoted scalar on one line: (value, column after the closing quote)."""
        line = self.lines[i]
        quote = line[col]
        out = []
        k = col + 1
        while k < len(line):
            c = line[k]
            if quote == "'":
                if c == "'":
                    if line[k + 1:k + 2] == "'":
                        out.append("'")
                        k += 2
                        continue
                    return "".join(out), k + 1
                out.append(c)
                k += 1
                continue
            if c == '"':
                return "".join(out), k + 1
            if c == "\\":
                e = line[k + 1:k + 2]
                if e in _ESCAPES:
                    out.append(_ESCAPES[e])
                    k += 2
                    continue
                if e in _HEX:
                    digits = line[k + 2:k + 2 + _HEX[e]]
                    if len(digits) != _HEX[e] or not re.fullmatch(r"[0-9a-fA-F]+", digits):
                        self.fail("Geçersiz kaçış dizisi: \\%s" % e, i, k)
                    out.append(chr(int(digits, 16)))
                    k += 2 + _HEX[e]
                    continue
                if e == "":
                    self.fail("Çok satırlı tırnaklı metin desteklenmiyor.", i, k)
                self.fail("Geçersiz kaçış dizisi: \\%s" % e, i, k)
            out.append(c)
            k += 1
        self.fail("Tırnak kapanmamış; çok satırlı tırnaklı metin desteklenmiyor.", i, col)

    def block_scalar(self, i, col, parent):
        head = self.lines[i][col:]
        style = head[0]
        chomp = "clip"
        explicit = None
        k = 1
        while k < len(head) and head[k] in "+-0123456789":
            c = head[k]
            if c in "+-":
                if chomp != "clip":
                    self.fail("Blok metin başlığı geçersiz.", i, col + k)
                chomp = "keep" if c == "+" else "strip"
            else:
                if c == "0" or explicit is not None:
                    self.fail("Blok metin başlığı geçersiz.", i, col + k)
                explicit = int(c)
            k += 1
        rest = head[k:]
        if rest and (rest[0] not in " \t" or not (rest.strip() == "" or rest.strip().startswith("#"))):
            self.fail("Blok metin başlığı geçersiz.", i, col + k)
        base = max(parent, 0)
        content_indent = base + explicit if explicit else None
        body = []
        j = i + 1
        while j < self.end:
            line = self.lines[j]
            if line.strip(" ") == "":
                body.append(None)
                j += 1
                continue
            ind = len(line) - len(line.lstrip(" "))
            if content_indent is None:
                if ind <= parent:
                    break
                content_indent = ind
            if ind < content_indent:
                break
            body.append(line[content_indent:])
            j += 1
        trailing = 0
        while body and body[-1] is None:
            body.pop()
            trailing += 1
        if style == "|":
            text = "\n".join("" if b is None else b for b in body)
        else:
            text = self.fold(body)
        if not body:
            text = ""
            value = "\n" * trailing if chomp == "keep" else ""
        elif chomp == "strip":
            value = text
        elif chomp == "keep":
            value = text + "\n" * (1 + trailing)
        else:
            value = text + "\n"
        return value, j

    @staticmethod
    def fold(body):
        out = ""
        kind = None
        empties = 0
        for b in body:
            if b is None:
                empties += 1
                continue
            more = b[:1] in (" ", "\t")
            if kind is None:
                out = "\n" * empties + b
            elif kind == "normal" and not more:
                out += ("\n" * empties) if empties else " "
                out += b
            else:
                out += "\n" * (empties + 1) + b
            empties = 0
            kind = "more" if more else "normal"
        return out


class _Flow:
    """Reads one flow collection ([...] or {...}), which may continue over the following lines."""

    def __init__(self, doc, i, col):
        self.doc = doc
        self.li = i
        self.ci = col

    def fail(self, message):
        self.doc.fail(message, self.li, self.ci)

    def char(self):
        line = self.doc.lines[self.li]
        return line[self.ci] if self.ci < len(line) else "\n"

    def skip(self):
        """Skip spaces, line ends and comments inside the collection."""
        while True:
            if self.li >= self.doc.end:
                self.doc.fail("Kapanmamış [ ya da {.", self.doc.end - 1)
            line = self.doc.lines[self.li]
            while self.ci < len(line) and line[self.ci] in " \t":
                self.ci += 1
            if self.ci >= len(line) or (line[self.ci] == "#" and (self.ci == 0 or line[self.ci - 1] in " \t")):
                self.li += 1
                self.ci = 0
                if self.li >= self.doc.end:
                    self.doc.fail("Kapanmamış [ ya da {.", self.doc.end - 1)
                continue
            return

    def read(self):
        value = self.node()
        return value, self.li, self.ci

    def node(self):
        self.skip()
        c = self.char()
        self.doc.count(self.li)
        if c == "[":
            return self.sequence()
        if c == "{":
            return self.mapping()
        if c in ("'", '"'):
            value, self.ci = self.doc.quoted(self.li, self.ci)
            return value
        self.doc.unsupported(self.li, self.ci)
        return resolve(self.plain())

    def plain(self):
        line = self.doc.lines[self.li]
        start = self.ci
        k = start
        while k < len(line):
            c = line[k]
            if c in ",[]{}":
                break
            if c == ":" and (k + 1 == len(line) or line[k + 1] in " \t,[]{}"):
                break
            if c == "#" and k > start and line[k - 1] in " \t":
                break
            k += 1
        text = line[start:k].rstrip(" \t")
        if text == "":
            self.fail("Değer bekleniyordu.")
        self.ci = start + len(text)
        return text

    def sequence(self):
        self.doc.enter(self.li)
        seq = Seq(self.li + 1)
        self.ci += 1
        while True:
            self.skip()
            if self.char() == "]":
                self.ci += 1
                break
            seq.item_lines.append(self.li + 1)
            seq.append(self.node())
            self.skip()
            c = self.char()
            if c == ":":
                self.fail("Liste içinde eşleme desteklenmiyor.")
            if c == ",":
                self.ci += 1
                continue
            if c == "]":
                self.ci += 1
                break
            self.fail("Liste içinde , ya da ] bekleniyordu.")
        self.doc.depth -= 1
        return seq

    def mapping(self):
        self.doc.enter(self.li)
        result = Map(self.li + 1)
        self.ci += 1
        while True:
            self.skip()
            c = self.char()
            if c == "}":
                self.ci += 1
                break
            line = self.li
            if c in ("'", '"'):
                key, self.ci = self.doc.quoted(self.li, self.ci)
            elif c in ("[", "{", "?"):
                self.fail("Karmaşık anahtar desteklenmiyor.")
            else:
                self.doc.unsupported(self.li, self.ci)
                key = self.plain()
            if key in result:
                self.fail("Aynı anahtar iki kez yazılmış: %s" % key)
            self.skip()
            value = None
            if self.char() == ":":
                self.ci += 1
                self.skip()
                if self.char() not in (",", "}"):
                    value = self.node()
            result[key] = value
            result.key_lines[key] = line + 1
            self.skip()
            c = self.char()
            if c == ",":
                self.ci += 1
                continue
            if c == "}":
                self.ci += 1
                break
            self.fail("Eşleme içinde , ya da } bekleniyordu.")
        self.doc.depth -= 1
        return result


def _segments(lines):
    """Split the stream into documents: (start, end, explicit) line ranges."""
    out = []
    start = 0
    explicit = False
    ended = False
    for i, line in enumerate(lines):
        if line.startswith("%"):
            raise YamlError("YAML yönergesi (%) desteklenmiyor.", i + 1)
        marker = line[:3]
        if marker == "---" and (len(line) == 3 or line[3] in " \t"):
            rest = line[3:].strip(" \t")
            if rest and not rest.startswith("#"):
                raise YamlError("Belge ayırıcısından (---) sonra aynı satırda içerik desteklenmiyor.", i + 1, 5)
            if not ended:
                out.append((start, i, explicit))
            start, explicit, ended = i + 1, True, False
            continue
        if marker == "..." and (len(line) == 3 or line[3] in " \t"):
            if not ended:
                out.append((start, i, explicit))
            start, explicit, ended = i + 1, False, True
            continue
        if ended:
            text = line.lstrip(" \t")
            if text and not text.startswith("#"):
                raise YamlError("Belge sonundan (...) sonra --- bekleniyordu.", i + 1)
    if not ended:
        out.append((start, len(lines), explicit))
    return out


def load_all(text):
    """Every document in text, as Map, Seq or scalar values (None for an empty explicit document)."""
    if not isinstance(text, str):
        raise TypeError("text must be str")
    if len(text.encode("utf-8", "surrogatepass")) > LIMIT_BYTES:
        raise YamlError("Dosya çok büyük (en çok %d KiB)." % (LIMIT_BYTES // 1024), 1)
    if text.startswith("﻿"):
        text = text[1:]
    if "\x00" in text:
        raise YamlError("Dosyada boş karakter (NUL) var.", text[:text.index("\x00")].count("\n") + 1)
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    docs = []
    for start, end, explicit in _segments(lines):
        doc = _Document(lines, start, end)
        if not explicit and doc.next_content(start) >= end:
            continue
        docs.append(doc.read())
    return docs


def load(text):
    """Exactly one document."""
    docs = load_all(text)
    if len(docs) != 1:
        raise YamlError("Dosyada tek belge bekleniyordu, %d belge var." % len(docs), 1)
    return docs[0]
