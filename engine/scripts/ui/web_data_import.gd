class_name WebDataImport
extends Node
## Web only: lets the player pick their own game-data folder in Chrome, reads manifest.json and
## every file it lists, and copies them into user://gamedata (IndexedDB) so GameData.read_bytes
## works exactly like on desktop. Nothing is uploaded anywhere; the files stay in this browser.
##
## Uses showDirectoryPicker() when the page is a secure context (https or localhost); on a plain
## http LAN address Chrome hides that API, so it falls back to <input type=file webkitdirectory>.
##
## start_url(base): the same copy, but the files come from the server's /local-gamedata/ (only
## offered to a browser on the server machine itself), with no picker and no user gesture.

signal progress(text: String, fraction: float)
signal finished(ok: bool, text: String)

const CHUNK := 1 << 20

const JS := """
(function(){
  if (window.awImp) return;
  const S = window.awImp = {state:'idle', err:'', files:null, dir:null, base:null, manifest:'', cur:null, curState:'', buf:null};
  async function getFile(rel){
    if (S.base) {
      const r = await fetch(S.base + rel.split('/').map(encodeURIComponent).join('/'), {cache:'no-store'});
      return r.ok ? r : null;
    }
    if (S.files) return S.files[rel] || null;
    let d = S.dir; const parts = rel.split('/');
    for (let i = 0; i < parts.length - 1; i++) { d = await d.getDirectoryHandle(parts[i]); }
    const h = await d.getFileHandle(parts[parts.length - 1]); return await h.getFile();
  }
  async function afterPick(){
    try {
      const f = await getFile('manifest.json');
      if (!f) { S.state = 'error'; S.err = 'manifest.json not found in that folder'; return; }
      S.manifest = await f.text(); S.state = 'picked';
    } catch(e) { S.state = 'error'; S.err = 'manifest.json not found in that folder'; }
  }
  function useInput(){
    const inp = document.createElement('input');
    inp.type = 'file'; inp.webkitdirectory = true; inp.multiple = true; inp.style.display = 'none';
    inp.onchange = function(){
      S.files = {};
      for (const f of inp.files) { const p = f.webkitRelativePath.split('/'); p.shift(); S.files[p.join('/')] = f; }
      afterPick();
    };
    inp.oncancel = function(){ S.state = 'cancelled'; };
    document.body.appendChild(inp); inp.click();
  }
  S.fromUrl = function(base){
    S.state = 'picking'; S.err = ''; S.files = null; S.dir = null; S.base = base; afterPick();
  };
  S.pick = function(){
    S.state = 'picking'; S.err = ''; S.files = null; S.dir = null; S.base = null;
    if (window.showDirectoryPicker && window.isSecureContext) {
      window.showDirectoryPicker({mode:'read'}).then(function(d){ S.dir = d; afterPick(); })
        .catch(function(e){ if (e && e.name === 'AbortError') S.state = 'cancelled'; else useInput(); });
    } else { useInput(); }
  };
  S.load = function(rel){
    S.cur = rel; S.curState = 'loading'; S.buf = null;
    getFile(rel).then(function(f){
      if (!f) { S.curState = 'missing'; return; }
      return f.arrayBuffer().then(function(ab){ S.buf = new Uint8Array(ab); S.curState = 'ready'; });
    }).catch(function(){ S.curState = 'missing'; });
  };
  S.size = function(){ return S.buf ? S.buf.length : 0; };
  S.chunk = function(off, len){ return S.buf.subarray(off, Math.min(off + len, S.buf.length)); };
  S.chunk64 = function(off, len){
    const b = S.chunk(off, len); let s = '';
    for (let i = 0; i < b.length; i += 32768) s += String.fromCharCode.apply(null, b.subarray(i, i + 32768));
    return btoa(s);
  };
})();
"""

var skip_music := false
var _list: PackedStringArray = []
var _idx := 0
var _phase := "idle"   # idle, picking, loading, done
var _music := {}
var _copied := 0
var _missing: Array = []
var _use_b64 := false

static func available() -> bool:
	return OS.has_feature("web")

func _js(code: String):
	return JavaScriptBridge.eval(code, true)

## Must be called from a button press (the browser needs a user gesture to open the picker).
func start() -> void:
	if not available():
		finished.emit(false, "Folder picking in the browser is only used in the web version.")
		return
	_js(JS)
	_js("window.awImp.pick()")
	_phase = "picking"
	progress.emit("Choose the folder that holds manifest.json...", 0.0)

## No picker: copy from the server's loopback-only /local-gamedata/ (see WebFileServer).
func start_url(base: String) -> void:
	if not available():
		finished.emit(false, "Only used in the web version.")
		return
	_js(JS)
	_js("window.awImp.fromUrl(%s)" % JSON.stringify(base))
	_phase = "picking"
	progress.emit("Loading game data from this computer's server...", 0.0)

func _process(_d: float) -> void:
	match _phase:
		"picking":
			var st := str(_js("window.awImp.state"))
			if st == "picked":
				_begin_copy(str(_js("window.awImp.manifest")))
			elif st == "cancelled":
				_phase = "idle"
				finished.emit(false, "No folder chosen.")
			elif st == "error":
				_phase = "idle"
				finished.emit(false, str(_js("window.awImp.err")))
		"loading":
			_step()

func _begin_copy(manifest_text: String) -> void:
	var m = JSON.parse_string(manifest_text)
	if typeof(m) != TYPE_DICTIONARY:
		_phase = "idle"
		finished.emit(false, "manifest.json could not be read.")
		return
	DirAccess.make_dir_recursive_absolute(GameData.WEB_ROOT)
	var f := FileAccess.open(GameData.WEB_ROOT.path_join("manifest.json"), FileAccess.WRITE)
	f.store_string(manifest_text)
	f.close()
	for rel in m.get("audio", {}).get("music", []):
		_music[str(rel)] = true
	_list = GameData.listed_files(m)
	_idx = -1
	_copied = 0
	_missing.clear()
	_phase = "loading"
	_next_file()

func _next_file() -> void:
	_idx += 1
	while _idx < _list.size() and skip_music and _music.has(_list[_idx]):
		_idx += 1
	if _idx >= _list.size():
		_phase = "done"
		GameData.reset_cache()
		var msg := "Copied %d files into this browser." % _copied
		if not _missing.is_empty():
			msg += " %d listed files were not in the folder." % _missing.size()
		finished.emit(true, msg)
		return
	_js("window.awImp.load(%s)" % JSON.stringify(_list[_idx]))
	progress.emit("Copying %s" % _list[_idx], float(_idx) / maxf(_list.size(), 1))

func _step() -> void:
	var st := str(_js("window.awImp.curState"))
	if st == "loading":
		return
	var rel := _list[_idx]
	if st == "missing":
		_missing.append(rel)
		_next_file()
		return
	var size := int(_js("window.awImp.size()"))
	var out := GameData.WEB_ROOT.path_join(rel)
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		_missing.append(rel)
		_next_file()
		return
	var off := 0
	while off < size:
		var part = null
		if not _use_b64:
			part = _js("window.awImp.chunk(%d, %d)" % [off, CHUNK])
			if typeof(part) != TYPE_PACKED_BYTE_ARRAY:
				_use_b64 = true
		if _use_b64:
			part = Marshalls.base64_to_raw(str(_js("window.awImp.chunk64(%d, %d)" % [off, CHUNK])))
		f.store_buffer(part)
		off += (part as PackedByteArray).size()
		if (part as PackedByteArray).is_empty():
			break
	f.close()
	_copied += 1
	_js("window.awImp.buf = null")
	_next_file()
