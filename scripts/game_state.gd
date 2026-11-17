extends Node
## Economy, save/load and offline earnings.
## Difficulty curve: costs grow faster than income, so the early game is
## nearly instant and later upgrades take longer (rewarded ads speed this up).

const SAVE_PATH := "user://save.json"
const OFFLINE_CAP_SECONDS := 8 * 3600
const BOOST_SECONDS := 30 * 60

signal changed

# name, base_cost, base_income_per_sec, cost_growth
const STALLS := [
	{"name": "Filter Coffee Cart", "cost": 15.0, "income": 1.0, "growth": 1.07},
	{"name": "Idli & Dosa Stall", "cost": 150.0, "income": 8.0, "growth": 1.09},
	{"name": "Pongal & Vada Counter", "cost": 1500.0, "income": 55.0, "growth": 1.10},
	{"name": "Sundal Beach Cart", "cost": 15000.0, "income": 380.0, "growth": 1.11},
	{"name": "Biryani Stall", "cost": 150000.0, "income": 2600.0, "growth": 1.12},
	{"name": "Kothu Parotta Joint", "cost": 1.5e6, "income": 18000.0, "growth": 1.13},
]

var coins: float = 0.0
var levels: Array = [0, 0, 0, 0, 0, 0]
var tap_level: int = 1
var boost_until: int = 0      # unix time, 2x income while active
var last_seen: int = 0

func _ready() -> void:
	load_game()
	var offline := _offline_earnings()
	if offline > 0.0:
		coins += offline
		offline_gain = offline
	last_seen = int(Time.get_unix_time_from_system())
	AdService.reward_granted.connect(_on_reward)

var offline_gain: float = 0.0

func multiplier() -> float:
	return 2.0 if int(Time.get_unix_time_from_system()) < boost_until else 1.0

func income_per_sec() -> float:
	var total := 0.0
	for i in STALLS.size():
		total += STALLS[i].income * levels[i]
	return total * multiplier()

func tap_value() -> float:
	return float(tap_level) * multiplier()

func upgrade_cost(i: int) -> float:
	return STALLS[i].cost * pow(STALLS[i].growth, levels[i])

func tap_cost() -> float:
	return 10.0 * pow(1.15, tap_level - 1)

func buy_stall(i: int) -> bool:
	var c := upgrade_cost(i)
	if coins < c:
		return false
	coins -= c
	levels[i] += 1
	changed.emit()
	return true

func buy_tap() -> bool:
	var c := tap_cost()
	if coins < c:
		return false
	coins -= c
	tap_level += 1
	changed.emit()
	return true

func tap() -> void:
	coins += tap_value()
	changed.emit()

func _process(delta: float) -> void:
	coins += income_per_sec() * delta

func _offline_earnings() -> float:
	if last_seen <= 0:
		return 0.0
	var away := clampi(int(Time.get_unix_time_from_system()) - last_seen, 0, OFFLINE_CAP_SECONDS)
	# Base rate without the boost; offline reward is optionally doubled via ad.
	var base := 0.0
	for i in STALLS.size():
		base += STALLS[i].income * levels[i]
	return base * away * 0.5

func double_offline() -> void:
	coins += offline_gain
	offline_gain = 0.0
	changed.emit()

func _on_reward(kind: String) -> void:
	match kind:
		"boost":
			boost_until = int(Time.get_unix_time_from_system()) + BOOST_SECONDS
		"offline":
			double_offline()
		"chest":
			coins += maxf(50.0, income_per_sec() * 120.0)
	changed.emit()
	save_game()

func format_num(v: float) -> String:
	var suffix := ["", "K", "M", "B", "T", "Qa", "Qi"]
	var idx := 0
	while v >= 1000.0 and idx < suffix.size() - 1:
		v /= 1000.0
		idx += 1
	return ("%.0f" % v if idx == 0 else "%.2f%s" % [v, suffix[idx]])

func save_game() -> void:
	last_seen = int(Time.get_unix_time_from_system())
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({
			"coins": coins, "levels": levels, "tap_level": tap_level,
			"boost_until": boost_until, "last_seen": last_seen}))

func load_game() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if not f:
		return
	var data = JSON.parse_string(f.get_as_text())
	if typeof(data) != TYPE_DICTIONARY:
		return
	coins = float(data.get("coins", 0.0))
	tap_level = int(data.get("tap_level", 1))
	boost_until = int(data.get("boost_until", 0))
	last_seen = int(data.get("last_seen", 0))
	var lv = data.get("levels", [])
	for i in mini(lv.size(), levels.size()):
		levels[i] = int(lv[i])

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_game()
