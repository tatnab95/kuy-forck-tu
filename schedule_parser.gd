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
##           "kind": "Лабораторная", "topic": "...", "room": "210",
##           "building": "УК1, Вахитова 53/02", "teacher": "Нигметзянова В.М.",
##           "groups": "ПИ-21-1" } ] } ]
##   }
##
## Parsing is class-driven (stable) with a text fallback:
##   daily-box-wrapper       -> one day
##     box-content-header    -> "dd.mm.yyyy, <weekday>"
##     sub-time              -> "hh:mm - hh:mm"   (starts a new lesson)
##     box-content-subheader -> building / room
##     disc-inf-header       -> subject / kind / topic
##     disc-inf-bottom       -> groups / teacher

const BASE := "https://idis.ieml.ru/Education/protected/student-cabinet/GenerateScheduleLessons"

const WEEKDAYS := ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"]

## Raw wording on the site -> the short form used by the UI.
## The site writes «Лекции», «Лабораторные занятия», «Практические занятия».
const KINDS := {
	"Дифференцированный зачёт": "Диф. зачёт",
	"Дифференцированный зачет": "Диф. зачёт",
	"Курсовая работа": "Курсовая",
	"Лабораторные занятия": "Лабораторная",
	"Лабораторные работы": "Лабораторная",
	"Лабораторная работа": "Лабораторная",
	"Практические занятия": "Практика",
	"Практические работы": "Практика",
	"Семинарские занятия": "Семинар",
	"Практическая": "Практика",
	"Лабораторная": "Лабораторная",
	"Консультация": "Консультация",
	"Семинары": "Семинар",
	"Семинар": "Семинар",
	"Экзамен": "Экзамен",
	"Лекции": "Лекция",
	"Лекция": "Лекция",
	"Практика": "Практика",
	"Зачёт": "Зачёт",
	"Зачет": "Зачёт",
}

const CLS_DAY := "daily-box-wrapper"
const CLS_DATE := "box-content-header"
const CLS_TIME := "sub-time"
const CLS_PLACE := "box-content-subheader"
const CLS_DISC_HEAD := "disc-inf-header"
const CLS_DISC_BOTTOM := "disc-inf-bottom"

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
	var ranges := _day_ranges(html)
	if not ranges.is_empty():
		for r in ranges:
			var d := _parse_day(html.substr(r[0], r[1] - r[0]))
			if not d.is_empty():
				days.append(d)
	else:
		# Fallback for unexpected markup: split by dates / time ranges.
		for block in _day_blocks(html):
			var d := _parse_block(block)
			if not d.is_empty():
				days.append(d)
	return {"updated": today_dot(), "days": days}

## Positions of each element carrying `cls` inside `html`.
## Returns [{ "tag_start", "tag_end", "cls" }].
static func _class_anchors(html: String, cls: String) -> Array:
	var out: Array = []
	var re := RegEx.new()
	if re.compile("class\\s*=\\s*\"([^\"]*)\"") != OK:
		return out
	var needle := " " + cls + " "
	for m in re.search_all(html):
		if (" " + m.get_string(1) + " ").find(needle) == -1:
			continue
		var attr_pos := m.get_start()
		var tag_start := html.rfind("<", attr_pos)
		var tag_end := html.find(">", attr_pos)
		if tag_start == -1 or tag_end == -1:
			continue
		out.append({"tag_start": tag_start, "tag_end": tag_end + 1, "cls": cls})
	return out

## One entry per day: [start, stop) byte range.
static func _day_ranges(html: String) -> Array:
	var marks := _class_anchors(html, CLS_DAY)
	var out: Array = []
	for i in marks.size():
		var start: int = marks[i]["tag_start"]
		var stop: int = html.length() if i + 1 >= marks.size() else int(marks[i + 1]["tag_start"])
		out.append([start, stop])
	return out

