extends Control
## Schedule UI: week navigation, day tabs, lesson cards, login overlay,
## and an on-screen debug log.

var week_offset := 0
var current_data: Dictionary = {}
var selected_day := 0
var busy := false

var status_label: Label
var week_label: Label
var tabs: HBoxContainer
var list: VBoxContainer
var refresh_btn: Button
var login_btn: Button
var log_btn: Button
var prev_btn: Button
var next_btn: Button

var debug_panel: PanelContainer
var debug_text: TextEdit

var login_overlay: Control
var login_field: LineEdit
var pass_field: LineEdit
var login_error: Label

func _ready() -> void:
	_build_ui()
	Store.debug_line.connect(_on_debug_line)
	Session.status.connect(_on_status)
	Session.auth_changed.connect(_on_auth_changed)
	_load_initial()

# ---------------------------------------------------------------------- UI

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color("101418")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	# Header
	var header := HBoxContainer.new()
	root.add_child(header)
	var title := Label.new()
	title.text = "Расписание"
	title.add_theme_font_size_override("font_size", 26)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	status_label = Label.new()
	status_label.text = ""
	status_label.add_theme_font_size_override("font_size", 14)
	status_label.add_theme_color_override("font_color", Color("8fa3b0"))
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(status_label)

	# Week navigation
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 8)
	root.add_child(nav)
	prev_btn = _nav_button("‹")
	prev_btn.pressed.connect(func(): _change_week(-1))
	nav.add_child(prev_btn)
	week_label = Label.new()
	week_label.add_theme_font_size_override("font_size", 18)
	week_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	week_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	week_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav.add_child(week_label)
	next_btn = _nav_button("›")
	next_btn.pressed.connect(func(): _change_week(1))
	nav.add_child(next_btn)

	# Actions
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	root.add_child(actions)
	refresh_btn = _action_button("Обновить")
	refresh_btn.pressed.connect(_refresh)
	actions.add_child(refresh_btn)
	login_btn = _action_button("Логин")
	login_btn.pressed.connect(_open_login)
	actions.add_child(login_btn)
	log_btn = _action_button("Лог")
	log_btn.pressed.connect(_toggle_debug)
	actions.add_child(log_btn)

	# Day tabs
	tabs = HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	root.add_child(tabs)

	# Lesson list
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	list = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 10)
	scroll.add_child(list)

	_build_debug_panel()
	_build_login_overlay()

func _nav_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(56, 44)
	b.add_theme_font_size_override("font_size", 24)
	return b

func _action_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 44)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return b

func _build_debug_panel() -> void:
	debug_panel = PanelContainer.new()
	debug_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	debug_panel.offset_top = -320
	debug_panel.offset_left = 8
	debug_panel.offset_right = -8
	debug_panel.offset_bottom = -8
	debug_panel.visible = false
	add_child(debug_panel)

	var box := VBoxContainer.new()
	debug_panel.add_child(box)
	var bar := HBoxContainer.new()
	box.add_child(bar)
	var lbl := Label.new()
	lbl.text = "Отладочный лог"
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(lbl)
	var clear := Button.new()
	clear.text = "Очистить"
	clear.pressed.connect(func(): Store.clear_debug(); debug_text.text = "")
	bar.add_child(clear)
	var close := Button.new()
	close.text = "Закрыть"
	close.pressed.connect(func(): debug_panel.visible = false)
	bar.add_child(close)
	debug_text = TextEdit.new()
	debug_text.editable = false
	debug_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	debug_text.add_theme_font_size_override("font_size", 12)
	box.add_child(debug_text)

func _build_login_overlay() -> void:
	login_overlay = Control.new()
	login_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	login_overlay.visible = false
	add_child(login_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	login_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	login_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(340, 0)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var t := Label.new()
	t.text = "Вход в ИДИС"
	t.add_theme_font_size_override("font_size", 20)
	box.add_child(t)

	login_field = LineEdit.new()
	login_field.placeholder_text = "Логин"
	box.add_child(login_field)

	pass_field = LineEdit.new()
	pass_field.placeholder_text = "Пароль"
	pass_field.secret = true
	box.add_child(pass_field)

	login_error = Label.new()
	login_error.add_theme_color_override("font_color", Color("ff7b72"))
	login_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(login_error)

	var hint := Label.new()
	hint.text = "Данные сохраняются только на этом устройстве."
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color("8fa3b0"))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hint)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var cancel := Button.new()
	cancel.text = "Отмена"
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.pressed.connect(_close_login)
	row.add_child(cancel)
	var ok := Button.new()
	ok.text = "Войти"
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ok.pressed.connect(_submit_login)
	row.add_child(ok)

	pass_field.text_submitted.connect(func(_t): _submit_login())

# ------------------------------------------------------------------- actions

func _load_initial() -> void:
	if Store.has_schedule():
		current_data = Store.load_schedule()
	elif not Store.has_credentials():
		current_data = ScheduleSeed.sample()
	_render()
	if Store.has_credentials():
		_refresh()
	else:
		status_label.text = "Войдите, чтобы загрузить расписание"

func _change_week(delta: int) -> void:
	if busy:
		return
	week_offset += delta
	_render()
	_refresh()

func _refresh() -> void:
	if busy:
		return
	busy = true
	_set_busy(true)
	var wk := ScheduleParser.week_range(week_offset)
	var res: Dictionary = await Session.get_week(wk["begin"], wk["end"])
	busy = false
	_set_busy(false)
	if String(res.get("error", "")) != "":
		status_label.text = String(res["error"])
		_maybe_prompt_login(String(res["error"]))
		return
	current_data = res["data"]
	selected_day = 0
	Store.save_schedule(current_data)
	_render()

