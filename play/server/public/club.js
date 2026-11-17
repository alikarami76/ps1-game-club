// Club page logic. The disc and BIOS never leave this browser tab: they are read through
// File objects and object URLs, and handed to the self-hosted EmulatorJS player.
(function () {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const discInput = $("discFiles"), biosInput = $("biosFile"), gameIdInput = $("gameId");
  const startBtn = $("startBtn"), info = $("discInfo");
  const DISC_EXT = ["cue", "bin", "chd", "pbp", "iso", "img", "m3u", "zip", "7z"];
  const extOf = (n) => (n.split(".").pop() || "").toLowerCase();

  fetch("config.json").then((r) => r.json()).then((c) => {
    $("clubName").textContent = c.name;
    document.title = c.name;
  }).catch(() => {});

  if (!window.isSecureContext) {
    const n = $("secureNote");
    n.hidden = false;
    n.textContent = "This page is not using HTTPS, so your browser may block gamepads and some other features. " +
      "Open it as https:// (see the README) or from localhost on the host computer.";
  }

  function selection() {
    const files = Array.from(discInput.files || []).filter((f) => DISC_EXT.includes(extOf(f.name)));
    const cue = files.find((f) => extOf(f.name) === "cue");
    const archive = files.find((f) => ["zip", "7z"].includes(extOf(f.name)));
    const single = files.find((f) => ["chd", "pbp", "iso", "img", "m3u"].includes(extOf(f.name)));
    return { files, cue, archive, single };
  }

  function describe() {
    const s = selection();
    const mb = (n) => (n / 1048576).toFixed(0) + " MB";
    let text = "", ok = false;
    if (s.cue) {
      const bins = s.files.filter((f) => extOf(f.name) === "bin");
      text = "CUE sheet: " + s.cue.name + "\nTrack files selected: " + bins.length + " (" + mb(bins.reduce((a, f) => a + f.size, 0)) + ")";
      ok = bins.length > 0;
      if (!ok) text += "\nSelect the .bin track files together with the .cue.";
    } else if (s.archive || s.single) {
      const f = s.archive || s.single;
      text = f.name + " (" + mb(f.size) + ")";
      ok = true;
    } else if (s.files.length === 1) {
      text = s.files[0].name + " (" + mb(s.files[0].size) + ")";
      ok = true;
    } else if (s.files.length > 1) {
      text = "Several .bin files without a .cue sheet. Please also select the .cue file.";
    }
    info.textContent = text;
    startBtn.disabled = !ok;
  }
  discInput.addEventListener("change", describe);

  // 31-bit id from the disc content so friends with the same dump see the same room list.
  async function autoGameId(s) {
    const first = s.cue ? s.files.filter((f) => extOf(f.name) === "bin").sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }))[0]
      : (s.archive || s.single || s.files[0]);
    const crc = await ClubZip.crc32(first.slice(0, 2 * 1048576));
    return (crc % 2147483646) + 1;
  }

  $("pickForm").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    startBtn.disabled = true;
    const s = selection();
    try {
      info.textContent = "Reading your disc in this browser...";
      const typed = parseInt(gameIdInput.value, 10);
      const gameId = typed > 0 ? typed : await autoGameId(s);

      let gameBlob, gameName;
      if (s.cue) {
        const bins = s.files.filter((f) => extOf(f.name) === "bin");
        info.textContent = "Packing " + (bins.length + 1) + " files into one in-memory package...";
        gameBlob = await ClubZip.buildZip([s.cue].concat(bins), (p) => { info.textContent = "Packing disc in your browser: " + Math.round(p * 100) + "%"; });
        gameName = s.cue.name.replace(/\.cue$/i, "") + ".zip";
      } else {
        const f = s.archive || s.single || s.files[0];
        gameBlob = f; gameName = f.name;
      }
      const gameUrl = URL.createObjectURL(gameBlob);
      let biosUrl;
      if (biosInput.files && biosInput.files[0]) biosUrl = URL.createObjectURL(biosInput.files[0]);
      launch({ gameUrl: gameUrl, gameName: gameName.replace(/\.[^.]+$/, ""), biosUrl: biosUrl, gameId: gameId });
    } catch (e) {
      info.textContent = "Could not read the disc: " + e.message;
      startBtn.disabled = false;
    }
  });

  function launch(o) {
    $("lobby").hidden = true;
    $("stage").hidden = false;
    window.EJS_player = "#game";
    window.EJS_core = "psx";                         // PCSX-ReARMed
    window.EJS_pathtodata = "emulatorjs/";
    window.EJS_gameUrl = o.gameUrl;
    window.EJS_gameName = o.gameName;
    if (o.biosUrl) window.EJS_biosUrl = o.biosUrl;   // optional, user supplied, stays local
    window.EJS_gameID = o.gameId;
    window.EJS_netplayServer = location.origin;      // same server serves the club and the relay
    window.EJS_DEBUG_XX = true;                      // EmulatorJS 4.2.3 only enables netplay in this mode
    window.EJS_EXPERIMENTAL_NETPLAY = true;
    window.EJS_CacheLimit = 0;                       // do not keep a copy of the game in browser storage
    window.EJS_startOnLoaded = true;
    window.EJS_threads = false;
    window.__clubState = "loading";
    window.EJS_ready = function () { window.__clubState = "ready"; };
    window.EJS_onGameStart = function () { window.__clubState = "running"; };
    const s = document.createElement("script");
    s.src = "emulatorjs/loader.js";
    document.body.appendChild(s);
  }
})();
