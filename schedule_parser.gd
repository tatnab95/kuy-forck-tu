class_name ScheduleParser
extends RefCounted
## Turns the protected schedule HTML into the app's data model, and builds
## the week ranges / URLs.
##
## Model:
##   {
##     "updated": "11.10.2026",
##     "days": [ { "date": "2026-10-12", "name": "Пн", "lessons": [
##         { "start": "13:10", "end": "14:30", "subject": "...",
##           "kind": "Лабораторная", "room": "210",
##           "building": "УК1, Вахитова 53/02", "teacher": "Нигметзянова В.М." } ] } ]
##   }

const BASE := "https://idis.ieml.ru/Education/protected/student-cabinet/GenerateScheduleLessons"

const WEEKDAYS := ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"]

const KINDS := [
	"Лабораторная работа", "Лабораторная", "Практическое занятие", "Практическая",
	"Лекция", "Семинар", "Консультация", "Зачёт", "Зачет", "Экзамен",
	"Дифференцированный зачёт", "Курсовая работа",
]

# ------------------------------------------------------------------ week math

## Week containing today, shifted by `offset` weeks. Monday-based.
static func week_range(offset: int = 0) -> Dictionary:
	var now := Time.get_datetime_dict_from_system()
	var dow := int(now.get("weekday", 1))          # 0=Sunday .. 6=Saturday
	var to_monday := (dow + 6) % 7                 # Monday -> 0
	var clean := {"year": int(now.year), "month": int(now.month), "day": int(now.day), "hour": 12}
	var base := Time.get_unix_time_from_datetime_dict(clean) - to_monday * 86400 + offset * 7 * 86400
	var mon := Time.get_datetime_dict_from_unix_time(int(base))
	var sun := Time.get_datetime_dict_from_unix_time(int(base) + 6 * 86400)
	return {
		"begin": _dot(mon),
		"end": _dot(sun),
		"begin_iso": _iso(mon),
		"end_iso": _iso(sun),
		"label": "%s – %s" % [_dmy(mon), _dmy(sun)],
	}

static func lessons_url(begin: String, end: String) -> String:
	return "%s?par_begindate=%s&par_enddate=%s" % [BASE, begin.uri_encode(), end.uri_encode()]

static func _dot(d: Dictionary) -> String:
	return "%02d.%02d.%04d" % [int(d.day), int(d.month), int(d.year)]

static func _iso(d: Dictionary) -> String:
	return "%04d-%02d-%02d" % [int(d.year), int(d.month), int(d.day)]

static func _dmy(d: Dictionary) -> String:
	return "%02d.%02d" % [int(d.day), int(d.month)]

static func weekday_name(iso: String) -> String:
	var parts := iso.split("-")
	if parts.size() != 3:
		return ""
	var dt := {"year": int(parts[0]), "month": int(parts[1]), "day": int(parts[2]), "hour": 12}
	var dow := int(Time.get_datetime_dict_from_unix_time(Time.get_unix_time_from_datetime_dict(dt)).weekday)
	return WEEKDAYS[dow]

static func today_dot() -> String:
	return _dot(Time.get_datetime_dict_from_system())

# ---------------------------------------------------------------------- parse

static func parse(html: String, _begin: String, _end: String) -> Dictionary:
	var days: Array = []
	for block in _day_blocks(html):
		var d := _parse_block(block)
		if not d.is_empty():
			days.append(d)
	return {"updated": today_dot(), "days": days}

## Split the page into per-day chunks.
static func _day_blocks(html: String) -> PackedStringArray:
	var out := PackedStringArray()
	var marker := "daily-box-wrapper"
	var idx := html.find(marker)
	if idx != -1:
		var positions: Array[int] = []
		while idx != -1:
			positions.append(idx)
			idx = html.find(marker, idx + marker.length())
		for i in positions.size():
			var start := positions[i]
			var stop := positions[i + 1] if i + 1 < positions.size() else html.length()
			out.append(html.substr(start, stop - start))
		return out

	# Fallback: split on date headings.
	var re := RegEx.new()
	re.compile("\\b\\d{2}\\.\\d{2}\\.\\d{4}\\b")
	var ms := re.search_all(html)
	for i in ms.size():
		var start := ms[i].get_start()
		var stop := ms[i + 1].get_start() if i + 1 < ms.size() else html.length()
		out.append(html.substr(start, stop - start))
	return out

static func _parse_block(block: String) -> Dictionary:
	var date_iso := _find_date_iso(block)
	var name := weekday_name(date_iso)
	return {
		"date": date_iso,
		"name": name,
		"lessons": _parse_lessons(block),
	}

