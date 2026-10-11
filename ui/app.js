// Changedetection.io's tabs on the chassis window: Watches, Alerts, Access, and a bit of Overview, Updates and Storage.
(function (P) {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  function cdUrl(st) { return ((st.app || {}).url || st.url || "").replace(/\/$/, ""); }
  function name(w) { return w.title || w.page_title || w.url; }
  function linksTo(st) { document.querySelectorAll(".cd-link").forEach(function (a) { a.href = cdUrl(st) + "/"; }); }
  function state(w) {
    if (w.paused) return P.chip("paused", "");
    if (w.error) return P.chip("error", "bad");
    if (!w.checked) return P.chip("not checked yet", "warn");
    if (w.changed && !w.viewed) return P.chip("changed", "ok");
    return P.chip("watching", "ok");
  }
  function toggle(box, btnBox, on, label, action, ask) {
    P.clear(box); P.clear(btnBox); box.appendChild(on ? P.chip("on", "ok") : P.chip("off", ""));
    btnBox.appendChild(P.btn(on ? "Turn off" : "Turn on", "", function () { P.act(action, { on: on ? 0 : 1 }, on ? null : ask); }));
  }

  // ---------------------------------------------------------------- Watches
  var wQuery = "";
  $("w-q").addEventListener("input", function () { wQuery = $("w-q").value.trim().toLowerCase(); $("watches").dataset.sig = ""; renderWatches((P.S || {}).status || {}); });
  function renderWatches(st) {
    var a = st.app || {}, all = a.watches || [], tb = $("watches"), t = $("w-tiles"), day = Date.now() / 1000 - 86400; linksTo(st);
    P.clear(t);
    P.tile(t, String(all.length), "watches");
    P.tile(t, String(all.filter(function (w) { return w.changed > day; }).length), "changed in 24 h");
    P.tile(t, String(all.filter(function (w) { return w.changed && !w.viewed; }).length), "changes not seen yet");
    P.tile(t, String(all.filter(function (w) { return w.error && !w.paused; }).length), "with an error");
    var allBox = $("w-all"); P.clear(allBox); if (all.length) allBox.appendChild(P.btn("Check all now", "", function () { P.act("checkall"); }));
    var shown = all.filter(function (w) { return !wQuery || (name(w) + " " + w.url).toLowerCase().indexOf(wQuery) >= 0; });
    $("w-count").textContent = all.length && wQuery ? shown.length + " of " + all.length : "";
    var sig = JSON.stringify(shown) + "|" + P.busy + "|" + P.role + "|" + Math.floor(Date.now() / 60000); if (tb.dataset.sig === sig) return; tb.dataset.sig = sig;
    P.clear(tb);
    function empty(text) { var r = P.el("tr"), c = P.cell(text, "empty"); c.colSpan = 5; r.appendChild(c); tb.appendChild(r); }
    if (!a.up) return empty("Changedetection.io isn't running.");
    if (a.ready === false) return empty("Changedetection.io is starting…");
    if (!all.length) return empty("No watches yet. Add a page below, or in Changedetection.io.");
    if (!shown.length) return empty("Nothing matches.");
    shown.forEach(function (w) {
      var who = P.el("div"); who.appendChild(P.el("div", name(w), "w-name" + (w.changed && !w.viewed ? " new" : "")));
      if (name(w) !== w.url) who.appendChild(P.el("div", w.url, "w-url"));
      if (w.via_browser) who.appendChild(P.el("div", "with the browser" + (((a.browser || {}).on) ? "" : " — which is off"), "w-url"));
      if (w.error) who.appendChild(P.el("div", w.error, "w-err"));
      var acts = P.el("span", null, "row");
      acts.appendChild(P.btn("Check now", "", function () { P.act("watchcheck", { id: w.id }); }));
      acts.appendChild(w.paused ? P.btn("Resume", "", function () { P.act("watchresume", { id: w.id }); }) : P.btn("Pause", "", function () { P.act("watchpause", { id: w.id }); }));
      var open = P.el("a", "Open", "btn"); open.href = cdUrl(st) + (w.changed ? "/diff/" : "/edit/") + w.id; open.title = w.changed ? "See what changed, in Changedetection.io" : "Its settings, in Changedetection.io"; open.target = "_blank"; open.rel = "noopener"; acts.appendChild(open);
      P.row(tb, [P.cell(state(w), "nw"), P.cell(who), P.cell(w.changed ? P.ago(w.changed) : "no change yet", "nw"), P.cell(w.checked ? P.ago(w.checked) : "–", "nw"), P.cell(acts, "n nw")]);
    });
  }
  function renderLan(st) { var a = st.app || {}; toggle($("lan-state"), $("lan-btn"), !!a.lan_pages, "", "lanpages", "Allow watching pages on your own network? Changedetection.io restarts for a few seconds."); }
  function renderBrowser(st) {
    var a = st.app || {}, b = a.browser || {}, box = $("br-state");
    toggle(box, $("br-btn"), !!b.on, "", "browser", "Turn the browser on? It's about a 500 MB download the first time and uses roughly 1 GB of memory while it runs.");
    if (b.on) box.appendChild(P.el("span", " — " + (b.state === "running" ? "running" : (b.state || "not started")), "muted small"));
    $("wa-browser-row").hidden = !b.on; if (!b.on) $("wa-browser").checked = false;
  }
  $("wa-add").onclick = function () {
    var u = $("wa-url").value.trim(); if (!u) { P.showErr("Type the page's address first."); return; }
    if (!/^https?:\/\//i.test(u)) u = "https://" + u;
    P.act("watchadd", { url: u, title: $("wa-title").value.trim(), browser: $("wa-browser").checked ? 1 : 0 }).then(function () { $("wa-url").value = ""; $("wa-title").value = ""; });
  };
  P.register("watches", {
    render: function (st) { renderWatches(st); renderLan(st); renderBrowser(st); },
    badge: function (st) { var n = (((st.app || {}).watches) || []).filter(function (w) { return w.changed && !w.viewed; }).length; $("badge-watches").hidden = !n; $("badge-watches").textContent = String(n); }
  });
  P.register("overview", { tiles: function (t, st) { var ws = (st.app || {}).watches || []; P.tile(t, String(ws.length), "watches"); P.tile(t, String(ws.filter(function (w) { return w.changed && !w.viewed; }).length), "changes not seen yet"); } });

  // ---------------------------------------------------------------- Alerts
  P.register("alerts", {
    render: function (st) {
      var a = st.app || {}, notes = a.notes || [], tb = $("notes"), nt = a.ntfy || {}, box = $("ntfy-box");
      if (!$("dn-mode").dataset.touched) $("dn-mode").value = a.notify || "changes";
      var sig = JSON.stringify([notes, nt]) + "|" + P.busy + "|" + P.role; if (tb.dataset.sig === sig) return; tb.dataset.sig = sig;
      P.clear(tb);
      if (!notes.length) { var r = P.el("tr"), c = P.cell("No addresses yet: Changedetection.io's own notifications go nowhere. Connect ntfy above, or add an Apprise address.", "empty"); c.colSpan = 2; r.appendChild(c); tb.appendChild(r); }
      notes.forEach(function (n) {
        var acts = P.el("span", null, "row");
        acts.appendChild(P.btn("Send a test", "", function () { P.act("notetest", { id: n.id }); }));
        acts.appendChild(P.btn("Remove", "danger", function () { P.act("notedel", { id: n.id }, "Remove " + n.label + "? Changes stop going there."); }));
        P.row(tb, [P.cell(P.el("b", n.label)), P.cell(acts, "n")]);
      });
      $("nt-all").hidden = notes.length < 2;
      P.clear(box);
      if (!nt.found) {
        box.appendChild(P.el("p", "The ntfy package isn't running on this Synology. Install it (it's built like this one) to get changes as push notifications on your phone, from your own server — then come back here and connect it with one click.", "muted small"));
        return;
      }
      box.appendChild(P.el("p", "ntfy is installed here, at " + (nt.url || "") + ". One click makes it a sender that may only post to the topic you choose, and adds it to Changedetection.io's notifications. Phones set up with the ntfy package's Phones tab and subscribed to that topic get every change.", "muted small"));
      if (nt.connected) { var p0 = P.el("p"); p0.appendChild(P.chip("connected", "ok")); box.appendChild(p0); }
      var lab = P.el("label", null, "f"); lab.appendChild(P.el("span", "Topic (dsm is the one the ntfy package's phones already read)"));
      var row = P.el("span", null, "inline"), inp = P.el("input"); inp.type = "text"; inp.id = "ntfy-topic"; inp.value = box.dataset.topic || "dsm"; inp.maxLength = 64; inp.oninput = function () { box.dataset.topic = inp.value; };
      row.appendChild(inp); row.appendChild(P.btn(nt.connected ? "Connect again" : "Send changes to ntfy", "primary", function () { P.act("ntfyuse", { topic: inp.value.trim() || "dsm" }, nt.connected ? "Replace the ntfy connection? The old token is removed from ntfy." : null); }));
      lab.appendChild(row); box.appendChild(lab);
      box.appendChild(P.el("p", "Another topic than dsm? Give people read access to it in the ntfy window's Users tab.", "muted small"));
    }
  });
  $("dn-mode").addEventListener("change", function () { $("dn-mode").dataset.touched = "1"; });
  $("dn-save").onclick = function () { P.act("dsmnotify", { mode: $("dn-mode").value }).then(function () { $("dn-mode").dataset.touched = ""; }); };
  $("nt-add").onclick = function () { var u = $("nt-url").value.trim(); if (!u) { P.showErr("Paste an Apprise address first."); return; } P.act("noteadd", { note: u }).then(function () { $("nt-url").value = ""; }); };
  $("nt-all").onclick = function () { P.act("notetest", {}); };

  // ---------------------------------------------------------------- Access
  P.register("access", {
    render: function (st) {
      var a = st.app || {}, on = !!a.password, chip = $("acc-chip"), btns = $("acc-btns"), sig = on + "|" + P.busy + "|" + P.role + "|" + a.up;
      $("acc-note").className = "note " + (on ? "good" : "warn");
      $("acc-note").textContent = on ? "Changedetection.io asks for a password. Forgotten it? Make a new one here — it's shown once." : "Changedetection.io is open to anyone who can reach " + (cdUrl(st) || "it") + ": no password is asked. Turn protection on below.";
      if (btns.dataset.sig === sig) return; btns.dataset.sig = sig; P.clear(chip); P.clear(btns);
      chip.appendChild(on ? P.chip("on", "ok") : P.chip("off", "bad"));
      btns.appendChild(P.btn(on ? "Make a new password" : "Turn on with a new password", "primary", function () { P.act("pwnew", {}, on ? "Make a new password? The old one stops working." : null); }));
      if (on) btns.appendChild(P.btn("Turn protection off", "danger", function () { P.act("pwoff", {}, "Turn password protection off? Anyone who can reach Changedetection.io can then use it."); }));
    }
  });
  $("acc-set").onclick = function () {
    var p = $("acc-pw").value; if (p.length < 8) { P.showErr("A password is at least 8 characters."); return; }
    P.act("pwset", { password: p }, "Set this as Changedetection.io's password?").then(function () { $("acc-pw").value = ""; });
  };
  P.register("secretNote", function (s) { return s.kind === "access" ? "Sign in to Changedetection.io with this, then keep it in your password manager." : ""; });

  // ---------------------------------------------------------------- Updates: which release
  P.register("updates", { render: function (st) {
    var iu = st.image_update || {}, box = $("upd-app"), p = $("cd-rel") || P.el("p", null, "muted small"); p.id = "cd-rel";
    p.textContent = iu.latest ? "Pinned release: " + (iu.current || "?") + "; newest on GitHub: " + iu.latest + "." : "";
    if (!p.parentNode) box.appendChild(p);
  } });

  // ---------------------------------------------------------------- Storage
  P.register("storage", { render: function (app, st, box) {
    P.clear(box); var c = P.el("div", null, "card"); c.appendChild(P.el("h2", "Inside the data volume")); var tbl = P.el("table"), tb = P.el("tbody"); tbl.appendChild(tb); c.appendChild(tbl);
    P.kv(tb, "Everything: watches, their snapshots and screenshots", P.mb(app.all || 0), true);
    P.kv(tb, "Watches stored", String(app.folders || 0), true);
    P.kv(tb, "Settings (changedetection.json)", (app.settings_kb || 0) + " KB", true);
    c.appendChild(P.el("p", "Each check that finds a change keeps a snapshot. Changedetection.io can limit how many it keeps (Settings → General, or per watch).", "muted small")); box.appendChild(c);
  } });
})(window.Panel);
