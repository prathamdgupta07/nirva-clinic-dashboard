// One permanent local dashboard address. 127.0.0.1 and localhost refer to
// the same computer, but browsers keep separate login sessions for them.
// Redirect old links before the app initializes Supabase authentication.
if (window.location.hostname === "127.0.0.1") {
  var canonicalDashboardUrl = new URL(window.location.href);
  canonicalDashboardUrl.hostname = "localhost";
  window.location.replace(canonicalDashboardUrl.toString());
}

// Supabase connection settings for the Sarvam dashboard (separate project
// from the Vapi dashboard -- see ../dashboard/config.js for that one).
// Publishable/anon key — safe to expose in client-side code, RLS controls
// what it can actually read/write.
var SUPABASE_URL = "https://ukfpiqtqxtywfuvakfgz.supabase.co";
var SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVrZnBpcXRxeHR5d2Z1dmFrZmd6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgxMDUwMzAsImV4cCI6MjEwMzY4MTAzMH0.efoeHPko3LTjAjUrTfZaBVHrgGnyDN2bUnRrD4a0JXA";
var supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

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
