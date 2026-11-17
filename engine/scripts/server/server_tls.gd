class_name ServerTLS
extends RefCounted
## Self-signed TLS certificate for LAN hosting. Chrome only runs Godot web builds in a secure
## context, and a page loaded over plain http from a LAN address (not localhost) is not one. So
## the server serves the web build over https and the game port over wss, both with this
## certificate.
##
## The key is made with Godot's Crypto (RSA 2048). Godot's generate_self_signed_certificate()
## cannot add a subjectAltName, and Chrome ignores the CN and checks names only against the
## subjectAltName, so the certificate is written here by hand (X.509 v3 DER: subject CN = the LAN
## address, subjectAltName = DNS localhost + IP of every LAN address, 127.0.0.1 and ::1, plus
## serverAuth key usage) and signed with Crypto.sign(). Chrome still warns once (nobody vouches
## for a self-signed certificate: ERR_CERT_AUTHORITY_INVALID), but the names match, so a machine
## that chooses to trust the certificate gets no warning at all. If the hand-written certificate
## cannot be loaded, it falls back to Crypto's own (CN only); one Proceed still covers the page
## and the game connection, because the game connection uses the same host and port (/ws).
## Kept in user://tls/, reused on later runs and made again when the addresses change, the
## certificate is about to expire, or it is from an older version without subjectAltName.
## --tls-cert=PATH --tls-key=PATH use your own files instead.

const DIR := "user://tls"
const KEY_PATH := "user://tls/server.key"
const CERT_PATH := "user://tls/server.crt"
const META_PATH := "user://tls/server.json"
const VALID_DAYS := 820       # Apple refuses TLS certificates valid for more than 825 days
const FORMAT := 2             # 1 = CN only (Crypto), 2 = hand-written with subjectAltName

var key: CryptoKey
var cert: X509Certificate
var common_name := ""
var alt_names: Array = []      # what the subjectAltName lists (for the log)
var created := false   # true when made in this run

## Loads (or makes) the certificate for these LAN addresses (the first is the CN). Returns OK or
## an error.
func setup(lan_addresses: Array, cert_path := "", key_path := "") -> Error:
	if cert_path != "" or key_path != "":
		key = CryptoKey.new()
		cert = X509Certificate.new()
		if key.load(key_path) != OK or cert.load(cert_path) != OK:
			printerr("[tls] could not load --tls-cert=%s / --tls-key=%s" % [cert_path, key_path])
			return ERR_FILE_CANT_READ
		common_name = "(your own certificate)"
		return OK
	var lan_address: String = str(lan_addresses[0])
	common_name = lan_address
	var ips: Array = []
	for a in lan_addresses + ["127.0.0.1", "::1"]:
		if not str(a) in ips:
			ips.append(str(a))
	alt_names = ["localhost"] + ips
	var now := int(Time.get_unix_time_from_system())
	var meta := _read_meta()
	if str(meta.get("cn", "")) == lan_address and int(meta.get("expires", 0)) > now + 7 * 86400 \
			and int(meta.get("format", 1)) == FORMAT and meta.get("san", []) == alt_names \
			and FileAccess.file_exists(KEY_PATH) and FileAccess.file_exists(CERT_PATH):
		key = CryptoKey.new()
		cert = X509Certificate.new()
		if key.load(KEY_PATH) == OK and cert.load(CERT_PATH) == OK:
			return OK
	return _generate(lan_address, ips, now)

