extends Node
## Economy, prestige, daily rewards, save/load and offline earnings.
## Difficulty curve: costs grow faster than income, so the early game is
## nearly instant and later upgrades take longer. Every 25 levels of a stall
## doubles that stall's income (milestones), and prestige gives permanent bonus.

const SAVE_PATH := "user://save.json"
const OFFLINE_CAP_SECONDS := 8 * 3600
const BOOST_SECONDS := 30 * 60
const DAY_SECONDS := 86400
const MILESTONE_LEVELS := 25
const PRESTIGE_DIVISOR := 1.0e6
const PRESTIGE_BONUS_EACH := 0.10

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
var run_earned: float = 0.0     # earned since last prestige
var levels: Array = [0, 0, 0, 0, 0, 0]
var tap_level: int = 1
var prestige_points: int = 0
var boost_until: int = 0        # unix time, 2x income while active
var last_seen: int = 0
var last_daily: int = 0
var offline_gain: float = 0.0

func _ready() -> void:
	load_game()
	if OS.get_cmdline_user_args().has("--smoke") or OS.get_cmdline_user_args().has("--shot"):
		# CI-only seed so customers, milestones, offline popup and prestige run.
		coins = 5.0e7
		run_earned = 9.0e6
		levels = [30, 12, 8, 5, 3, 1]
		last_seen = now() - 7200
	var offline := _offline_earnings()
	if offline > 0.0:
		add_coins(offline)
		offline_gain = offline
	last_seen = int(Time.get_unix_time_from_system())
	AdService.reward_granted.connect(_on_reward)

func add_coins(v: float) -> void:
	coins += v
	run_earned += v

func now() -> int:
	return int(Time.get_unix_time_from_system())

func boost_multiplier() -> float:
	return 2.0 if now() < boost_until else 1.0

func prestige_multiplier() -> float:
	return 1.0 + PRESTIGE_BONUS_EACH * prestige_points

func milestone_multiplier(level: int) -> float:
	return pow(2.0, floorf(float(level) / MILESTONE_LEVELS))

func base_income() -> float:
	var total := 0.0
	for i in STALLS.size():
		total += STALLS[i].income * levels[i] * milestone_multiplier(levels[i])
	return total * prestige_multiplier()

func income_per_sec() -> float:
	return base_income() * boost_multiplier()

func tap_value() -> float:
	return float(tap_level) * boost_multiplier() * prestige_multiplier()

func total_levels() -> int:
	var t := 0
	for l in levels:
		t += int(l)
	return t

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
	add_coins(tap_value())
	changed.emit()

func _process(delta: float) -> void:
	add_coins(income_per_sec() * delta)

# ---- prestige ("open a new branch") ----
func prestige_gain() -> int:
	return int(floor(sqrt(run_earned / PRESTIGE_DIVISOR)))

func prestige() -> void:
	var g := prestige_gain()
	if g <= 0:
		return
	prestige_points += g
	coins = 15.0
	run_earned = 0.0
	tap_level = 1
	for i in levels.size():
		levels[i] = 0
	changed.emit()
	save_game()

# ---- daily reward ----
func daily_ready() -> bool:
	return now() - last_daily >= DAY_SECONDS

func daily_seconds_left() -> int:
	return maxi(0, DAY_SECONDS - (now() - last_daily))

func daily_amount() -> float:
	return maxf(100.0, income_per_sec() * 600.0)

func claim_daily(mult: float) -> void:
	if not daily_ready():
		return
	add_coins(daily_amount() * mult)
	last_daily = now()
	changed.emit()
	save_game()

# ---- offline ----
func _offline_earnings() -> float:
	if last_seen <= 0:
		return 0.0
	var away := clampi(now() - last_seen, 0, OFFLINE_CAP_SECONDS)
	return base_income() * away * 0.5

func double_offline() -> void:
	add_coins(offline_gain)
	offline_gain = 0.0
	changed.emit()

func _on_reward(kind: String) -> void:
	match kind:
		"boost":
			boost_until = now() + BOOST_SECONDS
		"offline":
			double_offline()
		"chest":
			add_coins(maxf(50.0, income_per_sec() * 120.0))
		"daily3":
			claim_daily(3.0)
	changed.emit()
	save_game()

func format_num(v: float) -> String:
	var suffix := ["", "K", "M", "B", "T", "Qa", "Qi"]
	var idx := 0
	while v >= 1000.0 and idx < suffix.size() - 1:
		v /= 1000.0
		idx += 1
	return ("%.0f" % v if idx == 0 else "%.2f%s" % [v, suffix[idx]])

# ---- save / load ----
func save_game() -> void:
	last_seen = now()
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({
			"coins": coins, "run_earned": run_earned, "levels": levels,
			"tap_level": tap_level, "prestige_points": prestige_points,
			"boost_until": boost_until, "last_seen": last_seen,
			"last_daily": last_daily}))

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
	run_earned = float(data.get("run_earned", 0.0))
	tap_level = int(data.get("tap_level", 1))
	prestige_points = int(data.get("prestige_points", 0))
	boost_until = int(data.get("boost_until", 0))
	last_seen = int(data.get("last_seen", 0))
	last_daily = int(data.get("last_daily", 0))
	var lv = data.get("levels", [])
	for i in mini(lv.size(), levels.size()):
		levels[i] = int(lv[i])

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_game()
