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

  function wordVariant(word) {
    var w = String(word || "unknown");
    if (
      w === "recent activity" ||
      w === "ok" ||
      w === "active" ||
      w === "done" ||
      w === "completed" ||
      w === "fresh" ||
      w === "clean"
    ) {
      return "ok";
    }
    if (
      w === "idle" ||
      w === "stale" ||
      w === "dirty" ||
      w === "changed" ||
      w === "parked" ||
      w === "missing"
    ) {
      return "caution";
    }
    if (
      w === "suspected stall" ||
      w === "unavailable" ||
      w === "failed" ||
      w === "abandoned" ||
      w === "degraded" ||
      w === "rejected"
    ) {
      return "danger";
    }
    return "neutral";
  }

  function livenessVariant(word) {
    if (word === "recent activity") {
      return "ok";
    }
    if (word === "idle") {
      return "caution";
    }
    if (word === "suspected stall") {
      return "danger";
    }
    return "neutral";
  }

  function bindingVariant(binding) {
    if (binding === "clean") {
      return "ok";
    }
    if (binding === "dirty" || binding === "changed") {
      return "caution";
    }
    return "danger";
  }

  function chip(label, variant, filled) {
    var node = el("span");
    node.className =
      "chip is-" + (variant || "neutral") + (filled ? " is-filled" : "");
    txt(node, label);
    return node;
  }

  function pad2(value) {
    var text = String(value);
    return text.length < 2 ? "0" + text : text;
  }

  function stampUpdated() {
    var node = document.getElementById("updated-at");
    if (!node) {
      return;
    }
    var now = new Date();
    txt(
      node,
      "Updated " +
        pad2(now.getHours()) +
        ":" +
        pad2(now.getMinutes()) +
        ":" +
        pad2(now.getSeconds())
    );
  }

  function bindLiveRegions() {
    var status = document.getElementById("shell-status");
    if (status) {
      status.setAttribute("role", "status");
    }
    var err = document.getElementById("dials-error");
    if (err) {
      err.setAttribute("role", "status");
    }
  }

  function setStatus(value) {
    var node = document.getElementById("shell-status");
    if (!node) {
      return;
    }
    txt(node, value);
    var variant = "neutral";
    if (value === "Connected.") {
      variant = "ok";
    } else if (value === "State unavailable." || value === "Authentication failed.") {
      variant = "danger";
    }
    node.className = "chip is-" + variant;
    node.setAttribute("role", "status");
  }

  function parseHttpUrl(value) {
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
    return parsed;
  }

  function linkLabel(parsed) {
    var parts = [];
    var segs = String(parsed.pathname || "").split("/");
    var i;
    for (i = 0; i < segs.length; i += 1) {
      if (segs[i]) {
        parts.push(segs[i]);
      }
    }
    var tail = parts.slice(-2).join("/");
    if (tail) {
      return parsed.host + " · " + tail;
    }
    return parsed.host;
  }

  function appendLinkOrText(parent, value) {
    var parsed = parseHttpUrl(value);
    if (parsed) {
      var href = parsed.href;
      var link = el("a");
      link.setAttribute("href", href);
      link.setAttribute("rel", "noopener noreferrer");
      link.setAttribute("target", "_blank");
      link.setAttribute("title", href);
      txt(link, linkLabel(parsed));
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
    var box = el("div");
    box.className = "empty";
    var title = el("p");
    title.className = "empty-title";
    txt(title, "No runs recorded yet");
    var hint = el("p");
    hint.className = "empty-hint";
    hint.appendChild(document.createTextNode("Start one with "));
    var cmd = el("code");
    txt(cmd, "loop-run begin");
    hint.appendChild(cmd);
    hint.appendChild(document.createTextNode("."));
    box.appendChild(title);
    box.appendChild(hint);
    root.appendChild(box);
  }

  function tile(label, value, qualifier, variant) {
    var card = el("div");
    card.className = "card tile";
    var eye = el("p");
    eye.className = "eyebrow";
    txt(eye, label);
    var val = el("p");
    val.className = "tile-value tabular is-" + (variant || "neutral");
    txt(val, value);
    card.appendChild(eye);
    card.appendChild(val);
    if (qualifier) {
      var q = el("p");
      q.className = "tile-qualifier";
      q.setAttribute("title", qualifier);
      txt(q, qualifier);
      card.appendChild(q);
    }
    return card;
  }

  function renderVitals(state) {
    var root = document.getElementById("vitals-root");
    if (!root) {
      return;
    }
    clear(root);
    var grid = el("div");
    grid.className = "vitals";
    var journal = state.journal || {};
    var jstatus = journal.status || "unknown";
    grid.appendChild(tile("Journal", jstatus, "", wordVariant(jstatus)));
    var context = state.context || {};
    var cstate = context.state || "unknown";
    var cqual = context.run ? String(context.run) : "No active run";
    grid.appendChild(tile("Context", cstate, cqual, wordVariant(cstate)));
    var run = pickRun(state);
    var checkpoint = run && run.checkpoint ? run.checkpoint : { state: "unknown" };
    var axis = checkpoint.state || "unknown";
    var quals = [];
    if (checkpoint.age_minutes != null) {
      quals.push(String(checkpoint.age_minutes) + " min");
    }
    if (checkpoint.note) {
      quals.push(String(checkpoint.note));
    }
    grid.appendChild(tile("Checkpoint", axis, quals.join(" · "), wordVariant(axis)));
    var openCount = run ? openItems(run).length : 0;
    grid.appendChild(
      tile(
        "Open dispatches",
        String(openCount),
        run ? "In this run" : "No run selected",
        openCount ? "ok" : "neutral"
      )
    );
    root.appendChild(grid);
  }

  function renderNow(state) {
    var root = document.getElementById("now-root");
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
    var open = openItems(run);
    if (!open.length) {
      var none = el("p");
      none.className = "empty-hint";
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
    var grid = el("div");
    grid.className = "card-grid";
    for (var n = 0; n < open.length; n += 1) {
      renderOpenDispatch(grid, open[n]);
    }
    root.appendChild(grid);
    var panel = el("section");
    panel.className = "card transcript-panel";
    var head = el("div");
    head.className = "transcript-head";
    var heading = el("h3");
    txt(heading, "Transcript");
    var ident = el("p");
    ident.className = "mono";
    txt(ident, selectedDispatch || "");
    head.appendChild(heading);
    head.appendChild(ident);
    var pre = el("pre");
    pre.id = "transcript-tail";
    txt(pre, "");
    panel.appendChild(head);
    panel.appendChild(pre);
    root.appendChild(panel);
    pullTranscript(selectedDispatch);
  }

  function renderOpenDispatch(root, item) {
    var live = item.liveness || {};
    var word = live.state || "unknown";
    var pick = el("button");
    pick.setAttribute("type", "button");
    var selected = item.dispatch_id === selectedDispatch;
    pick.className =
      "card dispatch-card pick" + (selected ? " is-selected" : "");
    pick.setAttribute("aria-pressed", selected ? "true" : "false");
    pick.addEventListener("click", function () {
      selectedDispatch = item.dispatch_id;
      if (lastState) {
        renderAll(lastState);
      }
    });
    var title = el("h3");
    title.className = "mono dispatch-id";
    txt(title, item.dispatch_id);
    pick.appendChild(title);
    pick.appendChild(chip(word, livenessVariant(word)));
    var meta = el("p");
    meta.className = "meta";
    txt(meta, (item.backend || "unknown") + " · " + (item.mode || "unknown"));
    pick.appendChild(meta);
    if (live.idle_minutes != null) {
      var idle = el("p");
      idle.className = "meta tabular";
      txt(idle, String(live.idle_minutes) + " min idle");
      pick.appendChild(idle);
    }
    var path = el("p");
    path.className = "path";
    var source = live.source || "no source path";
    path.setAttribute("title", source);
    txt(path, source);
    pick.appendChild(path);
    root.appendChild(pick);
  }

  function renderPublish(parent, publish) {
    var row = el("div");
    row.className = "publish";
    var key = el("span");
    key.className = "muted-label";
    txt(key, "Publish");
    row.appendChild(key);
    if (!publish || publish === "not recorded") {
      var none = el("p");
      none.className = "meta";
      txt(none, "not recorded");
      row.appendChild(none);
      parent.appendChild(row);
      return;
    }
    var facts = el("p");
    facts.className = "meta";
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
      var extra = el("span");
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
      var empty = el("span");
      txt(empty, "recorded");
      facts.appendChild(empty);
    }
    row.appendChild(facts);
    parent.appendChild(row);
  }

  function renderGate(parent, gate) {
    var box = el("div");
    box.className = "gate";
    var binding = gate.binding || "unknown";
    var clean = binding === "clean";
    var badge = chip(binding, bindingVariant(binding), clean);
    badge.className += " gate-binding";
    box.appendChild(badge);
    var meta = el("p");
    meta.className = "meta";
    txt(
      meta,
      (gate.policy || "unknown") + " · " + (gate.purpose || "unknown")
    );
    box.appendChild(meta);
    var note = el("span");
    note.className = "binding-note";
    txt(note, clean ? "Publication evidence" : "Not publication evidence");
    box.appendChild(note);
    parent.appendChild(box);
  }

  function appendCell(row, value, className) {
    var cell = el("td");
    if (className) {
      cell.className = className;
    }
    txt(cell, value);
    row.appendChild(cell);
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
    var head = el("div");
    head.className = "run-head";
    var rid = el("p");
    rid.className = "mono run-id";
    txt(rid, run.run_id || "unknown");
    head.appendChild(rid);
    head.appendChild(chip(run.status || "unknown", wordVariant(run.status)));
    root.appendChild(head);
    var units = run.units || [];
    var unitHead = el("h3");
    txt(unitHead, "Units");
    root.appendChild(unitHead);
    if (!units.length) {
      var noUnits = el("p");
      noUnits.className = "empty-hint";
      txt(noUnits, "No units recorded.");
      root.appendChild(noUnits);
    } else {
      var unitGrid = el("div");
      unitGrid.className = "card-grid";
      for (var i = 0; i < units.length; i += 1) {
        var unit = units[i];
        var box = el("div");
        box.className = "card unit";
        var name = el("h3");
        txt(name, unit.unit || "unknown");
        box.appendChild(name);
        box.appendChild(chip(unit.status || "unknown", wordVariant(unit.status)));
        var rounds = el("p");
        rounds.className = "meta";
        var rlabel = el("span");
        txt(rlabel, "Rounds ");
        var rval = el("span");
        rval.className = "tabular";
        txt(rval, unit.rounds == null ? "0" : String(unit.rounds));
        rounds.appendChild(rlabel);
        rounds.appendChild(rval);
        box.appendChild(rounds);
        var review = el("p");
        review.className = "meta";
        txt(review, "Review " + reviewLabel(unit.review));
        box.appendChild(review);
        renderPublish(box, unit.publish);
        unitGrid.appendChild(box);
      }
      root.appendChild(unitGrid);
    }
    var items = run.dispatches || [];
    var dispHead = el("h3");
    txt(dispHead, "Dispatches");
    root.appendChild(dispHead);
    if (!items.length) {
      var noDisp = el("p");
      noDisp.className = "empty-hint";
      txt(noDisp, "No dispatches recorded.");
      root.appendChild(noDisp);
    } else {
      var wrap = el("div");
      wrap.className = "table-wrap";
      var table = el("table");
      table.className = "records";
      var thead = el("thead");
      var headerRow = el("tr");
      var cols = ["Id", "Backend", "Mode", "State", "Exit"];
      for (var c = 0; c < cols.length; c += 1) {
        var th = el("th");
        th.setAttribute("scope", "col");
        txt(th, cols[c]);
        headerRow.appendChild(th);
      }
      thead.appendChild(headerRow);
      table.appendChild(thead);
      var tbody = el("tbody");
      for (var d = 0; d < items.length; d += 1) {
        var item = items[d];
        var tr = el("tr");
        appendCell(tr, item.dispatch_id || "unknown", "mono");
        appendCell(tr, item.backend || "unknown", "");
        appendCell(tr, item.mode || "unknown", "");
        appendCell(tr, item.state || "unknown", "");
        appendCell(
          tr,
          item.exit == null ? "" : String(item.exit),
          "tabular"
        );
        tbody.appendChild(tr);
      }
      table.appendChild(tbody);
      wrap.appendChild(table);
      root.appendChild(wrap);
    }
    var gates = run.gates || [];
    var gateHead = el("h3");
    txt(gateHead, "Gates");
    root.appendChild(gateHead);
    if (!gates.length) {
      var noGates = el("p");
      noGates.className = "empty-hint";
      txt(noGates, "No gates recorded.");
      root.appendChild(noGates);
    } else {
      var gateRow = el("div");
      gateRow.className = "gate-row";
      for (var g = 0; g < gates.length; g += 1) {
        renderGate(gateRow, gates[g]);
      }
      root.appendChild(gateRow);
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
    box.className = "card dial";
    var selectId = "dial-select-" + key;
    var head = el("div");
    head.className = "dial-head";
    var label = el("label");
    label.setAttribute("for", selectId);
    label.className = "dial-name";
    txt(label, key);
    head.appendChild(label);
    if (record && record.scope === "permission") {
      head.appendChild(chip("grants authority", "caution"));
    }
    box.appendChild(head);
    var value = el("p");
    value.className = "dial-value mono";
    txt(value, record && record.value ? record.value : "");
    box.appendChild(value);
    var meta = el("p");
    meta.className = "meta dial-meta";
    var bits = [];
    if (record && record.scope) {
      bits.push(record.scope);
    }
    if (record && record.source) {
      bits.push(record.source);
    }
    if (record && record.set_by) {
      bits.push(record.set_by);
    }
    if (record && record.set_at) {
      bits.push(record.set_at);
    }
    if (record && record.provenance) {
      bits.push(record.provenance);
    }
    txt(meta, bits.join(" · "));
    box.appendChild(meta);
    var controls = el("div");
    controls.className = "dial-controls";
    var select = el("select");
    select.setAttribute("id", selectId);
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
    bindLiveRegions();
    if (!doc) {
      var inert = el("p");
      inert.className = "empty-hint";
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
      var store = el("p");
      store.className = "meta";
      txt(store, "Store " + String(doc.store));
      root.appendChild(store);
    }
    var locked = rejected || dialsBusy;
    var permBox = el("div");
    permBox.className = "dials-permission";
    var permHead = el("h3");
    txt(permHead, "Permission dials");
    permBox.appendChild(permHead);
    var permNote = el("p");
    permNote.className = "dials-section-note";
    txt(
      permNote,
      "These dials grant standing authorization when set beyond their default. At their default value they carry no authority."
    );
    permBox.appendChild(permNote);
    var permList = el("div");
    permList.className = "dial-list";
    var dials = doc.dials || {};
    for (var p = 0; p < PERMISSION_KEYS.length; p += 1) {
      renderDialRow(permList, PERMISSION_KEYS[p], dials[PERMISSION_KEYS[p]], locked);
    }
    permBox.appendChild(permList);
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
    if (dialsBusy) {
      setControlsDisabled(root, true);
    }
  }

  function setDialError(message) {
    var node = document.getElementById("dials-error");
    if (node) {
      node.setAttribute("role", "status");
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
    renderVitals(state);
    renderNow(state);
    renderThisRun(state);
    stampUpdated();
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

  bindLiveRegions();
  startSession();
})();
