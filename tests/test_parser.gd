extends SceneTree
## Headless parser test: res://tests/fixture_schedule.html
##   godot --headless --path <project> -s res://tests/test_parser.gd

func _init() -> void:
	var path := "res://tests/fixture_schedule.html"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Cannot open " + path)
		quit(1)
		return
	var html := f.get_as_text()
	f.close()

	var data := ScheduleParser.parse(html, "12.10.2026", "18.10.2026")
	print(JSON.stringify(data, "  "))

	var total := 0
	print("--- summary ---")
	for d in data["days"]:
		var lessons: Array = d["lessons"]
		total += lessons.size()
		print("%s %s: %d пар" % [d["date"], d["name"], lessons.size()])
		for l in lessons:
			print("  %s-%s | %s | %s | ауд. %s | %s | %s" % [
				l["start"], l["end"], l["kind"], l["subject"],
				l["room"], l["building"], l["teacher"],
			])
	print("TOTAL LESSONS: ", total)
	quit(0)