func _generate(cn: String, ips: Array, now: int) -> Error:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	var crypto := Crypto.new()
	var t0 := Time.get_ticks_msec()
	key = crypto.generate_rsa(2048)
	var nb := Time.get_datetime_string_from_unix_time(now - 86400).replace("-", "").replace(":", "").replace("T", "")
	var na := Time.get_datetime_string_from_unix_time(now + VALID_DAYS * 86400).replace("-", "").replace(":", "").replace("T", "")
	var fmt := FORMAT
	cert = _build_san_cert(crypto, key, cn, ips, now - 86400, now + VALID_DAYS * 86400)
	if cert == null:
		printerr("[tls] could not write a certificate with subjectAltName; using one with the CN only (Chrome's Proceed still covers the page and the game, which share one address)")
		fmt = 1
		cert = crypto.generate_self_signed_certificate(key, "CN=%s,O=Arena Wheels LAN server,C=US" % cn, nb, na)
	if key == null or cert == null:
		printerr("[tls] could not make a certificate")
		return FAILED
	if key.save(KEY_PATH) != OK or cert.save(CERT_PATH) != OK:
		printerr("[tls] could not save the certificate to %s" % ProjectSettings.globalize_path(DIR))
		return ERR_FILE_CANT_WRITE
	var f := FileAccess.open(META_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"cn": cn, "created": now, "expires": now + VALID_DAYS * 86400, "format": fmt, "san": alt_names if fmt == FORMAT else []}))
		f.close()
	created = true
	print("[tls] made a self-signed certificate for %s (names: %s) in %d ms (%s)" % [cn, ", ".join(alt_names) if fmt == FORMAT else "CN only", Time.get_ticks_msec() - t0, ProjectSettings.globalize_path(CERT_PATH)])
	return OK

# ---------------- hand-written X.509 v3 certificate (DER) ----------------
## Self-signed RSA/SHA-256 certificate with subjectAltName (DNS localhost + the IPs), basic
## constraints CA:FALSE, key usage digitalSignature + keyEncipherment and extended key usage
## serverAuth. Returns null when anything fails (the caller falls back to Crypto's own).
func _build_san_cert(crypto: Crypto, k: CryptoKey, cn: String, ips: Array, not_before: int, not_after: int) -> X509Certificate:
	var spki := _pem_body(k.save_to_string(true))
	if spki.is_empty():
		return null
	var serial := crypto.generate_random_bytes(16)
	serial[0] = serial[0] & 0x7f | 0x10   # positive, no leading zero byte
	var sha256_rsa := _seq([_oid([1, 2, 840, 113549, 1, 1, 11]), PackedByteArray([0x05, 0x00])])
	var name := _seq([
		_tlv(0x31, _seq([_oid([2, 5, 4, 3]), _tlv(0x0c, cn.to_utf8_buffer())])),
		_tlv(0x31, _seq([_oid([2, 5, 4, 10]), _tlv(0x0c, "Arena Wheels LAN server".to_utf8_buffer())])),
	])
	var gen_names: Array = [_tlv(0x82, "localhost".to_ascii_buffer())]
	for ip in ips:
		var raw := _ip_bytes(str(ip))
		if not raw.is_empty():
			gen_names.append(_tlv(0x87, raw))
	var exts := _seq([
		_ext([2, 5, 29, 17], false, _seq(gen_names)),
		_ext([2, 5, 29, 19], true, _seq([])),
		_ext([2, 5, 29, 15], true, PackedByteArray([0x03, 0x02, 0x05, 0xa0])),
		_ext([2, 5, 29, 37], false, _seq([_oid([1, 3, 6, 1, 5, 5, 7, 3, 1])])),
	])
	var tbs := _seq([
		_tlv(0xa0, _tlv(0x02, PackedByteArray([2]))),
		_tlv(0x02, serial),
		sha256_rsa,
		name,
		_seq([_time(not_before), _time(not_after)]),
		name,
		spki,
		_tlv(0xa3, exts),
	])
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	hc.update(tbs)
	var sig := crypto.sign(HashingContext.HASH_SHA256, hc.finish(), k)
	if sig.is_empty():
		return null
	var bits := PackedByteArray([0])
	bits.append_array(sig)
	var der := _seq([tbs, sha256_rsa, _tlv(0x03, bits)])
	var b64 := Marshalls.raw_to_base64(der)
	var pem := "-----BEGIN CERTIFICATE-----\n"
	for i in range(0, b64.length(), 64):
		pem += b64.substr(i, 64) + "\n"
	pem += "-----END CERTIFICATE-----\n"
	var c := X509Certificate.new()
	if c.load_from_string(pem) != OK:
		return null
	return c

