extends Node
## Rewarded-ad wrapper.
## On Android it uses the Poing AdMob plugin (Google test ad units until real
## IDs are filled in below). Everywhere else (desktop, CI) the ad is simulated
## so the reward flow can be tested without an AdMob account.

signal reward_granted(kind: String)
signal ad_unavailable

# Google's official test rewarded ad unit. Replace ANDROID_REWARDED_REAL_ID with
# your AdMob rewarded ad unit ID (it contains a "/") before publishing, and set
# USE_TEST_ADS to false.
const USE_TEST_ADS := true
const ANDROID_REWARDED_TEST_ID := "ca-app-pub-3940256099942544/5224354917"
const ANDROID_REWARDED_REAL_ID := ""

var _pending_kind := ""
var _real := false
var _loading := false
var _ad = null                    # RewardedAd once loaded
var _reward_listener = null       # OnUserEarnedRewardListener
var _fullscreen_callback = null   # FullScreenContentCallback

func _ready() -> void:
	_real = OS.get_name() == "Android"
	if not _real:
		return
	MobileAds.initialize()

	var listener := OnUserEarnedRewardListener.new()
	listener.on_user_earned_reward = func(_item: RewardedItem) -> void:
		_deliver()
	_reward_listener = listener

	var cb := FullScreenContentCallback.new()
	cb.on_ad_dismissed_full_screen_content = func() -> void:
		_release()
		_load()
	cb.on_ad_failed_to_show_full_screen_content = func(_error: AdError) -> void:
		_pending_kind = ""
		_release()
		_load()
		ad_unavailable.emit()
	_fullscreen_callback = cb
	_load()

func _unit_id() -> String:
	if USE_TEST_ADS or ANDROID_REWARDED_REAL_ID == "":
		return ANDROID_REWARDED_TEST_ID
	return ANDROID_REWARDED_REAL_ID

func _load() -> void:
	if _loading or _ad != null:
		return
	_loading = true
	var load_cb := RewardedAdLoadCallback.new()
	load_cb.on_ad_loaded = func(ad: RewardedAd) -> void:
		_loading = false
		_ad = ad
		_ad.full_screen_content_callback = _fullscreen_callback
	load_cb.on_ad_failed_to_load = func(_error: LoadAdError) -> void:
		_loading = false
	RewardedAdLoader.new().load(_unit_id(), AdRequest.new(), load_cb)

func _release() -> void:
	if _ad != null:
		_ad.destroy()
		_ad = null

func show_rewarded(kind: String) -> void:
	_pending_kind = kind
	if not _real:
		await get_tree().create_timer(1.5).timeout
		_deliver()
		return
	if _ad != null:
		_ad.show(_reward_listener)
	else:
		_pending_kind = ""
		ad_unavailable.emit()
		_load()

func _deliver() -> void:
	if _pending_kind == "":
		return
	var kind := _pending_kind
	_pending_kind = ""
	reward_granted.emit(kind)
