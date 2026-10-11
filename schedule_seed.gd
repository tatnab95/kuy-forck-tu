class_name ScheduleSeed
extends RefCounted
## Sample week shown on first run before any successful fetch, so the UI can
## be previewed offline. Replaced by real data as soon as a fetch succeeds.

static func sample() -> Dictionary:
	var wk := ScheduleParser.week_range(0)
	var d0: String = wk["begin_iso"]
	var d1 := _next_day(d0, 1)
	var d2 := _next_day(d0, 2)
	return {
		"updated": ScheduleParser.today_dot(),
		"days": [
			{
				"date": d0,
				"name": ScheduleParser.weekday_name(d0),
				"lessons": [
					{"start": "08:30", "end": "09:50", "subject": "Математика",
						"kind": "Лекция", "room": "210",
						"building": "УК1, Вахитова 53/02", "teacher": "Нигметзянова В.М."},
					{"start": "10:00", "end": "11:20", "subject": "Информатика",
						"kind": "Лабораторная", "room": "312",
						"building": "УК1, Вахитова 53/02", "teacher": "Иванов И.И."},
				],
			},
			{
				"date": d1,
				"name": ScheduleParser.weekday_name(d1),
				"lessons": [
					{"start": "13:10", "end": "14:30", "subject": "Экономика",
						"kind": "Практическое занятие", "room": "105",
						"building": "УК2, Московская 42", "teacher": "Петрова А.С."},
				],
			},
			{
				"date": d2,
				"name": ScheduleParser.weekday_name(d2),
				"lessons": [],
			},
		],
	}

static func _next_day(iso: String, days: int) -> String:
	var parts := iso.split("-")
	var dt := {"year": int(parts[0]), "month": int(parts[1]), "day": int(parts[2]), "hour": 12}
	var unix := Time.get_unix_time_from_datetime_dict(dt) + days * 86400
	var d := Time.get_datetime_dict_from_unix_time(unix)
	return "%04d-%02d-%02d" % [int(d.year), int(d.month), int(d.day)]