static func _pem_body(pem: String) -> PackedByteArray:
	var b64 := ""
	for line in pem.split("\n"):
		line = line.strip_edges()
		if line != "" and not line.begins_with("-----"):
			b64 += line
	return Marshalls.base64_to_raw(b64) if b64 != "" else PackedByteArray()

static func _tlv(tag: int, body: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([tag])
	var n := body.size()
	if n < 128:
		out.append(n)
	else:
		var len_bytes := PackedByteArray()
		while n > 0:
			len_bytes.insert(0, n & 0xff)
			n >>= 8
		out.append(0x80 | len_bytes.size())
		out.append_array(len_bytes)
	out.append_array(body)
	return out

static func _seq(items: Array) -> PackedByteArray:
	var body := PackedByteArray()
	for it in items:
		body.append_array(it)
	return _tlv(0x30, body)

static func _oid(arcs: Array) -> PackedByteArray:
	var body := PackedByteArray([arcs[0] * 40 + arcs[1]])
	for i in range(2, arcs.size()):
		var v: int = arcs[i]
		var chunk := PackedByteArray([v & 0x7f])
		v >>= 7
		while v > 0:
			chunk.insert(0, (v & 0x7f) | 0x80)
			v >>= 7
		body.append_array(chunk)
	return _tlv(0x06, body)

static func _ext(arcs: Array, critical: bool, value: PackedByteArray) -> PackedByteArray:
	var parts: Array = [_oid(arcs)]
	if critical:
		parts.append(PackedByteArray([0x01, 0x01, 0xff]))
	parts.append(_tlv(0x04, value))
	return _seq(parts)

## UTCTime (YYMMDDHHMMSSZ) before 2050, GeneralizedTime after, as X.509 requires.
static func _time(unix: int) -> PackedByteArray:
	var d := Time.get_datetime_dict_from_unix_time(unix)
	var s := "%02d%02d%02d%02d%02dZ" % [d.month, d.day, d.hour, d.minute, d.second]
	if d.year < 2050:
		return _tlv(0x17, ("%02d" % (d.year % 100) + s).to_ascii_buffer())
	return _tlv(0x18, ("%04d" % d.year + s).to_ascii_buffer())

## 4 bytes for IPv4, 16 for IPv6 (with :: shorthand), empty when not an address.
static func _ip_bytes(ip: String) -> PackedByteArray:
	var out := PackedByteArray()
	if ip.count(".") == 3 and not ip.contains(":"):
		for part in ip.split("."):
			if not part.is_valid_int() or int(part) < 0 or int(part) > 255:
				return PackedByteArray()
			out.append(int(part))
		return out
	if not ip.contains(":") or ip.contains("%") or ip.contains("."):
		return PackedByteArray()
	var halves := ip.split("::")
	if halves.size() > 2:
		return PackedByteArray()
	var head: PackedStringArray = halves[0].split(":", false)
	var tail: PackedStringArray = halves[1].split(":", false) if halves.size() == 2 else PackedStringArray()
	var fill := 8 - head.size() - tail.size()
	if fill < 0 or (halves.size() == 1 and fill != 0):
		return PackedByteArray()
	var groups: Array = Array(head)
	for _i in fill:
		groups.append("0")
	groups.append_array(Array(tail))
	for g in groups:
		if not str(g).is_valid_hex_number() or str(g).length() > 4:
			return PackedByteArray()
		var v := str(g).hex_to_int()
		out.append(v >> 8)
		out.append(v & 0xff)
	return out

func _read_meta() -> Dictionary:
	if not FileAccess.file_exists(META_PATH):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(META_PATH))
	return d if typeof(d) == TYPE_DICTIONARY else {}

func server_options() -> TLSOptions:
	return TLSOptions.server(key, cert)
