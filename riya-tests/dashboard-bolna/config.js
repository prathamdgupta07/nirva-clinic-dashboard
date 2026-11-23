// One permanent local dashboard address. 127.0.0.1 and localhost refer to
// the same computer, but browsers keep separate login sessions for them.
// Redirect old links before the app initializes Supabase authentication.
if (window.location.hostname === "127.0.0.1") {
  var canonicalDashboardUrl = new URL(window.location.href);
  canonicalDashboardUrl.hostname = "localhost";
  window.location.replace(canonicalDashboardUrl.toString());
}

// Riya Bolna TEST dashboard. Points at the separate test Supabase
// project esvurkdwzcxtzimbpkwv (new account), never at the Vani project.
// Publishable/anon key — safe to expose in client-side code, RLS controls
// what it can actually read/write.
var SUPABASE_URL = "https://esvurkdwzcxtzimbpkwv.supabase.co";
var SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVzdnVya2R3emN4dHppbWJwa3d2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTU0NDQ2MzEsImV4cCI6MjExMTAyMDYzMX0._TC3d_6bF5RNJqezHxdCWWOS-zUVOSVLhVlRWOsgBbY";
// Keep the login in sessionStorage, not localStorage, so it ends when the tab
// or browser is closed (including Cmd+Q). Opening the dashboard link again
// always starts at the login page. Each new tab also needs its own login.
// Remove any older login saved in localStorage so it cannot be reused.
try { localStorage.removeItem("sb-esvurkdwzcxtzimbpkwv-auth-token"); } catch (e) {}
var supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { storage: window.sessionStorage, persistSession: true }
});

// ---------- Login/logout history tracking (shared by every page) ----------
// One row per session: login_time is set on insert, logout_time is filled in
// later. The row id is kept in sessionStorage (per-tab) so any page in this
// tab can update it on logout.
var LOGIN_HISTORY_KEY = "nirva_login_history_id";
var _currentAccessToken = null;

supabaseClient.auth.onAuthStateChange(function (_event, session) {
  _currentAccessToken = session && session.access_token;
});

async function recordLogin(userId) {
  try {
    var res = await supabaseClient.from("login_history").insert({ user_id: userId }).select("id").single();
    if (res.error) {
      // Do not expose backend or database diagnostics in the browser console.
      console.error("Could not record login history.");
      return;
    }
    sessionStorage.setItem(LOGIN_HISTORY_KEY, res.data.id);
  } catch (e) {
    console.error("Could not record login history.");
  }
}

async function recordLogout() {
  var rowId = sessionStorage.getItem(LOGIN_HISTORY_KEY);
  if (!rowId) return;
  sessionStorage.removeItem(LOGIN_HISTORY_KEY);
  try {
    await supabaseClient.from("login_history").update({ logout_time: new Date().toISOString() }).eq("id", rowId);
  } catch (e) {
    console.error("Could not record logout time.");
  }
}

// Catches the case where staff just close the tab (Cmd+W / Ctrl+W) instead
// of clicking "Log out". pagehide fires reliably on tab close; a normal
// awaited Supabase call would get cancelled mid-flight at that point, so this
// fires a keepalive fetch directly instead (the sendBeacon equivalent for a
// PATCH request — sendBeacon itself only supports POST).
window.addEventListener("pagehide", function () {
  var rowId = sessionStorage.getItem(LOGIN_HISTORY_KEY);
  if (!rowId || !_currentAccessToken) return;
  fetch(SUPABASE_URL + "/rest/v1/login_history?id=eq." + rowId, {
    method: "PATCH",
    keepalive: true,
    headers: {
      "Content-Type": "application/json",
      "apikey": SUPABASE_ANON_KEY,
      "Authorization": "Bearer " + _currentAccessToken,
      "Prefer": "return=minimal"
    },
    body: JSON.stringify({ logout_time: new Date().toISOString() })
  });
});

// Dashboard pages retain their own Supabase session checks. Sign-in uses the
// normal email/password flow; no second-factor challenge is required.

// ---------- Test environment label (Riya Bolna test) ----------
var RIYA_TEST_LABEL = "BOLNA TEST";
(function () {
  try { if (document.title.indexOf(RIYA_TEST_LABEL) !== 0) document.title = RIYA_TEST_LABEL + " · " + document.title; } catch (e) {}
  function addBadge() {
    if (document.getElementById("riya-test-badge")) return;
    var bar = document.createElement("div");
    bar.id = "riya-test-badge";
    bar.setAttribute("role", "status");
    bar.textContent = RIYA_TEST_LABEL + " · Riya on Bolna · test data only";
    bar.style.cssText = "position:fixed;top:0;left:0;right:0;z-index:2147483647;height:26px;line-height:26px;" +
      "text-align:center;font:600 12px/26px system-ui,-apple-system,Segoe UI,sans-serif;letter-spacing:.08em;" +
      "color:#fff;background:#EA580C;box-shadow:0 1px 4px rgba(0,0,0,.18);pointer-events:none";
    document.body.appendChild(bar);
    document.body.style.paddingTop = "26px";
    var link = document.querySelector("link[rel~='icon']") || document.createElement("link");
    link.rel = "icon";
    link.href = "data:image/svg+xml," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="7" fill="#EA580C"/><text x="16" y="22" font-size="17" font-family="Arial" font-weight="700" fill="#fff" text-anchor="middle">B</text></svg>');
    document.head.appendChild(link);
  }
  if (document.body) addBadge(); else document.addEventListener("DOMContentLoaded", addBadge);
})();
