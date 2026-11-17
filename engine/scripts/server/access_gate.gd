class_name AccessGate
extends RefCounted
## Shared-secret gate for a deployment behind a reverse proxy (--behind-proxy). The secret comes
## from the environment (TM_ACCESS_KEY), never from a command-line flag, and is never printed.
##
## GET /login?key=<secret>: compared in constant time; on success the browser gets an HttpOnly,
## Secure, SameSite=Strict cookie holding a token derived from the secret (HMAC-SHA256) and is
## redirected to /. Every other path (except /healthz) needs that cookie, otherwise 404.
## Failed logins are rate-limited per client address.

const COOKIE := "tm_session"
const MIN_KEY_LEN := 12
const MAX_FAILS := 5           # failed logins allowed per window and client
const WINDOW_MS := 300000      # 5 minutes
const MAX_CLIENTS := 2000      # bound on the table of failing clients
const COOKIE_AGE := 2592000    # 30 days

var _key := PackedByteArray()
var _token := PackedByteArray()      # hex text of HMAC(key, "tm-session-v1")
var _fails := {}                     # client -> Array of failure times (msec)

## Returns false when the key is missing or too short (the server then refuses to start).
func setup(key: String) -> bool:
	if key.length() < MIN_KEY_LEN:
		return false
	_key = key.to_utf8_buffer()
	var crypto := Crypto.new()
	_token = crypto.hmac_digest(HashingContext.HASH_SHA256, _key, "tm-session-v1".to_utf8_buffer()).hex_encode().to_ascii_buffer()
	return true

func _ct_equal(a: PackedByteArray, b: PackedByteArray) -> bool:
	# hash both first so the comparison length never depends on the secret
	var crypto := Crypto.new()
	var ha := crypto.hmac_digest(HashingContext.HASH_SHA256, _key, a)
	var hb := crypto.hmac_digest(HashingContext.HASH_SHA256, _key, b)
	return crypto.constant_time_compare(ha, hb)

func check_key(candidate: String) -> bool:
	return _ct_equal(candidate.to_utf8_buffer(), _key)

## True when the request's Cookie header carries a valid session token.
func has_session(cookie_header: String) -> bool:
	var ok := false
	for part in cookie_header.split(";"):
		var kv := part.strip_edges().split("=", true, 1)
		if kv.size() == 2 and kv[0] == COOKIE:
			if _ct_equal(kv[1].to_ascii_buffer(), _token):
				ok = true
	return ok

func set_cookie_header() -> String:
	return "Set-Cookie: %s=%s; Path=/; Max-Age=%d; HttpOnly; Secure; SameSite=Strict\r\n" % [COOKIE, _token.get_string_from_ascii(), COOKIE_AGE]

func is_limited(client: String) -> bool:
	var now := Time.get_ticks_msec()
	var l: Array = _fails.get(client, [])
	l = l.filter(func(t): return now - t < WINDOW_MS)
	if l.is_empty():
		_fails.erase(client)
	else:
		_fails[client] = l
	return l.size() >= MAX_FAILS

func record_fail(client: String) -> void:
	if _fails.size() >= MAX_CLIENTS and not _fails.has(client):
		# table full: drop the oldest client (an attacker cannot lock others out of it for long)
		_fails.erase(_fails.keys()[0])
	var l: Array = _fails.get(client, [])
	l.append(Time.get_ticks_msec())
	_fails[client] = l
