extends Node
## Procedural sound: effects and a gentle looping tune are synthesized at
## startup, so there are no audio files to license or download.

const RATE := 22050
const MUSIC_RATE := 11025

var enabled: bool = true
var _streams: Dictionary = {}
var _players: Array = []
var _music: AudioStreamPlayer

func _ready() -> void:
	_streams["tap"] = _make([[740.0, 0.06]], 0.5, RATE, 7.0, false)
	_streams["buy"] = _make([[523.0, 0.07], [784.0, 0.12]], 0.5, RATE, 6.0, false)
	_streams["reward"] = _make([[523.0, 0.08], [659.0, 0.08], [784.0, 0.08], [1047.0, 0.22]], 0.5, RATE, 5.0, false)
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	_music = AudioStreamPlayer.new()
	_music.stream = _make([
		[261.6, 0.5], [329.6, 0.5], [392.0, 0.5], [440.0, 0.5],
		[392.0, 0.5], [329.6, 0.5], [293.7, 0.5], [329.6, 0.5]], 0.3, MUSIC_RATE, 2.5, true)
	_music.volume_db = -12.0
	add_child(_music)
	_apply()

func set_enabled(on: bool) -> void:
	enabled = on
	_apply()

func _apply() -> void:
	if enabled:
		if not _music.playing:
			_music.play()
	else:
		_music.stop()

func play(sfx_name: String) -> void:
	if not enabled or not _streams.has(sfx_name):
		return
	for p in _players:
		if not p.playing:
			p.stream = _streams[sfx_name]
			p.play()
			return

func _make(notes: Array, vol: float, rate: int, decay: float, loop: bool) -> AudioStreamWAV:
	var data := PackedByteArray()
	for n in notes:
		var f: float = n[0]
		var d: float = n[1]
		var count := int(rate * d)
		var start := data.size()
		data.resize(start + count * 2)
		for i in count:
			var t := float(i) / rate
			var env := exp(-decay * t / d) * minf(1.0, float(i) / 40.0)
			var v := sin(TAU * f * t) * 0.7 + sin(TAU * f * 2.0 * t) * 0.2
			data.encode_s16(start + i * 2, int(clampf(v * env * vol, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = data.size() / 2
	return w
