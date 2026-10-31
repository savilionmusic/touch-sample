// Touch Sample: sound buffer selector injected into the stock panel page by touch_server.py.
// The stock page (vendor, unedited) builds its AudioWorklet from an inline string and creates
// `new AudioContext({latencyHint: 0})`. This script runs first and, only when the user picked a
// non-stock value, rewrites that worklet string's target numbers and the latencyHint on the way
// through. Settings live in localStorage; a change reloads the page (the worklet is built once).
(function () {
  "use strict";
  var KEY_FRAMES = "tsBufferFrames", KEY_HINT = "tsLatencyHint";
  var FRAMES = ["auto", "256", "384", "512", "1024"];
  var HINTS = { stock: 0, balanced: "balanced", safe: "playback" };

  // Returns the worklet source with its queue target floor set to `floor` frames, or null if the
  // stock source does not look as expected (then it is left untouched).
  function rewriteWorklet(src, floor) {
    if (!(floor >= 32)) return null;
    var steps = [
      ["this.target = 320; this.ema = 320;", "this.target = " + floor + "; this.ema = " + floor + ";"],
      ["this.target > 320", "this.target > " + floor],
      ["Math.max(320, this.target - 32)", "Math.max(" + floor + ", this.target - 32)"],
      ["Math.min(1536, this.target + 128)", "Math.min(Math.max(1536, " + floor * 2 + "), this.target + 128)"]
    ];
    var out = src;
    for (var i = 0; i < steps.length; i++) {
      if (out.indexOf(steps[i][0]) < 0) return null;
      out = out.split(steps[i][0]).join(steps[i][1]);
    }
    return out;
  }
  function get(k, d) { try { return localStorage.getItem(k) || d; } catch (e) { return d; } }
  function set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }

  var api = { rewriteWorklet: rewriteWorklet, FRAMES: FRAMES, HINTS: HINTS };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (typeof window === "undefined" || typeof document === "undefined") return;

  var frames = get(KEY_FRAMES, "auto"), hint = get(KEY_HINT, "stock");
  if (FRAMES.indexOf(frames) < 0) frames = "auto";
  if (!(hint in HINTS)) hint = "stock";

  var NativeBlob = window.Blob;
  if (frames !== "auto") {
    window.Blob = function (parts, opts) {
      if (parts && typeof parts[0] === "string" && parts[0].indexOf("class Player extends AudioWorkletProcessor") >= 0) {
        var r = rewriteWorklet(parts[0], +frames);
        if (r) parts = [r].concat(Array.prototype.slice.call(parts, 1));
      }
      return new NativeBlob(parts, opts);
    };
    window.Blob.prototype = NativeBlob.prototype;
  }
  if (hint !== "stock" && window.AudioContext) {
    var NativeAC = window.AudioContext;
    window.AudioContext = new Proxy(NativeAC, { construct: function (T, args) {
      var o = Object.assign({}, args[0] || {}); o.latencyHint = HINTS[hint];
      return new T(o);
    } });
  }

  document.addEventListener("DOMContentLoaded", function () {
    var box = document.createElement("div");
    box.style.cssText = "position:fixed;right:8px;bottom:8px;z-index:99999;font:12px system-ui,sans-serif;color:#ddd;background:rgba(20,20,20,.85);padding:4px 8px;border-radius:6px;display:flex;gap:10px;align-items:center";
    function mk(label, id, opts, cur, key) {
      var l = document.createElement("label"); l.textContent = label + " ";
      var s = document.createElement("select"); s.id = id;
      opts.forEach(function (o) { var e = document.createElement("option"); e.value = o[0]; e.textContent = o[1]; if (o[0] === cur) e.selected = true; s.appendChild(e); });
      s.onchange = function () { set(key, s.value); location.reload(); };
      l.appendChild(s); box.appendChild(l);
    }
    mk("Sound buffer", "ts-buffer", FRAMES.map(function (f) { return [f, f === "auto" ? "Auto (stock)" : f + " frames (" + Math.round(f / 44.1) + " ms)"]; }), frames, KEY_FRAMES);
    mk("Output", "ts-hint", [["stock", "Lowest (stock)"], ["balanced", "Balanced"], ["safe", "Safe"]], hint, KEY_HINT);
    box.title = "Smaller buffer = less delay but more risk of crackles. Changing reloads the page. The stock page still raises the buffer after a dropout.";
    document.body.appendChild(box);
  });
})();
