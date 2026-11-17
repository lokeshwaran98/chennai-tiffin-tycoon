extends Node
## Rewarded-ad wrapper. In the greybox build the ad is simulated so the whole
## reward flow can be tested without an AdMob account. The real AdMob plugin
## replaces _show_real_ad() once the AdMob app/unit IDs are available.

signal reward_granted(kind: String)

const USE_TEST_ADS := true
var _pending_kind := ""

func show_rewarded(kind: String) -> void:
	_pending_kind = kind
	if USE_TEST_ADS:
		# Simulated 1.5s ad.
		await get_tree().create_timer(1.5).timeout
		_grant()
	else:
		_show_real_ad()

func _show_real_ad() -> void:
	# TODO: call the AdMob plugin here with the rewarded ad unit ID.
	_grant()

func _grant() -> void:
	reward_granted.emit(_pending_kind)
	_pending_kind = ""
