extends Node
## Network + auth (autoload "Session").
##
## Replicates the browser flow against idis.ieml.ru / idp.ieml.ru:
##   1. GET the schedule URL -> 302 to the SAML IdP (idp.ieml.ru)
##   2. the IdP answers with a JS browser-check page (the "RCPC" WAF challenge);
##      we solve it (AES-CBC of the challenge blob) and retry
##   3. we land on the SimpleSAML login form; POST username/password/AuthState
##   4. the IdP returns a SAMLResponse auto-submit form; POST it to the ACS
##   5. the session cookies are then set on idis.ieml.ru and we GET the schedule
##
## Cookies are kept manually because HTTPRequest has no cookie jar, and
## redirects are followed manually so we can interleave the WAF solving.

signal status(text: String)
signal auth_changed(logged_in: bool)

const UA := "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

var cookies: Dictionary = {}          # host -> { name: value }
var logged_in: bool = false
var last_error: String = ""

func debug(msg: String) -> void:
	Store.debug("net: " + msg)

# ------------------------------------------------------------------ public API

## Fetch one week. Returns {"error": String, "data": Dictionary}.
## An empty (but valid) week yields data with an empty "days" array.
func get_week(begin: String, end: String) -> Dictionary:
	var url := ScheduleParser.lessons_url(begin, end)
	status.emit("Загрузка…")
	var r := await _get_follow(url)
	if r.get("code", -1) == -1:
		last_error = "Нет соединения"
		status.emit(last_error)
		return {"error": last_error, "data": {}}

	if _needs_login(r):
		debug("session expired -> re-login")
		if not await _relogin():
			status.emit(last_error)
			return {"error": last_error, "data": {}}
		r = await _get_follow(url)
		if _needs_login(r):
			last_error = "Не удалось авторизоваться"
			status.emit(last_error)
			return {"error": last_error, "data": {}}

	logged_in = true
	auth_changed.emit(true)

	var data := ScheduleParser.parse(r.get("body", ""), begin, end)
	if data.get("days", []).is_empty():
		var body: String = r.get("body", "")
		debug("no lessons parsed; page len=%d url=%s" % [body.length(), r.get("final_url", "")])
		debug("schedule head: " + body.substr(0, 3000))
	status.emit("Обновлено")
	return {"error": "", "data": data}

## Log in with explicit credentials (used by the login dialog).
func login(login_name: String, password: String) -> bool:
	last_error = ""
	logged_in = false
	debug("=== LOGIN START ===")

	var wk := ScheduleParser.week_range(0)
	var r := await _get_follow(ScheduleParser.lessons_url(wk.begin, wk.end))
	if r.get("code", -1) == -1:
		last_error = "Нет соединения"
		return false

	if not _is_login_page(r):
		# Already authenticated (a valid session was still alive).
		logged_in = true
		auth_changed.emit(true)
		debug("already authenticated")
		return true

	var login_url: String = r.get("final_url", "")
	var authstate := _field(r.get("body", ""), "AuthState")
	if authstate == "":
		last_error = "Форма входа не найдена"
		debug("AuthState not found on login page (url=%s)" % login_url)
		return false

	# The SimpleSAML form posts to action="?" (same path, empty query).
	var post_url := login_url.split("?")[0]
	var form := "username=%s&password=%s&AuthState=%s" % [
		_uri(login_name), _uri(password), _uri(authstate)
	]
	debug("POST login -> %s (AuthState len=%d)" % [post_url, authstate.length()])
	var r2 := await _request(HTTPClient.METHOD_POST, post_url,
		PackedStringArray(["Content-Type: application/x-www-form-urlencoded"]),
		form.to_utf8_buffer())
	debug("login POST <- code=%d len=%d loc=%s" % [r2.code, String(r2.body).length(), r2.loc])

	var final := await _finish_forms(r2, 14)
	if _is_login_page(final):
		last_error = "Неверный логин или пароль"
		debug("login failed: still on login page")
		return false

	logged_in = true
	auth_changed.emit(true)
	debug("=== LOGIN OK ===")
	return true

func _relogin() -> bool:
	var creds := Store.load_credentials()
	if not creds.has("login") or not creds.has("password"):
		last_error = "Нужно войти"
		return false
	return await login(String(creds["login"]), String(creds["password"]))

# --------------------------------------------------------------- WAF "RCPC"

const _RE_ABC := "toNumbers\\(\"([0-9a-f]+)\"\\),b=toNumbers\\(\"([0-9a-f]+)\"\\),c=toNumbers\\(\"([0-9a-f]+)\"\\)"
const _RE_HREF := "document\\.location\\.href=\"([^\"]+)\""

