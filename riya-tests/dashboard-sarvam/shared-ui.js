// Shared top bar for every dashboard page (Sarvam test dashboard):
//  - the bell shows a WhatsApp-style count of callbacks waiting and a short list
//  - the search box searches appointments, patients and callback requests
// Load after config.js. Pages that already have their own search input
// (the Dashboard's #bookingSearch) keep it; the bell works everywhere.
(function () {
  if (!window.supabaseClient) return;
  var db = window.supabaseClient;

  function esc(v) {
    return String(v == null ? "" : v).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function shortTime(iso) {
    return new Date(iso).toLocaleString("en-IN", { day: "numeric", month: "short", hour: "numeric", minute: "2-digit" });
  }
  function dateKey(iso) {
    var d = new Date(iso), p = function (n) { return String(n).padStart(2, "0"); };
    return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate());
  }

  var css = document.createElement("style");
  css.textContent =
    ".topbar .nv-bell{position:relative;border:0;cursor:pointer;font-family:inherit}" +
    ".topbar .nv-bell .dot{display:none!important}" +
    ".nv-badge{position:absolute;top:-4px;right:-6px;min-width:19px;height:19px;padding:0 5px;border-radius:10px;background:#25D366;color:#fff;font:700 11px/19px -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;text-align:center;border:2px solid #fff;box-sizing:content-box}" +
    ".nv-badge[hidden]{display:none}" +
    ".nv-panel{position:absolute;right:0;top:46px;width:min(360px,calc(100vw - 32px));background:#fff;border:1px solid var(--border,#EAEDF2);border-radius:12px;box-shadow:0 18px 38px rgba(24,50,75,.16);padding:12px;z-index:60;text-align:left;cursor:default;display:none}" +
    ".nv-panel.show{display:block}" +
    ".nv-panel h3{margin:2px 4px 8px;font-size:13px;color:var(--text-dark,#1A1F2B)}" +
    ".nv-item{display:block;padding:9px 8px;border-radius:8px;text-decoration:none;color:var(--text-dark,#1A1F2B)}" +
    ".nv-item:hover,.nv-item.active{background:var(--bg,#F5F7FA)}" +
    ".nv-item b{display:block;font-size:13px;font-weight:650}" +
    ".nv-item span{display:block;font-size:12px;color:var(--text-muted,#7C8493);margin-top:2px}" +
    ".nv-empty{padding:10px 8px;font-size:12.5px;color:var(--text-muted,#7C8493)}" +
    ".nv-more{display:block;margin-top:6px;padding:9px 8px;border-top:1px solid var(--border,#EAEDF2);font-size:12.5px;font-weight:600;color:var(--blue,#3B82F6);text-decoration:none}" +
    ".topbar .search.nv-search{position:relative}" +
    ".topbar .search.nv-search input{width:100%;border:0;outline:0;background:transparent;color:var(--text-dark,#1A1F2B);font:inherit}" +
    ".nv-results{position:absolute;left:0;top:calc(100% + 6px);width:min(440px,calc(100vw - 32px));background:#fff;border:1px solid var(--border,#EAEDF2);border-radius:12px;box-shadow:0 18px 38px rgba(24,50,75,.16);padding:8px;z-index:60;display:none;max-height:70vh;overflow:auto}" +
    ".nv-results.show{display:block}" +
    ".nv-results h4{margin:8px 8px 4px;font-size:11px;text-transform:uppercase;letter-spacing:.4px;color:var(--text-muted,#7C8493)}";
  document.head.appendChild(css);

  // ---------------- Bell ----------------
  var bellPanel = null, bellBadge = null;
  function setupBell() {
    var old = document.querySelector(".topbar .bell");
    if (!old) return;
    var bell = document.createElement("button");
    bell.type = "button";
    bell.className = "bell nv-bell";
    bell.id = old.id || "callbackBell";
    bell.setAttribute("aria-label", "Callback notifications");
    bell.setAttribute("aria-expanded", "false");
    var svg = old.querySelector("svg");
    bell.innerHTML = (svg ? svg.outerHTML : "") + '<span class="nv-badge" hidden></span><div class="nv-panel" role="dialog" aria-label="Callback notifications"><h3>Callbacks waiting</h3><div class="nv-list"><div class="nv-empty">Loading…</div></div><a class="nv-more" href="callback-requests.html">Open Callback Requests</a></div>';
    old.replaceWith(bell); // drops any older click handler on the old bell
    bellPanel = bell.querySelector(".nv-panel");
    bellBadge = bell.querySelector(".nv-badge");
    bell.addEventListener("click", function (e) {
      if (e.target.closest(".nv-panel")) return;
      var open = bellPanel.classList.toggle("show");
      bell.setAttribute("aria-expanded", String(open));
    });
    document.addEventListener("click", function (e) {
      if (!bell.contains(e.target)) { bellPanel.classList.remove("show"); bell.setAttribute("aria-expanded", "false"); }
    });
  }

  async function loadBell() {
    if (!bellPanel) return;
    var results = await Promise.all([
      db.from("calls").select("id, phone_number, caller_name, outcome, created_at, patients(name)")
        .in("outcome", ["missed", "callback_requested"]).eq("callback_done", false)
        .order("created_at", { ascending: false }).limit(50),
      db.from("callback_requests").select("id, caller_name, phone_number, reason, created_at")
        .eq("status", "pending").order("created_at", { ascending: false }).limit(50)
    ]);
    var list = bellPanel.querySelector(".nv-list");
    if (results[0].error && results[1].error) { list.innerHTML = '<div class="nv-empty">Could not load notifications.</div>'; return; }
    var items = (results[0].data || []).map(function (c) {
      return { who: (c.patients && c.patients.name) || c.caller_name || c.phone_number || "Unknown caller", phone: c.phone_number,
        why: c.outcome === "callback_requested" ? "Doctor unavailable" : "Missed call", at: c.created_at };
    }).concat((results[1].data || []).map(function (r) {
      return { who: r.caller_name || r.phone_number || "Caller", phone: r.phone_number, why: r.reason || "Callback requested", at: r.created_at };
    })).sort(function (a, b) { return new Date(b.at) - new Date(a.at); });
    var n = items.length;
    bellBadge.hidden = n === 0;
    bellBadge.textContent = n > 99 ? "99+" : String(n);
    bellBadge.parentNode.setAttribute("aria-label", n ? n + " callbacks waiting" : "No callbacks waiting");
    list.innerHTML = n
      ? items.slice(0, 6).map(function (i) {
          return '<a class="nv-item" href="callback-requests.html"><b>' + esc(i.who) + (i.phone && i.phone !== i.who ? " · " + esc(i.phone) : "") + '</b><span>' + esc(i.why) + " · " + esc(shortTime(i.at)) + "</span></a>";
        }).join("") + (n > 6 ? '<div class="nv-empty">+' + (n - 6) + " more</div>" : "")
      : '<div class="nv-empty">No callbacks waiting. You are all caught up.</div>';
  }

  // ---------------- Search ----------------
  var searchBox = null, resultsBox = null, searchTimer = null, searchRun = 0;
  function setupSearch() {
    var box = document.querySelector(".topbar .search");
    if (!box || box.querySelector("input")) return; // page has its own working search
    var svg = box.querySelector("svg");
    box.classList.add("nv-search");
    box.innerHTML = (svg ? svg.outerHTML : "") +
      '<input type="search" autocomplete="off" placeholder="Search patients, appointments, callbacks…" aria-label="Search patients, appointments and callbacks">' +
      '<div class="nv-results" role="listbox"></div>';
    searchBox = box.querySelector("input");
    resultsBox = box.querySelector(".nv-results");
    searchBox.addEventListener("input", function () {
      var q = searchBox.value.trim();
      document.dispatchEvent(new CustomEvent("nirva:search", { detail: q }));
      clearTimeout(searchTimer);
      if (q.length < 2) { resultsBox.classList.remove("show"); return; }
      searchTimer = setTimeout(function () { runSearch(q); }, 220);
    });
    searchBox.addEventListener("keydown", function (e) {
      var links = Array.from(resultsBox.querySelectorAll("a.nv-item"));
      var i = links.indexOf(resultsBox.querySelector("a.nv-item.active"));
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        if (!links.length) return;
        if (i >= 0) links[i].classList.remove("active");
        i = e.key === "ArrowDown" ? Math.min(links.length - 1, i + 1) : Math.max(0, i - 1);
        links[i].classList.add("active");
      } else if (e.key === "Enter") {
        var go = links[i >= 0 ? i : 0];
        if (go) location.href = go.href;
      } else if (e.key === "Escape") {
        resultsBox.classList.remove("show");
      }
    });
    searchBox.addEventListener("focus", function () { if (resultsBox.innerHTML && searchBox.value.trim().length >= 2) resultsBox.classList.add("show"); });
    document.addEventListener("click", function (e) { if (!box.contains(e.target)) resultsBox.classList.remove("show"); });
  }

  async function runSearch(q) {
    var run = ++searchRun;
    // Keep only safe characters for the database filter.
    var text = q.replace(/[^\p{L}\p{N} .@'-]/gu, " ").replace(/\s+/g, " ").trim();
    var digits = q.replace(/\D/g, "");
    var nameTerm = text ? "*" + text + "*" : null;
    var phoneTerm = digits.length >= 3 ? "*" + digits + "*" : null;
    if (!nameTerm && !phoneTerm) return;
    function either(nameCol, phoneCol) {
      var parts = [];
      if (nameTerm) parts.push(nameCol + ".ilike." + nameTerm);
      if (phoneTerm) parts.push(phoneCol + ".ilike." + phoneTerm);
      return parts.join(",");
    }
    var since = new Date(); since.setDate(since.getDate() - 60);
    var res = await Promise.all([
      db.from("bookings").select("id, appointment_time, status, patient_name_snapshot, phone_e164_snapshot, doctors(name)")
        .or(either("patient_name_snapshot", "phone_e164_snapshot")).neq("status", "rescheduled")
        .gte("appointment_time", since.toISOString()).order("appointment_time", { ascending: false }).limit(8),
      db.from("patients").select("id, name, phone").or(either("name", "phone")).order("name").limit(5),
      db.from("callback_requests").select("id, caller_name, phone_number, status, created_at")
        .or(either("caller_name", "phone_number")).order("created_at", { ascending: false }).limit(5)
    ]);
    if (run !== searchRun) return;
    var labels = { confirmed: "Expected", arrived: "Arrived", completed: "Completed", no_show: "No-show", cancelled: "Cancelled" };
    var html = "";
    var b = res[0].data || [], p = res[1].data || [], c = res[2].data || [];
    if (b.length) html += "<h4>Appointments</h4>" + b.map(function (r) {
      return '<a class="nv-item" href="calendar.html?date=' + dateKey(r.appointment_time) + '"><b>' + esc(r.patient_name_snapshot || "Patient") + '</b><span>' +
        esc(shortTime(r.appointment_time)) + " · " + esc((r.doctors && r.doctors.name) || "Doctor") + " · " + esc(labels[r.status] || r.status) + "</span></a>";
    }).join("");
    if (p.length) html += "<h4>Patients</h4>" + p.map(function (r) {
      return '<a class="nv-item" href="patients.html?q=' + encodeURIComponent(r.name || r.phone || "") + '"><b>' + esc(r.name || "Patient") + "</b><span>" + esc(r.phone || "No phone") + "</span></a>";
    }).join("");
    if (c.length) html += "<h4>Callback requests</h4>" + c.map(function (r) {
      return '<a class="nv-item" href="callback-requests.html?q=' + encodeURIComponent(r.caller_name || r.phone_number || "") + '"><b>' + esc(r.caller_name || "Caller") + "</b><span>" +
        esc(r.phone_number || "") + " · " + (r.status === "pending" ? "Pending" : "Contacted") + " · " + esc(shortTime(r.created_at)) + "</span></a>";
    }).join("");
    resultsBox.innerHTML = html || '<div class="nv-empty">Nothing matches "' + esc(q) + '".</div>';
    resultsBox.classList.add("show");
  }

  // ---------------- Start ----------------
  function start() {
    setupBell();
    setupSearch();
    db.auth.getSession().then(function (r) {
      if (!r.data || !r.data.session) return;
      loadBell();
      try {
        db.channel("nv-bell-" + Math.random().toString(36).slice(2))
          .on("postgres_changes", { event: "*", schema: "public", table: "callback_requests" }, loadBell)
          .on("postgres_changes", { event: "*", schema: "public", table: "calls" }, loadBell)
          .subscribe();
      } catch (e) {}
      setInterval(loadBell, 60000);
    });
  }
  window.NirvaTopbar = { refreshBell: function () { return loadBell(); } };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start); else start();
})();