## Parse one day (`daily-box-wrapper` substring), driven by the field classes.
static func _parse_day(block: String) -> Dictionary:
	var items: Array = []
	items.append_array(_class_anchors(block, CLS_DATE))
	items.append_array(_class_anchors(block, CLS_TIME))
	items.append_array(_class_anchors(block, CLS_PLACE))
	items.append_array(_class_anchors(block, CLS_DISC_HEAD))
	items.append_array(_class_anchors(block, CLS_DISC_BOTTOM))
	if items.is_empty():
		return {}
	items.sort_custom(func(a, b): return int(a["tag_start"]) < int(b["tag_start"]))
	# Sentinel: closes the last real element.
	items.append({"tag_start": block.length(), "tag_end": block.length(), "cls": ""})

	var date_iso := ""
	var lessons: Array = []
	var cur := _empty_lesson()
	var has_cur := false

	for i in range(items.size() - 1):
		var it: Dictionary = items[i]
		var nxt: Dictionary = items[i + 1]
		var from := int(it["tag_end"])
		var seg := block.substr(from, int(nxt["tag_start"]) - from)
		var text := _strip_tags(seg)
		match String(it["cls"]):
			CLS_DATE:
				date_iso = _date_from_text(text)
			CLS_TIME:
				if has_cur and String(cur.get("start", "")) != "":
					lessons.append(cur)
					cur = _empty_lesson()
				elif not has_cur:
					has_cur = true
				var tm := _split_time(text)
				cur["start"] = tm["start"]
				cur["end"] = tm["end"]
			CLS_PLACE:
				if not has_cur:
					has_cur = true
				var place := _split_place(text)
				cur["building"] = place["building"]
				cur["room"] = place["room"]
			CLS_DISC_HEAD:
				if not has_cur:
					has_cur = true
				var dh := _split_disc_header(text)
				cur["subject"] = dh["subject"]
				cur["kind"] = dh["kind"]
				cur["topic"] = dh["topic"]
			CLS_DISC_BOTTOM:
				if not has_cur:
					has_cur = true
				var db := _split_disc_bottom(text)
				cur["groups"] = db["groups"]
				cur["teacher"] = db["teacher"]
	if has_cur and not cur.is_empty():
		lessons.append(cur)

	return {"date": date_iso, "name": weekday_name(date_iso), "lessons": lessons}

static func _empty_lesson() -> Dictionary:
	return {
		"start": "", "end": "", "subject": "", "kind": "", "topic": "",
		"room": "", "building": "", "teacher": "", "groups": "",
	}

static func _date_from_text(text: String) -> String:
	var re := RegEx.new()
	re.compile("(\\d{2})\\.(\\d{2})\\.(\\d{4})")
	var m := re.search(text)
	if m == null:
		return ""
	return "%s-%s-%s" % [m.get_string(3), m.get_string(2), m.get_string(1)]

static func _split_time(text: String) -> Dictionary:
	var re := RegEx.new()
	re.compile("(\\d{1,2}:\\d{2})\\s*[-–—]\\s*(\\d{1,2}:\\d{2})")
	var m := re.search(text)
	if m != null:
		return {"start": m.get_string(1), "end": m.get_string(2)}
	var re1 := RegEx.new()
	re1.compile("(\\d{1,2}:\\d{2})")
	var m1 := re1.search(text)
	if m1 != null:
		return {"start": m1.get_string(1), "end": ""}
	return {"start": "", "end": ""}

## "УК1, Вахитова 53/02, ауд. 210" -> building="УК1, Вахитова 53/02", room="210".
static func _split_place(text: String) -> Dictionary:
	var t := text.strip_edges()
	var re := RegEx.new()
	re.compile("(?i)(?:каб(?:инет)?|ауд(?:итория)?)[.\\s№:]*([0-9]{1,4}[а-яa-z]?)")
	var m := re.search(t)
	if m != null:
		var building := t.substr(0, m.get_start()).strip_edges().trim_suffix(",").strip_edges()
		return {"building": building, "room": m.get_string(1)}
	# No "ауд./каб." keyword: trailing number is the room, the rest the building.
	var re2 := RegEx.new()
	re2.compile("([0-9]{1,4}[а-яa-z]?)\\s*$")
	var m2 := re2.search(t)
	if m2 != null:
		var building2 := t.substr(0, m2.get_start()).strip_edges().trim_suffix(",").strip_edges()
		if building2 != "":
			return {"building": building2, "room": m2.get_string(1)}
	return {"building": t, "room": ""}