func _solve_waf(body: String, host: String) -> String:
	var re := RegEx.new()
	if re.compile(_RE_ABC) != OK:
		return ""
	var m := re.search(body)
	if m == null:
		return ""
	var key := _unhex(m.get_string(1))
	var iv := _unhex(m.get_string(2))
	var enc := _unhex(m.get_string(3))

	var aes := AESContext.new()
	if aes.start(AESContext.MODE_CBC_DECRYPT, key, iv) != OK:
		debug("waf: AESContext.start failed")
		return ""
	var dec := aes.update(enc)
	var hex := dec.hex_encode()
	set_cookie(host, "RCPC", hex)
	debug("waf solved: set RCPC=%s on %s" % [hex, host])

	var rh := RegEx.new()
	if rh.compile(_RE_HREF) != OK:
		return ""
	var hm := rh.search(body)
	if hm == null:
		return ""
	return hm.get_string(1)

func _unhex(s: String) -> PackedByteArray:
	var out := PackedByteArray()
	var i := 0
	while i + 1 < s.length():
		out.append(s.substr(i, 2).hex_to_int())
		i += 2
	return out

# ------------------------------------------------------------ http plumbing

func _request(method: int, url: String, extra_headers: PackedStringArray, body: PackedByteArray) -> Dictionary:
	var http := HTTPRequest.new()
	http.max_redirects = 0
	http.timeout = 30.0
	add_child(http)
	await get_tree().process_frame

	var host := _host_of(url)
	var headers := PackedStringArray([
		"User-Agent: " + UA,
		"Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
		"Accept-Language: ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7",
		"Accept-Encoding: identity",
	])
	var ck := cookie_header(host)
	if ck != "":
		headers.append("Cookie: " + ck)
	for h in extra_headers:
		headers.append(h)

	var err := http.request_raw(url, headers, method, body)
	if err != OK:
		http.queue_free()
		debug("request error %d for %s" % [err, url])
		return {"code": -1, "url": url, "loc": "", "body": "", "host": host}

	var res: Array = await http.request_completed
	http.queue_free()

	var rh: PackedStringArray = res[2]
	_store_set_cookies(host, rh)
	debug("%s %s -> %d" % [("POST" if method == HTTPClient.METHOD_POST else "GET"), _short(url), int(res[1])])
	return {
		"code": int(res[1]),
		"url": url,
		"loc": _header(rh, "location"),
		"body": (res[3] as PackedByteArray).get_string_from_utf8(),
		"host": host,
	}

## GET following redirects and solving WAF challenges until a final page.
func _get_follow(url: String, max_hops: int = 14) -> Dictionary:
	var cur := url
	var r := {"code": -1, "final_url": cur, "body": "", "loc": "", "host": _host_of(cur)}
	for i in max_hops:
		r = await _request(HTTPClient.METHOD_GET, cur, PackedStringArray(), PackedByteArray())
		if r.code == -1:
			return r
		if _is_waf(r.body):
			var nxt := _solve_waf(r.body, r.host)
			if nxt != "":
				cur = _abs(cur, nxt)
				continue
		if r.code >= 300 and r.code < 400 and r.loc != "":
			cur = _abs(cur, r.loc)
			continue
		r["final_url"] = cur
		return r
	r["final_url"] = cur
	r["code"] = -2
	debug("too many hops for %s" % _short(url))
	return r

## Keep following redirects / posting auto-submitted forms (SAML in particular).
func _finish_forms(from: Dictionary, max_loops: int) -> Dictionary:
	var r := from
	for i in max_loops:
		if _is_waf(r.body):
			var nxt := _solve_waf(r.body, r.host)
			if nxt != "":
				r = await _request(HTTPClient.METHOD_GET, _abs(r.url, nxt), PackedStringArray(), PackedByteArray())
				continue
		var form: Variant = _extract_form(r.body)
		if not form.is_empty():
			var action: String = _abs(r.url, String(form["action"]))
			var body := _build_form_body(form["fields"])
			debug("submit form -> %s (%d fields)" % [_short(action), (form["fields"] as Dictionary).size()])
			r = await _request(HTTPClient.METHOD_POST, action,
				PackedStringArray(["Content-Type: application/x-www-form-urlencoded"]),
				body.to_utf8_buffer())
			continue
		if r.code >= 300 and r.code < 400 and r.loc != "":
			r = await _request(HTTPClient.METHOD_GET, _abs(r.url, r.loc), PackedStringArray(), PackedByteArray())
			continue
		break
	return r

# ------------------------------------------------------------ classification

func _is_waf(body: String) -> bool:
	return body.find("slowAES.decrypt") != -1

func _is_login_page(r: Dictionary) -> bool:
	if typeof(r) != TYPE_DICTIONARY:
		return false
	var body: String = r.get("body", "")
	var url: String = r.get("final_url", r.get("url", ""))
	return body.find("loginuserpass") != -1 \
		or body.find("name=\"AuthState\"") != -1 \
		or body.find("Центр авторизации") != -1 \
		or url.find("loginuserpass") != -1

