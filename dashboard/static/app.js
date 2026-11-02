"use strict";
const $ = (s, el = document) => el.querySelector(s);
const HDR = { "Content-Type": "application/json", "X-Requested-With": "pusat-kendali" };
const HUES = { dashboard: 152, portainer: 200, code: 210, jupyter: 28, nextcloud: 205, adminer: 260,
  postgres: 220, redis: 2, "uptime-kuma": 140, netdata: 160, "socket-proxy": 45, traefik: 190, cloudflared: 30 };
const state = { filter: "all", data: null, timer: null, cpuHist: [], memHist: [], logSvc: null, logTimer: null };

// ---------------------------------------------------------------- utils
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
function bytes(n) {
  if (n == null) return "—";
  const u = ["B", "KB", "MB", "GB", "TB"]; let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(n >= 100 || i === 0 ? 0 : 1)} ${u[i]}`;
}
function dur(s) {
  if (s == null) return "—";
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  return d ? `${d} hari ${h} jam` : h ? `${h} jam ${m} mnt` : `${m} mnt`;
}
const level = (p) => (p >= 90 ? "bad" : p >= 75 ? "warn" : "");
function toast(msg, bad = false) {
  const t = document.createElement("div");
  t.className = "toast" + (bad ? " bad" : ""); t.textContent = msg;
  $("#toasts").appendChild(t); setTimeout(() => t.remove(), 4200);
}
async function api(path, opts = {}) {
  const r = await fetch(path, { credentials: "same-origin", headers: HDR, ...opts });
  const j = await r.json().catch(() => ({}));
  if (r.status === 401 && path !== "/api/login") { showLogin(); throw new Error("sesi berakhir"); }
  if (!r.ok) throw new Error(j.error || `HTTP ${r.status}`);
  return j;
}

// ---------------------------------------------------------------- auth
function showLogin() {
  clearInterval(state.timer); state.timer = null;
  $("#app").classList.add("hidden"); $("#login").classList.remove("hidden");
  setTimeout(() => $("#lg-user").focus(), 50);
}
function showApp() {
  $("#login").classList.add("hidden"); $("#app").classList.remove("hidden");
  refresh(); clearInterval(state.timer); state.timer = setInterval(refresh, 5000);
}
$("#login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const btn = e.submitter || $("#login-form button"); btn.disabled = true; $("#lg-err").textContent = "";
  try {
    await api("/api/login", { method: "POST", body: JSON.stringify({ username: $("#lg-user").value, password: $("#lg-pass").value }) });
    $("#lg-pass").value = ""; showApp();
  } catch (err) { $("#lg-err").textContent = err.message; }
  finally { btn.disabled = false; }
});
$("#btn-logout").addEventListener("click", async () => { await api("/api/logout", { method: "POST" }).catch(() => {}); showLogin(); });

// ---------------------------------------------------------------- render
function setMeter(id, pct, val, sub) {
  const el = $(id);
  el.querySelector(".val").innerHTML = val;
  if (sub != null) el.querySelector(".sub").textContent = sub;
  const bar = el.querySelector(".bar");
  if (bar) { bar.className = "bar " + level(pct ?? 0); bar.querySelector("i").style.width = `${Math.min(100, pct ?? 0)}%`; }
}
function spark(canvas, hist, color) {
  const dpr = window.devicePixelRatio || 1, w = canvas.clientWidth, h = canvas.clientHeight;
  canvas.width = w * dpr; canvas.height = h * dpr;
  const c = canvas.getContext("2d"); c.scale(dpr, dpr); c.clearRect(0, 0, w, h);
  if (hist.length < 2) return;
  const top = Math.min(100, Math.max(10, Math.max(...hist) * 1.4));
  const step = w / 59, y = (v) => h - 3 - (v / top) * (h - 6);
  const x0 = w - (hist.length - 1) * step;
  c.beginPath(); hist.forEach((v, i) => (i ? c.lineTo(x0 + i * step, y(v)) : c.moveTo(x0, y(v))));
  c.strokeStyle = color; c.lineWidth = 1.6; c.lineJoin = "round"; c.stroke();
  c.lineTo(w, h); c.lineTo(x0, h); c.closePath();
  const g = c.createLinearGradient(0, 0, 0, h); g.addColorStop(0, color + "40"); g.addColorStop(1, color + "00");
  c.fillStyle = g; c.fill();
}
function renderHost(hst) {
  const cpu = hst.cpu || {}, mem = hst.memory || {}, disk = hst.disk || {};
  if (cpu.percent != null) { state.cpuHist.push(cpu.percent); if (state.cpuHist.length > 60) state.cpuHist.shift(); }
  if (mem.percent != null) { state.memHist.push(mem.percent); if (state.memHist.length > 60) state.memHist.shift(); }
  setMeter("#m-cpu", cpu.percent, cpu.percent == null ? "…" : `${cpu.percent.toFixed(1)}<small>%</small>`, cpu.cores ? `${cpu.cores} core` : "—");
  setMeter("#m-mem", mem.percent, mem.percent == null ? "—" : `${mem.percent.toFixed(0)}<small>%</small>`, mem.total ? `${bytes(mem.used)} / ${bytes(mem.total)}` : "—");
  setMeter("#m-disk", disk.percent, disk.percent == null ? "—" : `${disk.percent.toFixed(0)}<small>%</small>`, disk.total ? `${bytes(disk.total)}` : "—");
  $("#m-disk .foot").textContent = disk.total ? `terpakai ${bytes(disk.used)} · sisa ${bytes(disk.total - disk.used)}` : "—";
  $("#m-up .val").textContent = dur(hst.uptime);
  const ld = hst.load || [];
  $("#m-up .load").innerHTML = [0, 1, 2].map((i) => `<span>${ld[i] != null ? ld[i].toFixed(2) : "—"}</span>`).join("");
  spark($("#m-cpu .spark"), state.cpuHist, "#3ddc97");
  spark($("#m-mem .spark"), state.memHist, "#6aa8ff");
}
function stateLabel(s) {
  return { running: "berjalan", exited: "berhenti", restarting: "restart…", paused: "jeda", created: "dibuat", dead: "mati" }[s] || s;
}
function card(s) {
  const hue = HUES[s.service] ?? (s.service.length * 47) % 360;
  const run = s.state === "running";
  const st = s.stats || {};
  const memPct = st.mem && st.mem.limit ? (100 * st.mem.used) / st.mem.limit : 0;
  const initials = s.title.replace(/[^A-Za-z ]/g, "").split(" ").map((w) => w[0]).join("").slice(0, 2).toUpperCase() || "?";
  return `
  <article class="card ${run ? "" : "stopped"}" data-state="${run ? "running" : "stopped"}">
    <div class="card-top">
      <div class="mono" style="background:linear-gradient(135deg,hsl(${hue} 70% 62%),hsl(${(hue + 40) % 360} 75% 52%))">${esc(initials)}</div>
      <div style="min-width:0">
        <h3>${esc(s.title)} ${s.protected ? '<span class="lock" title="Tidak bisa dimatikan dari panel">inti</span>' : ""}</h3>
        <p>${esc(s.desc)}</p>
      </div>
      <span class="pill ${esc(s.state)}">${esc(stateLabel(s.state))}</span>
    </div>
    <div class="meta">
      <div class="mini"><span>CPU <b>${run && st.cpu != null ? st.cpu.toFixed(1) + "%" : "—"}</b></span><div class="bar ${level(st.cpu || 0)}"><i style="width:${Math.min(100, st.cpu || 0)}%"></i></div></div>
      <div class="mini"><span>RAM <b>${run && st.mem ? bytes(st.mem.used) : "—"}</b></span><div class="bar ${level(memPct)}"><i style="width:${Math.min(100, memPct)}%"></i></div></div>
    </div>
    <div class="status" title="${esc(s.image)}">${esc(s.status)} · ${esc(s.image)}</div>
    <div class="actions">
      ${s.url && run ? `<a class="btn sm go open" href="${esc(s.url)}" target="_blank" rel="noopener noreferrer">Buka ↗</a>` : `<span class="open"></span>`}
      <button class="btn sm ghost" data-act="logs" data-id="${s.id}" data-title="${esc(s.title)}">Log</button>
      ${run ? `<button class="btn sm ghost" data-act="restart" data-id="${s.id}">Restart</button>` : ""}
      ${run ? (s.protected ? "" : `<button class="btn sm ghost danger" data-act="stop" data-id="${s.id}" data-title="${esc(s.title)}">Stop</button>`)
            : `<button class="btn sm ghost go" data-act="start" data-id="${s.id}">Start</button>`}
    </div>
  </article>`;
}
function renderServices() {
  const all = state.data?.services || [];
  const list = all.filter((s) => state.filter === "all" || (state.filter === "running") === (s.state === "running"));
  $("#grid").innerHTML = list.map(card).join("");
  $("#empty").classList.toggle("hidden", all.length > 0 || !state.data?.docker_ok);
  const up = all.filter((s) => s.state === "running").length;
  $("#m-count").textContent = `${up}/${all.length} layanan berjalan`;
}
async function refresh() {
  try {
    const d = await api("/api/overview");
    state.data = d;
    $("#tb-project").textContent = `${d.project} · ${d.mode !== "local" ? d.domain : d.host_addr}`;
    $("#tb-mode").textContent = ({ domain: "mode: domain + HTTPS", tunnel: "mode: cloudflare tunnel" })[d.mode] || "mode: lokal";
    const conn = $("#tb-conn"); conn.className = "conn " + (d.docker_ok ? "ok" : "bad");
    conn.querySelector("span").textContent = d.docker_ok ? "terhubung" : "docker terputus";
    $("#banner").classList.toggle("hidden", !d.error || d.error === "memuat…");
    $("#banner").textContent = d.error || "";
    renderHost(d.host || {});
    renderServices();
  } catch (e) {
    if (e.message !== "sesi berakhir") { $("#tb-conn").className = "conn bad"; $("#tb-conn span").textContent = "panel tidak terjangkau"; }
  }
}

// ---------------------------------------------------------------- actions
document.querySelectorAll(".filters .chip").forEach((b) => b.addEventListener("click", () => {
  document.querySelectorAll(".filters .chip").forEach((x) => x.classList.remove("on"));
  b.classList.add("on"); state.filter = b.dataset.f; renderServices();
}));
$("#grid").addEventListener("click", async (e) => {
  const b = e.target.closest("button[data-act]"); if (!b) return;
  const { act, id, title } = b.dataset;
  if (act === "logs") return openLogs(id, title);
  if (act === "stop" && !confirm(`Hentikan ${title}?`)) return;
  b.disabled = true; b.textContent = { start: "Menyalakan…", stop: "Menghentikan…", restart: "Merestart…" }[act];
  try { await api(`/api/services/${id}/${act}`, { method: "POST" }); toast(`${act} berhasil`); setTimeout(refresh, 900); }
  catch (err) { toast(err.message, true); refresh(); }
});

// ---------------------------------------------------------------- logs
function fmtLogs(txt) {
  return esc(txt).split("\n").map((l) => {
    const m = l.match(/^(\d{4}-\d\d-\d\dT[\d:.]+Z?)\s(.*)$/);
    let body = m ? m[2] : l;
    const cls = /\b(error|err|fatal|panic|exception)\b/i.test(body) ? "e" : /\bwarn(ing)?\b/i.test(body) ? "w" : "";
    if (cls) body = `<span class="${cls}">${body}</span>`;
    return m ? `<span class="ts">${m[1].slice(5, 19).replace("T", " ")}</span> ${body}` : body;
  }).join("\n");
}
async function loadLogs() {
  if (!state.logSvc) return;
  const pre = $("#log-body");
  const atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 30;
  try {
    const j = await api(`/api/services/${state.logSvc}/logs?tail=${$("#log-tail").value}`);
    pre.innerHTML = fmtLogs(j.logs) || "(log kosong)";
    if ($("#log-follow").checked && atBottom) pre.scrollTop = pre.scrollHeight;
  } catch (e) { pre.textContent = "Gagal memuat log: " + e.message; }
}
function openLogs(id, title) {
  state.logSvc = id; $("#log-title").textContent = `Log · ${title}`; $("#log-sub").textContent = id;
  $("#log-body").textContent = "memuat…"; $("#logdlg").showModal();
  loadLogs().then(() => { $("#log-body").scrollTop = 1e9; });
  clearInterval(state.logTimer); state.logTimer = setInterval(() => $("#log-follow").checked && loadLogs(), 3000);
}
$("#logdlg").addEventListener("close", () => { clearInterval(state.logTimer); state.logSvc = null; });
$("#log-close").addEventListener("click", () => $("#logdlg").close());
$("#log-refresh").addEventListener("click", loadLogs);
$("#log-tail").addEventListener("change", loadLogs);

// ---------------------------------------------------------------- boot
api("/api/session").then((s) => (s.authenticated ? showApp() : showLogin())).catch(showLogin);
