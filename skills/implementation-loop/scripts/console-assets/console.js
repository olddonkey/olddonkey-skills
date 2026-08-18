"use strict";

(function () {
  var POLL_MS = 4000;
  var sessionCsrf = null;
  var selectedDispatch = null;
  var lastState = null;
  var pollId = null;

  function el(name) {
    return document.createElement(name);
  }

  function txt(node, value) {
    node.textContent = value == null ? "" : String(value);
    return node;
  }

  function clear(node) {
    while (node.firstChild) {
      node.removeChild(node.firstChild);
    }
  }

  function kv(label, value, className) {
    var row = el("div");
    row.className = "kv";
    var key = el("span");
    txt(key, label);
    var val = el("strong");
    if (className) {
      val.className = className;
    }
    txt(val, value);
    row.appendChild(key);
    row.appendChild(val);
    return row;
  }

  function setStatus(value) {
    var node = document.getElementById("shell-status");
    if (node) {
      txt(node, value);
    }
  }

  function httpUrl(value) {
    if (!value || typeof value !== "string") {
      return null;
    }
    var parsed;
    try {
      parsed = new URL(value);
    } catch (err) {
      return null;
    }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      return null;
    }
    return parsed.href;
  }

  function appendLinkOrText(parent, value) {
    var href = httpUrl(value);
    if (href) {
      var link = el("a");
      link.setAttribute("href", href);
      link.setAttribute("rel", "noopener noreferrer");
      link.setAttribute("target", "_blank");
      txt(link, href);
      parent.appendChild(link);
      return;
    }
    var span = el("span");
    txt(span, value);
    parent.appendChild(span);
  }

  function pickRun(state) {
    var runs = state && state.runs ? state.runs : [];
    var context = state && state.context ? state.context : {};
    if (context.state === "active" && context.run) {
      for (var i = 0; i < runs.length; i += 1) {
        if (runs[i].run_id === context.run) {
          return runs[i];
        }
      }
    }
    for (var j = 0; j < runs.length; j += 1) {
      if (runs[j].status === "active") {
        return runs[j];
      }
    }
    return runs.length ? runs[0] : null;
  }

  function openItems(run) {
    var found = [];
    var items = run && run.dispatches ? run.dispatches : [];
    for (var i = 0; i < items.length; i += 1) {
      if (items[i].state === "open") {
        found.push(items[i]);
      }
    }
    return found;
  }

  function reviewLabel(review) {
    if (!review || review === "not recorded") {
      return "not recorded";
    }
    if (review.verdict) {
      return String(review.verdict);
    }
    return "not recorded";
  }

  function renderEmpty(root) {
    var p = el("p");
    p.className = "empty";
    txt(p, "no runs recorded");
    root.appendChild(p);
  }

  function renderNow(state) {
    var root = document.getElementById("now-root");
    if (!root) {
      return;
    }
    clear(root);
    var journal = state.journal || {};
    var context = state.context || {};
    root.appendChild(kv("Journal", journal.status || "unknown"));
    root.appendChild(kv("Context", context.state || "unknown"));
    var runs = state.runs || [];
    if (!runs.length) {
      renderEmpty(root);
      return;
    }
    var run = pickRun(state);
    if (!run) {
      renderEmpty(root);
      return;
    }
    var checkpoint = run.checkpoint || {};
    var axis = checkpoint.state || "unknown";
    if (checkpoint.age_minutes != null) {
      axis += " · " + String(checkpoint.age_minutes) + " min";
    }
    if (checkpoint.note) {
      axis += " · " + String(checkpoint.note);
    }
    root.appendChild(kv("Checkpoint", axis));
    var open = openItems(run);
    if (!open.length) {
      var none = el("p");
      none.className = "empty";
      txt(none, "No open dispatches.");
      root.appendChild(none);
      return;
    }
    var stillOpen = false;
    for (var i = 0; i < open.length; i += 1) {
      if (open[i].dispatch_id === selectedDispatch) {
        stillOpen = true;
      }
    }
    if (!stillOpen) {
      selectedDispatch = open[0].dispatch_id;
    }
    var heading = el("h3");
    txt(heading, "Open dispatches");
    root.appendChild(heading);
    for (var n = 0; n < open.length; n += 1) {
      renderOpenDispatch(root, open[n]);
    }
    var tailWrap = el("div");
    var tailLabel = el("h3");
    txt(tailLabel, "Transcript tail");
    tailWrap.appendChild(tailLabel);
    var pre = el("pre");
    pre.id = "transcript-tail";
    txt(pre, "");
    tailWrap.appendChild(pre);
    root.appendChild(tailWrap);
    pullTranscript(selectedDispatch);
  }

  function renderOpenDispatch(root, item) {
    var box = el("div");
    box.className = "dispatch";
    var live = item.liveness || {};
    var word = live.state || "unknown";
    var idle = live.idle_minutes != null ? String(live.idle_minutes) + " min idle" : "";
    var source = live.source || "no source path";
    var pick = el("button");
    pick.setAttribute("type", "button");
    pick.className = "pick" + (item.dispatch_id === selectedDispatch ? " is-selected" : "");
    txt(pick, item.dispatch_id);
    pick.addEventListener("click", function () {
      selectedDispatch = item.dispatch_id;
      if (lastState) {
        renderAll(lastState);
      }
    });
    box.appendChild(pick);
    box.appendChild(kv("Liveness", word, "liveness"));
    if (idle) {
      box.appendChild(kv("Idle", idle));
    }
    var pathRow = el("div");
    pathRow.className = "kv";
    var pathKey = el("span");
    txt(pathKey, "Source path");
    var pathVal = el("strong");
    pathVal.className = "path";
    txt(pathVal, source);
    pathRow.appendChild(pathKey);
    pathRow.appendChild(pathVal);
    box.appendChild(pathRow);
    root.appendChild(box);
  }

  function renderPublish(parent, publish) {
    var row = el("div");
    row.className = "kv";
    var key = el("span");
    txt(key, "Publish");
    row.appendChild(key);
    if (!publish || publish === "not recorded") {
      var none = el("strong");
      txt(none, "not recorded");
      row.appendChild(none);
      parent.appendChild(row);
      return;
    }
    var facts = el("span");
    var parts = [];
    if (publish.branch) {
      parts.push("branch " + publish.branch);
    }
    if (publish.sha) {
      parts.push("sha " + publish.sha);
    }
    if (publish.note) {
      parts.push(publish.note);
    }
    if (parts.length) {
      var extra = el("strong");
      txt(extra, parts.join(" · "));
      facts.appendChild(extra);
    }
    if (publish.pr) {
      if (facts.firstChild) {
        facts.appendChild(document.createTextNode(" · "));
      }
      appendLinkOrText(facts, publish.pr);
    }
    if (!facts.firstChild) {
      var empty = el("strong");
      txt(empty, "recorded");
      facts.appendChild(empty);
    }
    row.appendChild(facts);
    parent.appendChild(row);
  }

  function renderGate(parent, gate) {
    var box = el("div");
    box.className = "gate";
    box.appendChild(kv("Policy", gate.policy || "unknown"));
    box.appendChild(kv("Purpose", gate.purpose || "unknown"));
    var bind = el("div");
    bind.className = "kv";
    var bindKey = el("span");
    txt(bindKey, "Binding");
    var badge = el("strong");
    var clean = gate.binding === "clean";
    badge.className = "gate-binding " + (clean ? "is-clean" : "is-other");
    txt(badge, gate.binding || "unknown");
    bind.appendChild(bindKey);
    bind.appendChild(badge);
    box.appendChild(bind);
    var note = el("span");
    note.className = "binding-note";
    txt(
      note,
      clean
        ? "binding=clean is publication evidence"
        : "not publication readiness — binding is not clean"
    );
    box.appendChild(note);
    parent.appendChild(box);
  }

  function renderThisRun(state) {
    var root = document.getElementById("run-root");
    if (!root) {
      return;
    }
    clear(root);
    var runs = state.runs || [];
    if (!runs.length) {
      renderEmpty(root);
      return;
    }
    var run = pickRun(state);
    if (!run) {
      renderEmpty(root);
      return;
    }
    root.appendChild(kv("Run", run.run_id || "unknown"));
    root.appendChild(kv("Status", run.status || "unknown"));
    var units = run.units || [];
    var unitHead = el("h3");
    txt(unitHead, "Units");
    root.appendChild(unitHead);
    if (!units.length) {
      var noUnits = el("p");
      noUnits.className = "empty";
      txt(noUnits, "No units recorded.");
      root.appendChild(noUnits);
    }
    for (var i = 0; i < units.length; i += 1) {
      var unit = units[i];
      var box = el("div");
      box.className = "unit";
      box.appendChild(kv("Unit", unit.unit || "unknown"));
      box.appendChild(kv("Status", unit.status || "unknown"));
      box.appendChild(kv("Rounds", unit.rounds == null ? "0" : String(unit.rounds)));
      box.appendChild(kv("Review", reviewLabel(unit.review)));
      renderPublish(box, unit.publish);
      root.appendChild(box);
    }
    var items = run.dispatches || [];
    var dispHead = el("h3");
    txt(dispHead, "Dispatches");
    root.appendChild(dispHead);
    for (var d = 0; d < items.length; d += 1) {
      var item = items[d];
      var dbox = el("div");
      dbox.className = "dispatch";
      dbox.appendChild(kv("Dispatch", item.dispatch_id || "unknown"));
      dbox.appendChild(kv("Backend", item.backend || "unknown"));
      dbox.appendChild(kv("Mode", item.mode || "unknown"));
      dbox.appendChild(kv("State", item.state || "unknown"));
      if (item.exit != null) {
        dbox.appendChild(kv("Exit", String(item.exit)));
      }
      root.appendChild(dbox);
    }
    var gates = run.gates || [];
    var gateHead = el("h3");
    txt(gateHead, "Gates");
    root.appendChild(gateHead);
    if (!gates.length) {
      var noGates = el("p");
      noGates.className = "empty";
      txt(noGates, "No gates recorded.");
      root.appendChild(noGates);
    }
    for (var g = 0; g < gates.length; g += 1) {
      renderGate(root, gates[g]);
    }
  }

  function renderDials() {
    var root = document.getElementById("dials-root");
    if (!root) {
      return;
    }
    clear(root);
    var p = el("p");
    p.className = "empty";
    txt(
      p,
      "Dials arrive with the calibration store. This version has no controls."
    );
    root.appendChild(p);
  }

  function renderAll(state) {
    lastState = state;
    renderNow(state);
    renderThisRun(state);
    renderDials();
  }

  function apiHeaders() {
    var headers = {};
    if (sessionCsrf) {
      headers["X-Console-CSRF"] = sessionCsrf;
    }
    return headers;
  }

  function pullTranscript(dispatchId) {
    var pre = document.getElementById("transcript-tail");
    if (!pre || !dispatchId) {
      return;
    }
    fetch("/api/transcript?dispatch=" + encodeURIComponent(dispatchId), {
      credentials: "same-origin",
      headers: apiHeaders(),
    })
      .then(function (response) {
        if (!response.ok) {
          txt(pre, "Transcript unavailable.");
          return null;
        }
        return response.json();
      })
      .then(function (payload) {
        if (!payload) {
          return;
        }
        txt(pre, payload.tail == null ? "" : String(payload.tail));
      })
      .catch(function () {
        txt(pre, "Transcript unavailable.");
      });
  }

  function pullState() {
    fetch("/api/state", { credentials: "same-origin", headers: apiHeaders() })
      .then(function (response) {
        if (!response.ok) {
          setStatus("State unavailable.");
          return null;
        }
        return response.json();
      })
      .then(function (state) {
        if (!state) {
          return;
        }
        setStatus("Connected.");
        renderAll(state);
      })
      .catch(function () {
        setStatus("State unavailable.");
      });
  }

  function afterAuth() {
    pullState();
    pollId = setInterval(pullState, POLL_MS);
  }

  function startSession() {
    var raw = window.location.hash;
    history.replaceState(null, "", window.location.pathname + window.location.search);
    var token = raw.charAt(0) === "#" ? raw.slice(1) : raw;
    if (!token) {
      renderDials();
      return;
    }
    fetch("/api/session", {
      method: "POST",
      credentials: "same-origin",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token: token }),
    })
      .then(function (response) {
        if (!response.ok) {
          setStatus("Authentication failed.");
          return null;
        }
        return response.json();
      })
      .then(function (payload) {
        if (!payload) {
          return;
        }
        sessionCsrf = payload.csrf;
        afterAuth();
      })
      .catch(function () {
        setStatus("Authentication failed.");
      });
  }

  startSession();
})();
