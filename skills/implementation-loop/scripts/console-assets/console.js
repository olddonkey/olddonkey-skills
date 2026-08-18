"use strict";

(function () {
  var POLL_MS = 4000;
  var sessionCsrf = null;
  var selectedDispatch = null;
  var lastState = null;
  var lastDials = null;
  var dialsBusy = false;
  var pollId = null;
  var DIAL_ORDER = [
    "backend",
    "stop",
    "cadence",
    "dispatch-mode",
    "gate",
    "on-red",
    "depth",
    "fix-lane",
  ];
  var DIAL_OPTIONS = {
    backend: ["codex", "grok", "cursor-agent"],
    stop: ["worktree", "commit", "pr", "merge"],
    cadence: ["confirm", "continuous"],
    "dispatch-mode": ["implement", "read-only"],
    gate: ["baseline", "strict", "skip"],
    "on-red": ["stop", "iterate"],
    depth: ["light", "standard", "deep"],
    "fix-lane": ["codex", "claude-trivial-ok"],
  };
  var PERMISSION_KEYS = ["stop", "cadence", "fix-lane"];

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

  function isPermissionKey(key) {
    return PERMISSION_KEYS.indexOf(key) !== -1;
  }

  function setControlsDisabled(root, disabled) {
    var nodes = root.querySelectorAll("button, select");
    for (var i = 0; i < nodes.length; i += 1) {
      if (disabled) {
        nodes[i].setAttribute("disabled", "disabled");
      } else {
        nodes[i].removeAttribute("disabled");
      }
    }
  }

  function renderDialRow(parent, key, record, locked) {
    var box = el("div");
    box.className = "dial";
    box.appendChild(kv("Dial", key));
    box.appendChild(kv("Value", record && record.value ? record.value : ""));
    box.appendChild(kv("Scope", record && record.scope ? record.scope : ""));
    box.appendChild(kv("Source", record && record.source ? record.source : ""));
    box.appendChild(kv("Set by", record && record.set_by ? record.set_by : ""));
    box.appendChild(kv("Set at", record && record.set_at ? record.set_at : ""));
    box.appendChild(
      kv("Provenance", record && record.provenance ? record.provenance : "")
    );
    var controls = el("div");
    controls.className = "dial-controls";
    var select = el("select");
    select.setAttribute("data-dial", key);
    var options = DIAL_OPTIONS[key] || [];
    var current = record && record.value ? String(record.value) : options[0];
    for (var i = 0; i < options.length; i += 1) {
      var option = el("option");
      option.setAttribute("value", options[i]);
      txt(option, options[i]);
      if (options[i] === current) {
        option.setAttribute("selected", "selected");
      }
      select.appendChild(option);
    }
    var apply = el("button");
    apply.setAttribute("type", "button");
    apply.className = "dial-apply";
    txt(apply, "Apply");
    apply.addEventListener("click", function () {
      postDial(key, select.value);
    });
    var reset = el("button");
    reset.setAttribute("type", "button");
    reset.className = "dial-reset";
    txt(reset, "Reset to default");
    reset.addEventListener("click", function () {
      resetDial(key);
    });
    controls.appendChild(select);
    controls.appendChild(apply);
    controls.appendChild(reset);
    box.appendChild(controls);
    if (locked) {
      select.setAttribute("disabled", "disabled");
      apply.setAttribute("disabled", "disabled");
      reset.setAttribute("disabled", "disabled");
    }
    parent.appendChild(box);
  }

  function renderDials(doc) {
    var root = document.getElementById("dials-root");
    if (!root) {
      return;
    }
    clear(root);
    if (!doc) {
      var inert = el("p");
      inert.className = "empty";
      txt(inert, "Authenticate to read and set the workspace dials.");
      root.appendChild(inert);
      return;
    }
    lastDials = doc;
    var rejected = doc.store === "rejected";
    var absent = doc.store === "absent";
    if (rejected) {
      var ban = el("p");
      ban.className = "dials-notice is-rejected";
      txt(
        ban,
        "The calibration store was rejected: " +
          (doc.reason ? String(doc.reason) : "unknown reason") +
          ". Repair or remove the store file. Controls are disabled."
      );
      root.appendChild(ban);
    } else if (absent) {
      var notice = el("p");
      notice.className = "dials-notice is-absent";
      txt(
        notice,
        "The calibration store is absent. Safe defaults are in effect; nothing was imported from memory. Confirming a value here records it. Permission dials recorded here are granted via this console."
      );
      root.appendChild(notice);
    }
    if (doc.store) {
      root.appendChild(kv("Store", String(doc.store)));
    }
    var locked = rejected || dialsBusy;
    var permHead = el("h3");
    txt(permHead, "These grant authority");
    root.appendChild(permHead);
    var permNote = el("p");
    permNote.className = "dials-section-note";
    txt(
      permNote,
      "Permission dials. Setting one here grants standing authorization for this workspace."
    );
    root.appendChild(permNote);
    var permBox = el("div");
    permBox.className = "dials-permission";
    var dials = doc.dials || {};
    for (var p = 0; p < PERMISSION_KEYS.length; p += 1) {
      renderDialRow(permBox, PERMISSION_KEYS[p], dials[PERMISSION_KEYS[p]], locked);
    }
    root.appendChild(permBox);
    var polHead = el("h3");
    txt(polHead, "Policy");
    root.appendChild(polHead);
    var polBox = el("div");
    polBox.className = "dials-policy";
    for (var i = 0; i < DIAL_ORDER.length; i += 1) {
      var key = DIAL_ORDER[i];
      if (isPermissionKey(key)) {
        continue;
      }
      renderDialRow(polBox, key, dials[key], locked);
    }
    root.appendChild(polBox);
    var err = el("p");
    err.id = "dials-error";
    err.className = "dials-error";
    txt(err, "");
    root.appendChild(err);
    if (dialsBusy) {
      setControlsDisabled(root, true);
    }
  }

  function setDialError(message) {
    var node = document.getElementById("dials-error");
    if (node) {
      txt(node, message);
    }
  }

  function postDial(key, value) {
    if (dialsBusy) {
      return;
    }
    dialsBusy = true;
    if (lastDials) {
      renderDials(lastDials);
    }
    fetch("/api/dials", {
      method: "POST",
      credentials: "same-origin",
      headers: Object.assign(
        { "content-type": "application/json" },
        apiHeaders()
      ),
      body: JSON.stringify({ key: key, value: value }),
    })
      .then(function (response) {
        return response.json().then(function (payload) {
          return { ok: response.ok, status: response.status, payload: payload };
        });
      })
      .then(function (result) {
        dialsBusy = false;
        if (!result.ok) {
          if (lastDials) {
            renderDials(lastDials);
          }
          setDialError(
            result.payload && result.payload.error
              ? String(result.payload.error)
              : "Dial update failed."
          );
          return;
        }
        renderDials(result.payload);
      })
      .catch(function () {
        dialsBusy = false;
        if (lastDials) {
          renderDials(lastDials);
        }
        setDialError("Dial update failed.");
      });
  }

  function resetDial(key) {
    if (dialsBusy) {
      return;
    }
    dialsBusy = true;
    if (lastDials) {
      renderDials(lastDials);
    }
    fetch("/api/dials/reset", {
      method: "POST",
      credentials: "same-origin",
      headers: Object.assign(
        { "content-type": "application/json" },
        apiHeaders()
      ),
      body: JSON.stringify({ key: key }),
    })
      .then(function (response) {
        return response.json().then(function (payload) {
          return { ok: response.ok, status: response.status, payload: payload };
        });
      })
      .then(function (result) {
        dialsBusy = false;
        if (!result.ok) {
          if (lastDials) {
            renderDials(lastDials);
          }
          setDialError(
            result.payload && result.payload.error
              ? String(result.payload.error)
              : "Dial reset failed."
          );
          return;
        }
        renderDials(result.payload);
      })
      .catch(function () {
        dialsBusy = false;
        if (lastDials) {
          renderDials(lastDials);
        }
        setDialError("Dial reset failed.");
      });
  }

  function pullDials() {
    fetch("/api/dials", { credentials: "same-origin", headers: apiHeaders() })
      .then(function (response) {
        if (!response.ok) {
          return null;
        }
        return response.json();
      })
      .then(function (doc) {
        if (!doc) {
          return;
        }
        renderDials(doc);
      })
      .catch(function () {
        return;
      });
  }

  function renderAll(state) {
    lastState = state;
    renderNow(state);
    renderThisRun(state);
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
    pullDials();
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
