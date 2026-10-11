extends Node
## Persistence layer (autoload "Store").
## - credentials, encrypted at rest with the device id
## - cached schedule (JSON)
## - debug log file + in-memory ring buffer for the on-screen panel

signal debug_line(line: String)

const CRED_PATH := "user://credentials.dat"
const SCHED_PATH := "user://schedule.json"
const DEBUG_PATH := "user://debug.log"
const MAX_DEBUG_LINES := 500

var _buf: PackedStringArray = []

func _ready() -> void:
	# Make sure user:// exists and the debug file is present.
	if not FileAccess.file_exists(DEBUG_PATH):
		var f := FileAccess.open(DEBUG_PATH, FileAccess.WRITE)
		if f:
			f.close()
	_load_debug_tail()

# ---------------------------------------------------------------- credentials

func _secret() -> String:
	var uid := OS.get_unique_id()
	if uid.is_empty():
		uid = "idis-desktop-fallback"
	return "idis::v1::" + uid

func save_credentials(login: String, password: String) -> bool:
	var payload := JSON.stringify({"login": login, "password": password})
	var f := FileAccess.open_encrypted_with_pass(CRED_PATH, FileAccess.WRITE, _secret())
	if f == null:
		debug("save_credentials: cannot open file (%d)" % FileAccess.get_open_error())
		return false
	f.store_string(payload)
	f.close()
	debug("credentials saved")
	return true

func load_credentials() -> Dictionary:
	if not FileAccess.file_exists(CRED_PATH):
		return {}
	var f := FileAccess.open_encrypted_with_pass(CRED_PATH, FileAccess.READ, _secret())
	if f == null:
		debug("load_credentials: cannot open file (%d)" % FileAccess.get_open_error())
		return {}
	var txt := f.get_as_text()
	f.close()
	var v: Variant = JSON.parse_string(txt)
	if typeof(v) == TYPE_DICTIONARY:
		return v
	return {}

func has_credentials() -> bool:
	var c := load_credentials()
	return c.has("login") and c.has("password") and String(c["login"]) != ""

func clear_credentials() -> void:
	_remove(CRED_PATH)
	debug("credentials cleared")

# ------------------------------------------------------------------- schedule

func save_schedule(data: Dictionary) -> void:
	var f := FileAccess.open(SCHED_PATH, FileAccess.WRITE)
	if f == null:
		debug("save_schedule: cannot open file (%d)" % FileAccess.get_open_error())
		return
	f.store_string(JSON.stringify(data))
	f.close()

func load_schedule() -> Dictionary:
	if not FileAccess.file_exists(SCHED_PATH):
		return {}
	var f := FileAccess.open(SCHED_PATH, FileAccess.READ)
	if f == null:
		return {}
	var v: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(v) == TYPE_DICTIONARY:
		return v
	return {}

func has_schedule() -> bool:
	return FileAccess.file_exists(SCHED_PATH)

# ---------------------------------------------------------------------- debug

func debug(msg: String) -> void:
	var stamp := Time.get_time_string_from_system()
	var line := "[%s] %s" % [stamp, msg]
	_buf.append(line)
	while _buf.size() > MAX_DEBUG_LINES:
		_buf.remove_at(0)
	print(line)
	var f := FileAccess.open(DEBUG_PATH, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(DEBUG_PATH, FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_line(line)
		f.close()
	debug_line.emit(line)

func debug_text() -> String:
	return "\n".join(_buf)

func clear_debug() -> void:
	_buf.clear()
	var f := FileAccess.open(DEBUG_PATH, FileAccess.WRITE)
	if f:
		f.close()

func _load_debug_tail() -> void:
	var f := FileAccess.open(DEBUG_PATH, FileAccess.READ)
	if f == null:
		return
	var lines := f.get_as_text().split("\n")
	f.close()
	_buf.clear()
	for i in range(max(0, lines.size() - MAX_DEBUG_LINES), lines.size()):
		if String(lines[i]).strip_edges() != "":
			_buf.append(lines[i])

func _remove(path: String) -> void:
	var d := DirAccess.open(path.get_base_dir())
	if d:
		d.remove(path.get_file())