## "Математический анализ / Лекции / Тема: Пределы"
##   -> subject="Математический анализ", kind="Лекция", topic="Тема: Пределы".
static func _split_disc_header(text: String) -> Dictionary:
	var t := text.strip_edges()
	for key in _kind_keys():
		var pos := t.find(key)
		if pos == -1:
			continue
		var subject := t.substr(0, pos).strip_edges().trim_suffix("/").strip_edges()
		var topic := t.substr(pos + key.length()).strip_edges()
		topic = topic.trim_prefix("/").trim_prefix(":").strip_edges()
		return {"subject": subject, "kind": String(KINDS[key]), "topic": topic}
	return {"subject": t, "kind": _find_kind(t), "topic": ""}

## "ПИ-21-1, ПИ-21-2 - Нигметзянова В.М." -> groups="ПИ-21-1, ПИ-21-2", teacher="…".
static func _split_disc_bottom(text: String) -> Dictionary:
	var t := text.strip_edges()
	var teacher := _find_teacher(t)
	if teacher != "":
		var pos := t.find(teacher)
		var groups := t.substr(0, pos).strip_edges().trim_suffix("-").strip_edges()
		return {"groups": groups, "teacher": teacher}
	return {"groups": t, "teacher": ""}

static func _kind_keys() -> Array:
	var keys := KINDS.keys()
	keys.sort_custom(func(a, b): return String(a).length() > String(b).length())
	return keys

static func _find_kind(text: String) -> String:
	for key in _kind_keys():
		if text.find(String(key)) != -1:
			return String(KINDS[key])
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

## Bounded to the first room keyword (or 60 chars) so it can't swallow the
## whole block.
static func _find_building(text: String) -> String:
	var t := text
	var re_room := RegEx.new()
	re_room.compile("(?i)(?:каб(?:инет)?|ауд(?:итория)?)")
	var rm := re_room.search(t)
	if rm != null:
		t = t.substr(0, rm.get_start())
	var i := t.find("УК")
	if i == -1:
		return ""
	return t.substr(i, 60).strip_edges()

static func _find_subject(text: String) -> String:
	var s := text
	for key in _kind_keys():
		s = s.replace(String(key), " ")
	var re := RegEx.new()
	re.compile("(?i)(?:каб(?:инет)?|ауд(?:итория)?)[.\\s№:]*[0-9]{1,4}[а-яa-z]?")
	s = re.sub(s, " ", true)
	s = s.replace("\n", " ").strip_edges()
	while s.find("  ") != -1:
		s = s.replace("  ", " ")
	return s.substr(0, 80).strip_edges()

# ------------------------------------------------------- text fallback (rare)

## Split the page into per-day chunks (used only when no daily-box-wrapper).
static func _day_blocks(html: String) -> PackedStringArray:
	var out := PackedStringArray()
	var marker := CLS_DAY
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
	return {
		"date": date_iso,
		"name": weekday_name(date_iso),
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
		lessons.append({
			"start": start,
			"end": end,
			"subject": fields["subject"],
			"kind": fields["kind"],
			"topic": fields["topic"],
			"room": fields["room"],
			"building": fields["building"],
			"teacher": fields["teacher"],
			"groups": fields["groups"],
		})
	return lessons

static func _segment_fields(seg: String) -> Dictionary:
	var text := _strip_tags(seg)
	var dh := _split_disc_header(text)
	var db := _split_disc_bottom(text)
	return {
		"kind": dh["kind"],
		"subject": dh["subject"],
		"topic": dh["topic"],
		"teacher": db["teacher"],
		"groups": db["groups"],
		"room": _find_room(text),
		"building": _find_building(text),
	}

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