static func _find_date_iso(block: String) -> String:
	var re := RegEx.new()
	re.compile("(\\d{2})\\.(\\d{2})\\.(\\d{4})")
	var m := re.search(block)
	if m == null:
		return ""
	return "%s-%s-%s" % [m.get_string(3), m.get_string(2), m.get_string(1)]

static func _parse_lessons(block: String) -> Array:
	var lessons: Array = []
	var re := RegEx.new()
	re.compile("(\\d{1,2}:\\d{2})\\s*[-–—]\\s*(\\d{1,2}:\\d{2})")
	var ms := re.search_all(block)
	for i in ms.size():
		var start := ms[i].get_string(1)
		var end := ms[i].get_string(2)
		var seg_start := ms[i].get_end()
		var seg_end := ms[i + 1].get_start() if i + 1 < ms.size() else block.length()
		var seg := block.substr(seg_start, seg_end - seg_start)
		var fields := _segment_fields(seg)
		fields["start"] = start
		fields["end"] = end
		lessons.append({
			"start": start,
			"end": end,
			"subject": fields.subject,
			"kind": fields.kind,
			"room": fields.room,
			"building": fields.building,
			"teacher": fields.teacher,
		})
	return lessons

static func _segment_fields(seg: String) -> Dictionary:
	var text := _strip_tags(seg)
	return {
		"kind": _find_kind(text),
		"teacher": _find_teacher(text),
		"room": _find_room(text),
		"building": _find_building(text),
		"subject": _find_subject(text),
	}

static func _find_kind(text: String) -> String:
	for k in KINDS:
		if text.find(k) != -1:
			return k
	return ""

static func _find_teacher(text: String) -> String:
	var re := RegEx.new()
	# Фамилия И.О.  or  Фамилия И. О.
	re.compile("[А-ЯЁ][а-яё]+(?:-[А-ЯЁ][а-яё]+)?\\s+[А-ЯЁ]\\.\\s?[А-ЯЁ]\\.")
	var m := re.search(text)
	if m != null:
		return m.get_string(0).strip_edges()
	# Фамилия Имя Отчество
	var re2 := RegEx.new()
	re2.compile("[А-ЯЁ][а-яё]+\\s+[А-ЯЁ][а-яё]+\\s+[А-ЯЁ][а-яё]+(?:ов|ев|ин|ий|ова|ева|ина)?")
	var m2 := re2.search(text)
	if m2 != null:
		return m2.get_string(0).strip_edges()
	return ""

static func _find_room(text: String) -> String:
	var re := RegEx.new()
	re.compile("(?i)(?:каб(?:инет)?|ауд(?:итория)?)[.\\s№:]*([0-9]{1,4}[а-яa-z]?)")
	var m := re.search(text)
	if m != null:
		return m.get_string(1)
	return ""

static func _find_building(text: String) -> String:
	var re := RegEx.new()
	re.compile("(?i)УК\\s*№?\\s*[0-9]+[^<>]*")
	var m := re.search(text)
	if m != null:
		return m.get_string(0).strip_edges()
	return ""

static func _find_subject(text: String) -> String:
	# Best effort: first sizeable run of words after stripping known noise.
	var s := text
	for k in ["Лабораторная работа", "Лабораторная", "Практическое занятие",
			"Практическая", "Лекция", "Семинар", "Консультация", "Зачёт",
			"Зачет", "Экзамен"]:
		s = s.replace(k, " ")
	var re := RegEx.new()
	re.compile("(?i)(?:каб(?:инет)?|ауд(?:итория)?)[.\\s№:]*[0-9]{1,4}[а-яa-z]?")
	s = re.sub(s, " ", true)
	s = s.replace("\n", " ").strip_edges()
	while s.find("  ") != -1:
		s = s.replace("  ", " ")
	return s.substr(0, 80).strip_edges()

static func _strip_tags(s: String) -> String:
	var re := RegEx.new()
	re.compile("(?s)<[^>]+>")
	var text := re.sub(s, " ", true)
	text = text.replace("&nbsp;", " ").replace("&amp;", "&").replace("&laquo;", "«") \
		.replace("&raquo;", "»").replace("&quot;", "\"").replace("&#39;", "'")
	return _collapse(text)

static func _collapse(s: String) -> String:
	var out := ""
	var prev_space := false
	for ch in s:
		var is_space := ch == " " or ch == "\t" or ch == "\n" or ch == "\r"
		if is_space:
			if not prev_space:
				out += " "
			prev_space = true
		else:
			out += ch
			prev_space = false
	return out.strip_edges()