func _needs_login(r: Dictionary) -> bool:
	return _is_login_page(r) or String(r.get("final_url", "")).find("idp.ieml.ru") != -1

# ------------------------------------------------------------------ cookies

func _host_of(url: String) -> String:
	var re := RegEx.new()
	re.compile("^https?://([^/:]+)")
	var m := re.search(url)
	return m.get_string(1) if m != null else ""

func cookie_header(host: String) -> String:
	var jar: Dictionary = cookies.get(host, {})
	var parts := PackedStringArray()
	for k in jar:
		parts.append("%s=%s" % [k, jar[k]])
	return "; ".join(parts)

func set_cookie(host: String, name: String, value: String) -> void:
	if not cookies.has(host):
		cookies[host] = {}
	cookies[host][name] = value

func _store_set_cookies(host: String, headers: PackedStringArray) -> void:
	for h in headers:
		var low := h.to_lower()
		if not low.begins_with("set-cookie:"):
			continue
		var pair := h.substr(11).strip_edges().split(";")[0]
		var eq := pair.find("=")
		if eq <= 0:
			continue
		var name := pair.substr(0, eq).strip_edges()
		var value := pair.substr(eq + 1).strip_edges()
		set_cookie(host, name, value)
		debug("cookie set: %s=%s…" % [name, value.substr(0, min(6, value.length()))])

func _header(headers: PackedStringArray, name: String) -> String:
	var key := name.to_lower() + ":"
	for h in headers:
		if h.to_lower().begins_with(key):
			return h.substr(key.length()).strip_edges()
	return ""

# ------------------------------------------------------------- html helpers

func _field(body: String, name: String) -> String:
	return _extract_form(body, name)

## Pull a named field value from the first form that contains it.
func _extract_form(body: String, only_field: String = "") -> Variant:
	var form_re := RegEx.new()
	if form_re.compile("(?is)(<form\\b[^>]*>)(.*?)</form>") != OK:
		return {} if only_field == "" else ""
	var form_matches := form_re.search_all(body)
	for fm in form_matches:
		var open_tag := fm.get_string(1)
		var inner := fm.get_string(2)
		var action := "?"
		var ar := RegEx.new()
		if ar.compile("(?is)<form\\b[^>]*action=\"([^\"]*)\"") == OK:
			var am := ar.search(open_tag)
			if am != null:
				action = am.get_string(1)
		var fields := {}
		var ir := RegEx.new()
		ir.compile("(?is)<input\\b[^>]*>")
		for im in ir.search_all(inner):
			var tag := im.get_string(0)
			var n := _attr(tag, "name")
			if n == "":
				continue
			var v := _attr(tag, "value")
			var t := _attr(tag, "type").to_lower()
			if t == "submit" or t == "button" or t == "image":
				if only_field == "":
					continue
				if n != only_field:
					continue
			fields[n] = v
		if only_field != "":
			if fields.has(only_field):
				return String(fields[only_field])
			continue
		if fields.has("SAMLResponse"):
			return {"action": action, "fields": fields}
	return {} if only_field == "" else ""

func _attr(tag: String, name: String) -> String:
	var re := RegEx.new()
	if re.compile("(?is)\\b" + name + "=\"([^\"]*)\"") == OK:
		var m := re.search(tag)
		if m != null:
			return _unescape(m.get_string(1))
	var re2 := RegEx.new()
	if re2.compile("(?is)\\b" + name + "='([^']*)'") == OK:
		var m2 := re2.search(tag)
		if m2 != null:
			return _unescape(m2.get_string(1))
	return ""

func _build_form_body(fields: Dictionary) -> String:
	var parts := PackedStringArray()
	for k in fields:
		parts.append("%s=%s" % [_uri(String(k)), _uri(String(fields[k]))])
	return "&".join(parts)

func _unescape(s: String) -> String:
	return s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">") \
		.replace("&#39;", "'").replace("&quot;", "\"").replace("&#x2F;", "/") \
		.replace("&#47;", "/")

func _uri(s: String) -> String:
	return s.uri_encode()

func _abs(base: String, loc: String) -> String:
	if loc.begins_with("http://") or loc.begins_with("https://"):
		return loc
	var re := RegEx.new()
	re.compile("^(https?://[^/]+)")
	var m := re.search(base)
	var origin := m.get_string(1) if m != null else ""
	if loc.begins_with("/"):
		return origin + loc
	# relative to the base path
	var path := base.split("?")[0]
	var slash := path.rfind("/")
	return path.substr(0, slash + 1) + loc

func _short(url: String) -> String:
	if url.length() <= 90:
		return url
	return url.substr(0, 90) + "…"