func _maybe_prompt_login(err: String) -> void:
	if err == "Нужно войти" or err == "Не удалось авторизоваться" or err == "Неверный логин или пароль":
		_open_login()

func _set_busy(on: bool) -> void:
	refresh_btn.disabled = on
	prev_btn.disabled = on
	next_btn.disabled = on
	status_label.text = "Загрузка…" if on else status_label.text

func _open_login() -> void:
	var creds := Store.load_credentials()
	login_field.text = String(creds.get("login", ""))
	pass_field.text = ""
	login_error.text = ""
	login_overlay.visible = true
	if login_field.text == "":
		login_field.grab_focus()
	else:
		pass_field.grab_focus()

func _close_login() -> void:
	pass_field.text = ""
	login_overlay.visible = false

func _submit_login() -> void:
	var l := login_field.text.strip_edges()
	var p := pass_field.text
	if l == "" or p == "":
		login_error.text = "Заполните логин и пароль"
		return
	login_error.text = ""
	login_overlay.visible = false
	status_label.text = "Вход…"
	Store.save_credentials(l, p)
	var ok: bool = await Session.login(l, p)
	pass_field.text = ""
	if ok:
		_refresh()
	else:
		status_label.text = Session.last_error
		_open_login()
		login_error.text = Session.last_error

# ------------------------------------------------------------------ rendering

func _render() -> void:
	week_label.text = ScheduleParser.week_range(week_offset)["label"]
	_build_tabs()
	_render_day()

func _build_tabs() -> void:
	for c in tabs.get_children():
		c.queue_free()
	var days: Array = current_data.get("days", [])
	if days.is_empty():
		return
	if selected_day >= days.size():
		selected_day = 0
	for i in days.size():
		var d: Dictionary = days[i]
		var b := Button.new()
		var name := String(d.get("name", ""))
		var date_iso := String(d.get("date", ""))
		if date_iso.length() >= 10:
			b.text = "%s\n%s" % [name, date_iso.substr(8, 2) + "." + date_iso.substr(5, 2)]
		else:
			b.text = name
		b.add_theme_font_size_override("font_size", 13)
		b.custom_minimum_size = Vector2(0, 48)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.toggle_mode = true
		b.button_pressed = (i == selected_day)
		var idx := i
		b.pressed.connect(func(): _select_day(idx))
		tabs.add_child(b)

func _select_day(idx: int) -> void:
	selected_day = idx
	_build_tabs()
	_render_day()

func _render_day() -> void:
	for c in list.get_children():
		c.queue_free()
	var days: Array = current_data.get("days", [])
	if days.is_empty():
		list.add_child(_empty_label("Нет данных за эту неделю"))
		return
	var day: Dictionary = days[clamp(selected_day, 0, days.size() - 1)]
	var lessons: Array = day.get("lessons", [])
	if lessons.is_empty():
		list.add_child(_empty_label("В этот день занятий нет"))
		return
	for lesson in lessons:
		list.add_child(_lesson_card(lesson))

func _empty_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Color("8fa3b0"))
	l.add_theme_font_size_override("font_size", 16)
	l.custom_minimum_size = Vector2(0, 120)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l

func _lesson_card(lesson: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("1b232b")
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	card.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	card.add_child(box)

	var top := HBoxContainer.new()
	box.add_child(top)
	var time := Label.new()
	time.text = "%s – %s" % [lesson.get("start", ""), lesson.get("end", "")]
	time.add_theme_font_size_override("font_size", 15)
	time.add_theme_color_override("font_color", Color("7cc7ff"))
	time.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(time)
	var kind := Label.new()
	kind.text = String(lesson.get("kind", ""))
	kind.add_theme_font_size_override("font_size", 13)
	kind.add_theme_color_override("font_color", Color("b0bec5"))
	top.add_child(kind)

	var subject := Label.new()
	subject.text = String(lesson.get("subject", ""))
	subject.add_theme_font_size_override("font_size", 17)
	subject.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(subject)

	var where := "%s%s" % [
		String(lesson.get("room", "")),
		(" · " + String(lesson.get("building", ""))) if String(lesson.get("building", "")) != "" else "",
	]
	if where.strip_edges() != "·":
		var loc := Label.new()
		loc.text = where.strip_edges()
		loc.add_theme_font_size_override("font_size", 14)
		loc.add_theme_color_override("font_color", Color("8fa3b0"))
		box.add_child(loc)

	var teacher := String(lesson.get("teacher", ""))
	if teacher != "":
		var tl := Label.new()
		tl.text = teacher
		tl.add_theme_font_size_override("font_size", 14)
		tl.add_theme_color_override("font_color", Color("c5d0d8"))
		box.add_child(tl)

	return card

# -------------------------------------------------------------------- signals

func _on_status(text: String) -> void:
	status_label.text = text

func _on_auth_changed(ok: bool) -> void:
	login_btn.text = "Войти заново" if ok else "Логин"

func _on_debug_line(line: String) -> void:
	if debug_text == null:
		return
	if debug_text.text.length() > 20000:
		debug_text.text = debug_text.text.right(10000)
	debug_text.text += line + "\n"

func _toggle_debug() -> void:
	debug_panel.visible = not debug_panel.visible
	if debug_panel.visible:
		debug_text.text = Store.debug_text() + "\n"
		debug_text.scroll_vertical = debug_text.get_line_count()
