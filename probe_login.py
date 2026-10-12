#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Independent login probe for idis.ieml.ru / idp.ieml.ru (SimpleSAML + "RCPC" WAF).

Mirrors godot project session.gd:
  * manual cookie jar (per host) and manual redirect following (allow_redirects=False)
  * solves the slowAES "RCPC" challenge (AES-CBC decrypt, hex-encoded)
  * POSTs username/password/AuthState to loginuserpass.php with the same headers
  * follows the SAMLResponse auto-submit form
  * measures the POST time

Credentials come ONLY from environment variables:
    IDIS_LOGIN, IDIS_PASSWORD
They are never printed and never written to disk.

Run:
    pip install requests cryptography
    set IDIS_LOGIN=...        (Windows: set IDIS_PASSWORD=...)
    python probe_login.py
"""

import os
import re
import sys
import time
import datetime
import requests
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

BASE = "https://idis.ieml.ru/Education/protected/student-cabinet/GenerateScheduleLessons"
IDP_FORMS = {"Origin": "https://idp.ieml.ru", "Upgrade-Insecure-Requests": "1"}

TIMEOUT = 120  # seconds, as requested

jar = {}  # host -> {name: value}

RE_ABC = re.compile(r'toNumbers\("([0-9a-f]+)"\),b=toNumbers\("([0-9a-f]+)"\),c=toNumbers\("([0-9a-f]+)"\)')
RE_HREF = re.compile(r'document\.location\.href="([^"]+)"')
RE_FORM = re.compile(r'(?is)(<form\b[^>]*>)(.*?)</form>')
RE_INPUT = re.compile(r'(?is)<input\b[^>]*>')
RE_BUTTON = re.compile(r'(?is)<button\b[^>]*>.*?</button>')
RE_ACTION = re.compile(r'(?is)<form\b[^>]*action="([^"]*)"')


def host_of(url):
    m = re.match(r'^https?://([^/:]+)', url)
    return m.group(1) if m else ""


def cookie_header(host):
    return "; ".join("%s=%s" % (k, v) for k, v in jar.get(host, {}).items())


def set_cookie(host, name, value):
    jar.setdefault(host, {})[name] = value


def attr(tag, name):
    m = re.search(r'(?is)\b' + name + r'="([^"]*)"', tag)
    if m:
        return m.group(1)
    m = re.search(r"(?is)\b" + name + r"='([^']*)'", tag)
    if m:
        return m.group(1)
    return ""


def abs_url(base, loc):
    if loc.startswith("http://") or loc.startswith("https://"):
        return loc
    m = re.match(r'^(https?://[^/]+)', base)
    origin = m.group(1) if m else ""
    if loc.startswith("/"):
        return origin + loc
    path = base.split("?")[0]
    return path[:path.rfind("/") + 1] + loc


def do(method, url, extra=None, data=None):
    h = host_of(url)
    headers = {
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7",
        "Accept-Encoding": "identity",
    }
    ck = cookie_header(h)
    if ck:
        headers["Cookie"] = ck
    if extra:
        headers.update(extra)

    t0 = time.time()
    try:
        resp = requests.request(method, url, headers=headers, data=data,
                                allow_redirects=False, timeout=TIMEOUT)
    except Exception as exc:  # noqa: BLE001
        ms = int((time.time() - t0) * 1000)
        print("%s %s -> EXCEPTION %s: %s ms=%d" % (method, url, type(exc).__name__, exc, ms))
        return {"code": -1, "loc": "", "body": "", "url": url, "host": h, "ms": ms}

    ms = int((time.time() - t0) * 1000)
    try:
        for sc in resp.raw.headers.getlist("Set-Cookie"):
            pair = sc.split(";", 1)[0].strip()
            if "=" in pair:
                n, v = pair.split("=", 1)
                set_cookie(h, n.strip(), v.strip())
                print("  cookie set: %s on %s" % (n.strip(), h))
    except Exception:  # noqa: BLE001
        pass

    loc = resp.headers.get("Location", "")
    print("%s %s -> http=%d ms=%d len=%d" % (method, url, resp.status_code, ms, len(resp.content)))
    return {"code": resp.status_code, "loc": loc, "body": resp.text, "url": url, "host": h, "ms": ms}


def solve_waf(body, host):
    m = RE_ABC.search(body)
    if not m:
        print("  waf: abc not found")
        return ""
    key = bytes.fromhex(m.group(1))
    iv = bytes.fromhex(m.group(2))
    enc = bytes.fromhex(m.group(3))
    dec = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    out = dec.update(enc) + dec.finalize()
    hexv = out.hex()
    set_cookie(host, "RCPC", hexv)
    print("  waf solved: RCPC=%s on %s" % (hexv, host))
    hm = RE_HREF.search(body)
    return hm.group(1) if hm else ""


def get_follow(url, max_hops=14):
    cur = url
    r = {"code": -1, "loc": "", "body": "", "url": cur, "host": host_of(cur), "ms": 0}
    for _ in range(max_hops):
        r = do("GET", cur)
        if r["code"] == -1:
            return r
        if "slowAES.decrypt" in r["body"]:
            nxt = solve_waf(r["body"], r["host"])
            if nxt:
                cur = abs_url(cur, nxt)
                continue
        if 300 <= r["code"] < 400 and r["loc"]:
            cur = abs_url(cur, r["loc"])
            continue
        return r
    print("  too many hops")
    r["code"] = -2
    return r


def extract_form(body, only_field=""):
    for fm in RE_FORM.finditer(body):
        open_tag = fm.group(1)
        inner = fm.group(2)
        action = "?"
        am = RE_ACTION.search(open_tag)
        if am:
            action = am.group(1)
        fields = {}
        for im in RE_INPUT.finditer(inner):
            tag = im.group(0)
            n = attr(tag, "name")
            if n == "":
                continue
            t = attr(tag, "type").lower()
            if t in ("submit", "button", "image") and n != only_field:
                continue
            fields[n] = attr(tag, "value")
        if only_field:
            if only_field in fields:
                return fields[only_field]
            continue
        if "SAMLResponse" in fields:
            return {"action": action, "fields": fields}
    return {} if only_field == "" else ""


def finish_forms(r, max_loops=14):
    for _ in range(max_loops):
        if "slowAES.decrypt" in r["body"]:
            nxt = solve_waf(r["body"], r["host"])
            if nxt:
                r = do("GET", abs_url(r["url"], nxt))
                continue
        form = extract_form(r["body"])
        if form:
            action = abs_url(r["url"], form["action"])
            print("  submit form -> %s (%d fields)" % (action, len(form["fields"])))
            extra = dict(IDP_FORMS)
            extra["Referer"] = r["url"]
            r = do("POST", action, extra=extra, data=form["fields"])
            continue
        if 300 <= r["code"] < 400 and r["loc"]:
            r = do("GET", abs_url(r["url"], r["loc"]))
            continue
        break
    return r


def dump_login_form(body):
    found = False
    for fm in RE_FORM.finditer(body):
        open_tag = fm.group(1).strip()
        inner = fm.group(2)
        if "password" not in inner.lower():
            continue
        found = True
        print("LOGIN FORM OPEN: %s" % re.sub(r'\s+', ' ', open_tag))
        for im in RE_INPUT.finditer(inner):
            tag = im.group(0)
            n = attr(tag, "name")
            t = attr(tag, "type")
            v = attr(tag, "value")
            if t.lower() == "password":
                v = "<<hidden>>"
            print("  <input>  name='%s' type='%s' value='%s'" % (n, t, v))
        for bm in RE_BUTTON.finditer(inner):
            tag = bm.group(0)
            print("  <button> name='%s' type='%s' value='%s'"
                  % (attr(tag, "name"), attr(tag, "type"), attr(tag, "value")))
    if not found:
        print("no form containing a password input found")


def week_range(offset=0):
    monday = datetime.date.today() - datetime.timedelta(days=datetime.date.today().weekday())
    monday += datetime.timedelta(weeks=offset)
    sunday = monday + datetime.timedelta(days=6)
    return monday, sunday


def main():
    login = os.environ.get("IDIS_LOGIN", "")
    password = os.environ.get("IDIS_PASSWORD", "")
    if not login or not password:
        print("ERROR: set IDIS_LOGIN and IDIS_PASSWORD environment variables")
        return 2

    mon, sun = week_range(0)
    url = "%s?par_begindate=%s&par_enddate=%s" % (
        BASE, mon.strftime("%d.%m.%Y"), sun.strftime("%d.%m.%Y"))

    print("=== PROBE START ===")
    r = get_follow(url)
    if r["code"] == -1:
        print("no connection")
        return 1

    login_url = r["url"]
    authstate = extract_form(r["body"], "AuthState")
    dump_login_form(r["body"])
    if authstate == "":
        print("AuthState not found (url=%s)" % login_url)
        return 1

    post_url = login_url.split("?")[0]
    body = {"username": login, "password": password, "AuthState": authstate}
    extra = dict(IDP_FORMS)
    extra["Referer"] = login_url
    extra["Content-Type"] = "application/x-www-form-urlencoded"

    print("POST DETAILS url=%s" % post_url)
    print("  headers: %s" % ", ".join(sorted(extra.keys()) + ["Cookie"]))
    print("  cookie names: %s" % (", ".join(jar.get(host_of(post_url), {}).keys()) or "(none)"))
    print("  body fields: %s" % ", ".join(body.keys()))
    print("  body len: %d" % len(requests.models.PreparedRequest().prepare_url(
        post_url, {"username": login, "password": password, "AuthState": authstate})
        .encode("utf-8")))
    print("POST login -> %s (AuthState len=%d)" % (post_url, len(authstate)))

    r2 = do("POST", post_url, extra=extra, data=body)
    if r2["code"] == -1:
        print("POST FAILED: no response (ms=%d)" % r2["ms"])
        return 1
    print("POST duration: %d ms" % r2["ms"])

    final = finish_forms(r2)
    if "loginuserpass" in final["body"] or 'name="AuthState"' in final["body"]:
        print("RESULT: still on login page (bad login?)")
        return 1
    print("RESULT: login appears OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
