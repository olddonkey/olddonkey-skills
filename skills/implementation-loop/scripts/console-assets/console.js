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
  var SVG_ALLOW = {
    ns: "http://www.w3.org/2000/svg",
    tags: ["svg", "g", "path", "circle", "rect", "line", "text", "title", "desc"],
    attrs: [
      "viewBox",
      "d",
      "cx",
      "cy",
      "r",
      "x",
      "y",
      "x1",
      "y1",
      "x2",
      "y2",
      "width",
      "height",
      "rx",
      "class",
      "role",
      "aria-label",
      "aria-hidden",
      "focusable",
      "text-anchor",
    ],
    refused: /url\s*\(|java[\s\x00-\x1f]*script[\s\x00-\x1f]*:|</i,
  };
  var FLOW = {
    backends: ["codex", "cursor", "grok"],
    unknown: "unknown",
    owned: [
      "dispatch.start",
      "dispatch.end",
      "dispatch.abandoned",
      "gate.result",
      "review.recorded",
      "publish.recorded",
    ],
    sinks: [
      ["review", "Review"],
      ["gate", "Gate"],
      ["publish", "Publication"],
    ],
    packets: 20,
    recent: 10,
    width: 900,
    height: 304,
    row: 96,
    pad: 12,
    nodeW: 132,
    nodeH: 40,
    left: 86,
    center: 450,
    right: 814,
  };

  function el(name) {
    return document.createElement(name);
  }

  function txt(node, value) {
    var next = value == null ? "" : String(value);
    var child = node.firstChild;
    if (child && child.nodeType === 3 && !child.nextSibling) {
      if (child.nodeValue !== next) {
        child.nodeValue = next;
      }
      return node;
    }
    if (node.textContent !== next) {
      node.textContent = next;
    }
    return node;
  }

  function setClass(node, value) {
    if (node.className !== value) {
      node.className = value;
    }
  }

  function setAttr(node, name, value) {
    var next = String(value);
    if (node.getAttribute(name) !== next) {
      node.setAttribute(name, next);
    }
  }

  function svgEl(tag) {
    if (typeof tag !== "string" || SVG_ALLOW.tags.indexOf(tag) === -1) {
      throw new Error("svg tag refused");
    }
    return document.createElementNS(SVG_ALLOW.ns, tag);
  }

  function svgAttr(node, name, value) {
    if (typeof name !== "string" || SVG_ALLOW.attrs.indexOf(name) === -1) {
      throw new Error("svg attribute refused");
    }
    var next = String(value);
    if (SVG_ALLOW.refused.test(next)) {
      throw new Error("svg attribute value refused");
    }
    if (node.getAttribute(name) !== next) {
      node.setAttribute(name, next);
    }
    return node;
  }

  function wipe(node) {
    while (node.firstChild) {
      node.removeChild(node.firstChild);
    }
    node._byId = null;
    node._mode = null;
    node._parts = null;
    node._tbody = null;
    node._grid = null;
  }

  function keyedMap(parent) {
    if (!parent._byId) {
      parent._byId = {};
    }
    return parent._byId;
  }

  function itemById(parent, id) {
    var map = parent._byId;
    if (!map) {
      return null;
    }
    return Object.prototype.hasOwnProperty.call(map, id) ? map[id] : null;
  }

  function syncKeyed(parent, items, idOf, create, update) {
    var map = keyedMap(parent);
    var seen = {};
    var i;
    var id;
    var node;
    var want;
    for (i = 0; i < items.length; i += 1) {
      id = idOf(items[i], i);
      seen[id] = true;
      node = itemById(parent, id);
      if (!node) {
        node = create(items[i], i);
        map[id] = node;
      } else {
        update(node, items[i], i);
      }
      want = i < parent.children.length ? parent.children[i] : null;
      if (want !== node) {
        parent.insertBefore(node, want);
      }
    }
    var keys = Object.keys(map);
    for (i = 0; i < keys.length; i += 1) {
      id = keys[i];
      if (!seen[id]) {
        node = map[id];
        if (node.parentNode === parent) {
          parent.removeChild(node);
        }
        delete map[id];
      }
    }
  }

  function pathBasename(path) {
    var text = String(path || "");
    var idx = text.lastIndexOf("/");
    if (idx === -1) {
      return text;
    }
    return text.slice(idx + 1);
  }

  function transcriptHeadingText(path) {
    var base = pathBasename(path);
    if (!base) {
      return "Transcript";
    }
    return "Transcript · " + base;
  }

  function setChip(node, label, variant, filled, extra) {
    var next =
      "chip is-" +
      (variant || "neutral") +
      (filled ? " is-filled" : "") +
      (extra ? " " + extra : "");
    setClass(node, next);
    txt(node, label);
    return node;
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
      if (status.getAttribute("role") !== "status") {
        status.setAttribute("role", "status");
      }
    }
    var err = document.getElementById("dials-error");
    if (err) {
      if (err.getAttribute("role") !== "status") {
        err.setAttribute("role", "status");
      }
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
    setClass(node, "chip is-" + variant);
    if (node.getAttribute("role") !== "status") {
      node.setAttribute("role", "status");
    }
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

  function showEmpty(root) {
    if (root._mode === "empty") {
      return;
    }
    wipe(root);
    root._mode = "empty";
    renderEmpty(root);
  }

  function showHint(body, message) {
    if (body._mode === "hint" && body.firstChild) {
      txt(body.firstChild, message);
      return;
    }
    wipe(body);
    body._mode = "hint";
    setClass(body, "");
    var none = el("p");
    none.className = "empty-hint";
    txt(none, message);
    body.appendChild(none);
  }

  function ensureHost(body, mode, className) {
    if (body._mode === mode && body.parentNode) {
      if (body.className !== className) {
        setClass(body, className);
      }
      return body;
    }
    wipe(body);
    body._mode = mode;
    setClass(body, className);
    return body;
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
    card._value = val;
    card._qualifier = null;
    if (qualifier) {
      var q = el("p");
      q.className = "tile-qualifier";
      q.setAttribute("title", qualifier);
      txt(q, qualifier);
      card.appendChild(q);
      card._qualifier = q;
    }
    return card;
  }

  function ensureTile(grid, id, label) {
    var map = keyedMap(grid);
    var card = itemById(grid, id);
    if (card) {
      return card;
    }
    card = tile(label, "", "", "neutral");
    map[id] = card;
    grid.appendChild(card);
    return card;
  }

  function updateTile(card, value, qualifier, variant) {
    var val = card._value;
    setClass(val, "tile-value tabular is-" + (variant || "neutral"));
    txt(val, value);
    var q = card._qualifier;
    if (qualifier) {
      if (!q) {
        q = el("p");
        q.className = "tile-qualifier";
        card.appendChild(q);
        card._qualifier = q;
      }
      if (q.getAttribute("title") !== qualifier) {
        q.setAttribute("title", qualifier);
      }
      txt(q, qualifier);
    } else if (q) {
      card.removeChild(q);
      card._qualifier = null;
    }
  }

  function renderVitals(state) {
    var root = document.getElementById("vitals-root");
    if (!root) {
      return;
    }
    var grid;
    if (root._mode !== "vitals") {
      wipe(root);
      root._mode = "vitals";
      grid = el("div");
      grid.className = "vitals";
      root.appendChild(grid);
      root._grid = grid;
      ensureTile(grid, "journal", "Journal");
      ensureTile(grid, "context", "Context");
      ensureTile(grid, "checkpoint", "Checkpoint");
      ensureTile(grid, "open", "Open dispatches");
    } else {
      grid = root._grid;
    }
    var journal = state.journal || {};
    var jstatus = journal.status || "unknown";
    updateTile(
      itemById(grid, "journal"),
      jstatus,
      "",
      wordVariant(jstatus)
    );
    var context = state.context || {};
    var cstate = context.state || "unknown";
    var cqual = context.run ? String(context.run) : "No active run";
    updateTile(itemById(grid, "context"), cstate, cqual, wordVariant(cstate));
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
    updateTile(
      itemById(grid, "checkpoint"),
      axis,
      quals.join(" · "),
      wordVariant(axis)
    );
    var openCount = run ? openItems(run).length : 0;
    updateTile(
      itemById(grid, "open"),
      String(openCount),
      run ? "In this run" : "No run selected",
      openCount ? "ok" : "neutral"
    );
  }

  function ensureNowSkeleton(root) {
    if (root._mode === "now") {
      return root._parts;
    }
    wipe(root);
    root._mode = "now";
    var parts = {};
    parts.grid = el("div");
    parts.grid.className = "card-grid";
    root.appendChild(parts.grid);
    parts.panel = el("section");
    parts.panel.className = "card transcript-panel";
    parts.head = el("div");
    parts.head.className = "transcript-head";
    parts.heading = el("h3");
    parts.heading.id = "transcript-heading";
    txt(parts.heading, "Transcript");
    parts.ident = el("p");
    parts.ident.className = "mono";
    parts.head.appendChild(parts.heading);
    parts.head.appendChild(parts.ident);
    parts.pre = el("pre");
    parts.pre.id = "transcript-tail";
    txt(parts.pre, "");
    parts.panel.appendChild(parts.head);
    parts.panel.appendChild(parts.pre);
    root.appendChild(parts.panel);
    root._parts = parts;
    return parts;
  }

  function createOpenDispatch(item) {
    var pick = el("button");
    pick.setAttribute("type", "button");
    pick.setAttribute("data-dispatch-id", item.dispatch_id);
    pick.addEventListener("click", function () {
      selectedDispatch = pick.getAttribute("data-dispatch-id");
      if (lastState) {
        renderAll(lastState);
      }
    });
    var title = el("h3");
    title.className = "mono dispatch-id";
    pick.appendChild(title);
    var liveChip = chip("unknown", "neutral");
    pick.appendChild(liveChip);
    var meta = el("p");
    meta.className = "meta";
    pick.appendChild(meta);
    var path = el("p");
    path.className = "path";
    pick.appendChild(path);
    pick._title = title;
    pick._chip = liveChip;
    pick._meta = meta;
    pick._idle = null;
    pick._path = path;
    updateOpenDispatch(pick, item);
    return pick;
  }

  function updateOpenDispatch(pick, item) {
    var live = item.liveness || {};
    var word = live.state || "unknown";
    var selected = item.dispatch_id === selectedDispatch;
    setClass(
      pick,
      "card dispatch-card pick" + (selected ? " is-selected" : "")
    );
    setAttr(pick, "aria-pressed", selected ? "true" : "false");
    txt(pick._title, item.dispatch_id);
    setChip(pick._chip, word, livenessVariant(word));
    txt(
      pick._meta,
      (item.backend || "unknown") + " · " + (item.mode || "unknown")
    );
    if (live.idle_minutes != null) {
      if (!pick._idle) {
        pick._idle = el("p");
        pick._idle.className = "meta tabular";
        pick.insertBefore(pick._idle, pick._path);
      }
      txt(pick._idle, String(live.idle_minutes) + " min idle");
    } else if (pick._idle) {
      pick.removeChild(pick._idle);
      pick._idle = null;
    }
    var source = live.source || "no source path";
    setAttr(pick._path, "title", source);
    txt(pick._path, source);
  }

  function renderNow(state) {
    var root = document.getElementById("now-root");
    if (!root) {
      return;
    }
    var runs = state.runs || [];
    if (!runs.length) {
      showEmpty(root);
      return;
    }
    var run = pickRun(state);
    if (!run) {
      showEmpty(root);
      return;
    }
    var open = openItems(run);
    if (!open.length) {
      showHint(root, "No open dispatches.");
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
    var parts = ensureNowSkeleton(root);
    syncKeyed(
      parts.grid,
      open,
      function (item) {
        return item.dispatch_id;
      },
      createOpenDispatch,
      updateOpenDispatch
    );
    txt(parts.ident, selectedDispatch || "");
    pullTranscript(selectedDispatch);
  }

  function flowOwn(obj, key) {
    if (!obj || typeof obj !== "object") {
      return null;
    }
    return Object.prototype.hasOwnProperty.call(obj, key) ? obj[key] : null;
  }

  function flowNum(value) {
    if (typeof value !== "number" || !isFinite(value) || value < 0) {
      return 0;
    }
    return Math.floor(value);
  }

  function flowSeq(item) {
    if (!item || typeof item.seq !== "number" || !isFinite(item.seq)) {
      return -1;
    }
    return item.seq;
  }

  function flowKey(item) {
    return item.key;
  }

  function flowReady(run) {
    var counts = run.counts;
    return (
      !!counts &&
      typeof counts === "object" &&
      !!counts.all &&
      typeof counts.all === "object" &&
      Array.isArray(run.timeline)
    );
  }

  function flowReducedMotion() {
    if (typeof matchMedia !== "function") {
      return false;
    }
    var query = matchMedia("(prefers-reduced-motion: reduce)");
    return !!(query && query.matches);
  }

  function flowMemory(root) {
    if (!root._flow) {
      root._flow = {
        marks: {},
        run: null,
        filter: "all",
        tokens: {},
        names: {},
        serial: 0,
        state: null,
      };
    }
    return root._flow;
  }

  function flowToken(flow, key) {
    if (key === "all") {
      return "all";
    }
    if (key === "none") {
      return "unattributed";
    }
    if (!Object.prototype.hasOwnProperty.call(flow.tokens, key)) {
      flow.serial += 1;
      flow.tokens[key] = "unit-" + flow.serial;
      flow.names[flow.tokens[key]] = key;
    }
    return flow.tokens[key];
  }

  function flowFilterFor(flow, token) {
    if (token === "unattributed") {
      return "none";
    }
    var key = flowOwn(flow.names, token);
    return key || "all";
  }

  function flowUnits(counts) {
    var names = [];
    var units = counts.units;
    if (!units || typeof units !== "object") {
      return names;
    }
    var keys = Object.keys(units);
    for (var i = 0; i < keys.length; i += 1) {
      if (keys[i]) {
        names.push(keys[i]);
      }
    }
    return names;
  }

  function flowBackends(all, picked) {
    var dispatches = flowOwn(all, "dispatches");
    var found = [];
    for (var i = 0; i < FLOW.backends.length; i += 1) {
      if (flowOwn(dispatches, FLOW.backends[i])) {
        found.push(FLOW.backends[i]);
      }
    }
    // loop-index files a dispatch with no usable start under "unknown". It
    // gets a node only while the shown counts hold one, and never a packet.
    if (flowOwn(flowOwn(picked, "dispatches"), FLOW.unknown)) {
      found.push(FLOW.unknown);
    }
    return found;
  }

  function flowBackendName(backend) {
    return backend === FLOW.unknown ? "unknown backend" : backend;
  }

  function flowCounts(counts, filter) {
    if (filter === "none") {
      return flowOwn(counts, "unattributed") || {};
    }
    if (filter.indexOf("u:") === 0) {
      return flowOwn(counts.units, filter.slice(2)) || {};
    }
    return counts.all;
  }

  function flowParts(pairs, empty) {
    var shown = [];
    for (var i = 0; i < pairs.length; i += 1) {
      if (pairs[i][0] > 0) {
        shown.push(pairs[i][0] + " " + pairs[i][1]);
      }
    }
    return shown.length ? shown.join(" · ") : empty;
  }

  function flowEdgeLabel(edge, picked, partial) {
    var text;
    if (edge.backend) {
      var byBackend = flowOwn(flowOwn(picked, "dispatches"), edge.backend);
      text = flowParts(
        [
          [flowNum(flowOwn(byBackend, "ok")), "exit 0"],
          [flowNum(flowOwn(byBackend, "failed")), "failed"],
          [flowNum(flowOwn(byBackend, "open")), "open"],
          [flowNum(flowOwn(byBackend, "abandoned")), "abandoned"],
        ],
        "0 dispatches"
      );
    } else if (edge.key === "review") {
      var reviews = flowOwn(picked, "reviews");
      text = flowParts(
        [
          [flowNum(flowOwn(reviews, "pass")), "pass"],
          [flowNum(flowOwn(reviews, "iterate")), "iterate"],
        ],
        "0 reviews"
      );
    } else if (edge.key === "gate") {
      var gates = flowOwn(picked, "gates");
      text = flowParts(
        [
          [flowNum(flowOwn(gates, "green")), "green"],
          [flowNum(flowOwn(gates, "red")), "red"],
          [flowNum(flowOwn(gates, "unknown")), "unknown"],
        ],
        "0 gates"
      );
    } else {
      var published = flowNum(flowOwn(picked, "publishes"));
      text = published === 1 ? "1 publication" : published + " publications";
    }
    return partial ? "partial: " + text : text;
  }

  function flowAriaLabel(picked, backends, partial) {
    // The unknown-backend lane is not an implementer; name it on its own.
    var orphans = backends.indexOf(FLOW.unknown) !== -1;
    var implementers = backends.length - (orphans ? 1 : 0);
    var dispatches = 0;
    var byBackend = flowOwn(picked, "dispatches");
    var keys = byBackend && typeof byBackend === "object" ? Object.keys(byBackend) : [];
    var outcomes = ["ok", "failed", "open", "abandoned"];
    for (var i = 0; i < keys.length; i += 1) {
      for (var j = 0; j < outcomes.length; j += 1) {
        dispatches += flowNum(flowOwn(byBackend[keys[i]], outcomes[j]));
      }
    }
    var reviews = flowOwn(picked, "reviews");
    var gates = flowOwn(picked, "gates");
    return (
      "Loop flow of recorded events, not verified: Judge, " +
      implementers +
      (implementers === 1 ? " implementer, " : " implementers, ") +
      (orphans ? "plus dispatches with an unknown backend, " : "") +
      dispatches +
      " dispatches, " +
      (flowNum(flowOwn(reviews, "pass")) + flowNum(flowOwn(reviews, "iterate"))) +
      " reviews, " +
      (flowNum(flowOwn(gates, "green")) +
        flowNum(flowOwn(gates, "red")) +
        flowNum(flowOwn(gates, "unknown"))) +
      " gates, " +
      flowNum(flowOwn(picked, "publishes")) +
      " publications" +
      (partial ? ", counts partial." : ".")
    );
  }

  function flowRoute(item) {
    var kind = item && item.event;
    if (
      kind === "dispatch.start" ||
      kind === "dispatch.end" ||
      kind === "dispatch.abandoned"
    ) {
      var at = FLOW.backends.indexOf(item.backend);
      if (at === -1) {
        return null;
      }
      return {
        edge: "impl-" + FLOW.backends[at],
        far: FLOW.backends[at],
        back: kind !== "dispatch.start",
      };
    }
    if (kind === "review.recorded") {
      return { edge: "review", far: "Review", back: false };
    }
    if (kind === "gate.result") {
      return { edge: "gate", far: "Gate", back: false };
    }
    if (kind === "publish.recorded") {
      return { edge: "publish", far: "Publication", back: false };
    }
    return null;
  }

  function flowVariant(item) {
    var kind = item.event;
    if (kind === "dispatch.end") {
      return typeof item.exit === "number" && item.exit !== 0 ? "danger" : "neutral";
    }
    if (kind === "dispatch.abandoned") {
      return "danger";
    }
    if (kind === "review.recorded") {
      return item.review_verdict === "iterate" ? "caution" : "neutral";
    }
    if (kind === "gate.result") {
      return item.gate_verdict === "red" ? "danger" : "neutral";
    }
    return "neutral";
  }

  function flowOwner(item) {
    if (
      item.attribution === "declared" &&
      typeof item.unit === "string" &&
      item.unit
    ) {
      return "u:" + item.unit;
    }
    return "none";
  }

  function flowMatches(filter, item) {
    if (filter === "all") {
      return true;
    }
    // run.*, unit.*, round.begin, checkpoint, and journal.repaired carry no
    // unit in the timeline, so they show under All and nowhere else.
    return FLOW.owned.indexOf(item.event) !== -1 && filter === flowOwner(item);
  }

  function flowEventText(item) {
    var kind = typeof item.event === "string" ? item.event : "unknown event";
    var head = (flowSeq(item) >= 0 ? "#" + item.seq + " " : "") + kind;
    if (FLOW.owned.indexOf(kind) === -1) {
      return head;
    }
    // Only a dispatch with no usable backend has no route.
    var route = flowRoute(item) || {
      far: flowBackendName(FLOW.unknown),
      back: kind !== "dispatch.start",
    };
    var bits = [
      head + ": " + (route.back ? route.far + " → Judge" : "Judge → " + route.far),
    ];
    if (item.event === "dispatch.end") {
      bits.push(typeof item.exit === "number" ? "exit " + item.exit : "exit unknown");
    } else if (item.event === "review.recorded") {
      bits.push(
        item.review_verdict === "pass" || item.review_verdict === "iterate"
          ? item.review_verdict
          : "verdict unknown"
      );
    } else if (item.event === "gate.result") {
      bits.push(
        item.gate_verdict === "green" || item.gate_verdict === "red"
          ? item.gate_verdict
          : "verdict unknown"
      );
    }
    if (flowOwner(item) !== "none") {
      bits.push("unit " + item.unit);
    } else if (item.attribution === "conflict") {
      bits.push("unattributed (conflicting labels)");
    } else if (item.attribution === "partial") {
      bits.push("unattributed (no dispatch.start)");
    } else {
      bits.push("unattributed");
    }
    return bits.join(" · ");
  }

  function flowEdge(key, backend, judgeX, farX, farY) {
    var mid = FLOW.height / 2;
    var judgeY = mid + (farY - mid) / 6;
    var lift = farY > mid ? 18 : -8;
    return {
      key: key,
      backend: backend,
      out: "M " + judgeX + " " + judgeY + " L " + farX + " " + farY,
      back: "M " + farX + " " + farY + " L " + judgeX + " " + judgeY,
      lx: (judgeX + farX) / 2,
      ly: (judgeY + farY) / 2 + lift,
    };
  }

  function flowLayout(backends) {
    var mid = FLOW.height / 2;
    var half = FLOW.nodeW / 2;
    // Four implementer rows (three backends and unknown) close up to fit.
    var row =
      backends.length > 1
        ? Math.min(FLOW.row, (FLOW.height - FLOW.nodeH - FLOW.pad * 2) / (backends.length - 1))
        : FLOW.row;
    var nodes = [
      { key: "judge", label: "Judge", cx: FLOW.center, cy: mid, judge: true },
    ];
    var edges = [];
    var i;
    var y;
    for (i = 0; i < backends.length; i += 1) {
      y = mid + (i - (backends.length - 1) / 2) * row;
      nodes.push({
        key: "impl-" + backends[i],
        label: flowBackendName(backends[i]),
        cx: FLOW.left,
        cy: y,
      });
      edges.push(
        flowEdge("impl-" + backends[i], backends[i], FLOW.center - half, FLOW.left + half, y)
      );
    }
    for (i = 0; i < FLOW.sinks.length; i += 1) {
      y = mid + (i - (FLOW.sinks.length - 1) / 2) * FLOW.row;
      nodes.push({ key: FLOW.sinks[i][0], label: FLOW.sinks[i][1], cx: FLOW.right, cy: y });
      edges.push(flowEdge(FLOW.sinks[i][0], "", FLOW.center + half, FLOW.right - half, y));
    }
    return { nodes: nodes, edges: edges };
  }

  function createFlowEdge(edge) {
    var group = svgEl("g");
    svgAttr(group, "class", "flow-edge");
    var line = svgEl("path");
    svgAttr(line, "class", "flow-line");
    var label = svgEl("text");
    svgAttr(label, "text-anchor", "middle");
    group.appendChild(line);
    group.appendChild(label);
    group._line = line;
    group._label = label;
    updateFlowEdge(group, edge);
    return group;
  }

  function updateFlowEdge(group, edge) {
    svgAttr(group._line, "d", edge.out);
    svgAttr(group._label, "class", edge.partial ? "flow-label is-partial" : "flow-label");
    svgAttr(group._label, "x", edge.lx);
    svgAttr(group._label, "y", edge.ly);
    txt(group._label, edge.label);
  }

  function createFlowNode(node) {
    var group = svgEl("g");
    svgAttr(group, "class", node.judge ? "flow-node flow-judge" : "flow-node");
    var box = svgEl("rect");
    svgAttr(box, "width", FLOW.nodeW);
    svgAttr(box, "height", FLOW.nodeH);
    svgAttr(box, "rx", 8);
    var name = svgEl("text");
    svgAttr(name, "text-anchor", "middle");
    group.appendChild(box);
    group.appendChild(name);
    group._box = box;
    group._name = name;
    updateFlowNode(group, node);
    return group;
  }

  function updateFlowNode(group, node) {
    svgAttr(group._box, "x", node.cx - FLOW.nodeW / 2);
    svgAttr(group._box, "y", node.cy - FLOW.nodeH / 2);
    svgAttr(group._name, "x", node.cx);
    svgAttr(group._name, "y", node.cy + 5);
    txt(group._name, node.label);
  }

  function createFlowOption(item) {
    var option = el("option");
    updateFlowOption(option, item);
    return option;
  }

  function updateFlowOption(option, item) {
    setAttr(option, "value", item.token);
    txt(option, item.label);
  }

  function createFlowItem(item) {
    var row = el("li");
    updateFlowItem(row, item);
    return row;
  }

  function updateFlowItem(row, item) {
    txt(row, item.text);
  }

  function flowRecent(timeline, filter) {
    var picked = [];
    var used = {};
    for (var i = timeline.length - 1; i >= 0 && picked.length < FLOW.recent; i -= 1) {
      var item = timeline[i];
      if (item && typeof item === "object" && flowMatches(filter, item)) {
        var key = flowSeq(item) >= 0 ? "s" + item.seq : "i" + i;
        if (used[key]) {
          key += ":" + i;
        }
        used[key] = true;
        picked.unshift({ key: key, text: flowEventText(item) });
      }
    }
    if (!picked.length) {
      picked.push({ key: "none", text: "No recorded events under this filter." });
    }
    return picked;
  }

  function flowFresh(flow, runKey, timeline) {
    var top = -1;
    var i;
    for (i = 0; i < timeline.length; i += 1) {
      if (flowSeq(timeline[i]) > top) {
        top = timeline[i].seq;
      }
    }
    var seen = Object.prototype.hasOwnProperty.call(flow.marks, runKey);
    var mark = seen ? flow.marks[runKey] : top;
    var fresh = [];
    if (seen) {
      for (i = 0; i < timeline.length; i += 1) {
        if (flowSeq(timeline[i]) > mark) {
          fresh.push(timeline[i]);
        }
      }
    }
    flow.marks[runKey] = Math.max(mark, top);
    return fresh;
  }

  function clearPackets(layer) {
    while (layer.firstChild) {
      layer.removeChild(layer.firstChild);
    }
  }

  function launchPacket(layer, d, variant, lag) {
    var packet = svgEl("path");
    svgAttr(
      packet,
      "class",
      "flow-packet is-" + variant + " flow-lag-" + Math.min(lag, 9)
    );
    svgAttr(packet, "d", d);
    packet.addEventListener("animationend", function () {
      if (packet.parentNode === layer) {
        layer.removeChild(packet);
      }
    });
    layer.appendChild(packet);
    while (layer.childNodes.length > FLOW.packets) {
      layer.removeChild(layer.firstChild);
    }
  }

  function syncFlowFilter(select, flow, units) {
    var items = [{ key: "all", token: "all", label: "All" }];
    for (var i = 0; i < units.length; i += 1) {
      items.push({
        key: "u:" + units[i],
        token: flowToken(flow, "u:" + units[i]),
        label: units[i],
      });
    }
    items.push({ key: "none", token: "unattributed", label: "Unattributed" });
    syncKeyed(select, items, flowKey, createFlowOption, updateFlowOption);
    applySelectValue(select, flowToken(flow, flow.filter));
  }

  function ensureFlowSkeleton(root) {
    if (root._mode === "flow" && root._parts) {
      return root._parts;
    }
    wipe(root);
    root._mode = "flow";
    var parts = {};
    parts.bar = el("div");
    parts.bar.className = "flow-bar";
    var label = el("label");
    label.setAttribute("for", "flow-filter");
    label.className = "flow-filter-label";
    txt(label, "Show");
    parts.filter = el("select");
    parts.filter.setAttribute("id", "flow-filter");
    parts.filter.addEventListener("change", function () {
      var flow = flowMemory(root);
      flow.filter = flowFilterFor(flow, parts.filter.value);
      clearPackets(parts.packets);
      if (flow.state) {
        drawFlow(root, flow.state);
      }
    });
    parts.legend = el("p");
    parts.legend.className = "flow-legend";
    var caveat = el("span");
    txt(caveat, "recorded events — not verified");
    parts.legend.appendChild(caveat);
    parts.legend.appendChild(chip("recorded", "neutral"));
    parts.legend.appendChild(chip("iterate", "caution"));
    parts.legend.appendChild(chip("nonzero exit, red, abandoned", "danger"));
    parts.bar.appendChild(label);
    parts.bar.appendChild(parts.filter);
    parts.bar.appendChild(parts.legend);
    root.appendChild(parts.bar);
    parts.figure = el("div");
    parts.figure.className = "flow-figure";
    parts.svg = svgEl("svg");
    svgAttr(parts.svg, "class", "flow-svg");
    svgAttr(parts.svg, "viewBox", "0 0 " + FLOW.width + " " + FLOW.height);
    svgAttr(parts.svg, "width", FLOW.width);
    svgAttr(parts.svg, "height", FLOW.height);
    svgAttr(parts.svg, "role", "img");
    svgAttr(parts.svg, "focusable", "false");
    parts.edges = svgEl("g");
    svgAttr(parts.edges, "class", "flow-edges");
    parts.packets = svgEl("g");
    svgAttr(parts.packets, "class", "flow-packets");
    svgAttr(parts.packets, "aria-hidden", "true");
    parts.nodes = svgEl("g");
    svgAttr(parts.nodes, "class", "flow-nodes");
    parts.svg.appendChild(parts.edges);
    parts.svg.appendChild(parts.packets);
    parts.svg.appendChild(parts.nodes);
    parts.figure.appendChild(parts.svg);
    root.appendChild(parts.figure);
    parts.recentHead = el("h3");
    parts.recentHead.className = "visually-hidden";
    txt(parts.recentHead, "Last ten recorded events");
    root.appendChild(parts.recentHead);
    parts.recent = el("ol");
    parts.recent.className = "visually-hidden";
    root.appendChild(parts.recent);
    parts.truncated = null;
    parts.damaged = null;
    root._parts = parts;
    return parts;
  }

  function drawFlow(root, state) {
    var run = pickRun(state);
    if (!run) {
      showHint(root, "No runs recorded yet.");
      return;
    }
    if (!flowReady(run)) {
      showHint(root, "No flow data: this index output has no run totals or timeline.");
      return;
    }
    var flow = flowMemory(root);
    flow.state = state;
    var parts = ensureFlowSkeleton(root);
    var runKey = "r:" + String(run.run_id);
    if (flow.run !== runKey) {
      clearPackets(parts.packets);
      flow.run = runKey;
    }
    var counts = run.counts;
    var units = flowUnits(counts);
    if (flow.filter.indexOf("u:") === 0 && units.indexOf(flow.filter.slice(2)) === -1) {
      flow.filter = "all";
    }
    syncFlowFilter(parts.filter, flow, units);
    var picked = flowCounts(counts, flow.filter);
    var backends = flowBackends(counts.all, picked);
    var layout = flowLayout(backends);
    var partial = run.counts_complete !== true;
    var truncated = run.timeline_truncated === true;
    var edges = {};
    var i;
    for (i = 0; i < layout.edges.length; i += 1) {
      layout.edges[i].label = flowEdgeLabel(layout.edges[i], picked, partial);
      layout.edges[i].partial = partial;
      edges["e:" + layout.edges[i].key] = layout.edges[i];
    }
    syncKeyed(parts.edges, layout.edges, flowKey, createFlowEdge, updateFlowEdge);
    syncKeyed(parts.nodes, layout.nodes, flowKey, createFlowNode, updateFlowNode);
    svgAttr(parts.svg, "aria-label", flowAriaLabel(picked, backends, partial));
    // A damaged record's counts are partial, so a truncated, damaged run gets
    // one notice that says both and never claims whole-run totals.
    var damage = "";
    if (partial) {
      damage = truncated
        ? "packets show the last 500 events; counts are partial because the record is damaged"
        : "The run's record is damaged: every count here is partial.";
    }
    parts.truncated = updateOptional(
      root,
      parts.truncated,
      "flow-notice",
      truncated && !partial
        ? "packets show the last 500 events; totals cover the whole run"
        : "",
      parts.figure
    );
    parts.damaged = updateOptional(
      root,
      parts.damaged,
      "flow-notice is-damaged",
      damage,
      parts.truncated && parts.truncated.parentNode === root ? parts.truncated : parts.figure
    );
    syncKeyed(
      parts.recent,
      flowRecent(run.timeline, flow.filter),
      flowKey,
      createFlowItem,
      updateFlowItem
    );
    var fresh = flowFresh(flow, runKey, run.timeline);
    if (flowReducedMotion()) {
      clearPackets(parts.packets);
      return;
    }
    var lag = 0;
    for (i = 0; i < fresh.length; i += 1) {
      var route = flowRoute(fresh[i]);
      if (!route || !flowMatches(flow.filter, fresh[i])) {
        continue;
      }
      var edge = flowOwn(edges, "e:" + route.edge);
      if (!edge) {
        continue;
      }
      launchPacket(
        parts.packets,
        route.back ? edge.back : edge.out,
        flowVariant(fresh[i]),
        lag
      );
      lag += 1;
    }
  }

  function renderFlow(state) {
    var root = document.getElementById("flow-root");
    if (!root) {
      return;
    }
    drawFlow(root, state);
  }

  function publishSignature(publish) {
    if (!publish || publish === "not recorded") {
      return "none";
    }
    return [
      publish.branch || "",
      publish.sha || "",
      publish.note || "",
      publish.pr || "",
    ].join("\0");
  }

  function fillPublishFacts(row, publish) {
    var sig = publishSignature(publish);
    if (row._sig === sig) {
      return;
    }
    row._sig = sig;
    while (row.childNodes.length > 1) {
      row.removeChild(row.lastChild);
    }
    if (!publish || publish === "not recorded") {
      var none = el("p");
      none.className = "meta";
      txt(none, "not recorded");
      row.appendChild(none);
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
  }

  function renderPublish(parent, publish) {
    var row = el("div");
    row.className = "publish";
    var key = el("span");
    key.className = "muted-label";
    txt(key, "Publish");
    row.appendChild(key);
    fillPublishFacts(row, publish);
    parent.appendChild(row);
    return row;
  }

  function verdictVariant(verdict) {
    if (verdict === "green") {
      return "ok";
    }
    if (verdict === "red") {
      return "danger";
    }
    return "neutral";
  }

  function createGate(gate) {
    var box = el("div");
    box.className = "gate";
    var verdict = chip("unknown", "neutral");
    box.appendChild(verdict);
    var badge = chip("unknown", "neutral");
    box.appendChild(badge);
    var meta = el("p");
    meta.className = "meta";
    box.appendChild(meta);
    var note = el("span");
    note.className = "gate-note";
    box.appendChild(note);
    box._verdict = verdict;
    box._badge = badge;
    box._meta = meta;
    box._note = note;
    updateGate(box, gate);
    return box;
  }

  function updateGate(box, gate) {
    var verdict =
      gate.verdict === "green" || gate.verdict === "red"
        ? gate.verdict
        : "unknown";
    setChip(
      box._verdict,
      verdict,
      verdictVariant(verdict),
      verdict !== "unknown",
      "gate-verdict"
    );
    var binding = gate.binding || "unknown";
    var clean = binding === "clean";
    setChip(box._badge, binding, bindingVariant(binding), clean, "gate-binding");
    txt(
      box._meta,
      (gate.policy || "unknown") + " · " + (gate.purpose || "unknown")
    );
    txt(box._note, "Recorded gate result — not proof of what ships.");
  }

  function appendCell(row, value, className) {
    var cell = el("td");
    if (className) {
      cell.className = className;
    }
    txt(cell, value);
    row.appendChild(cell);
  }

  function createUnit(unit) {
    var box = el("div");
    box.className = "card unit";
    var name = el("h3");
    box.appendChild(name);
    var status = chip("unknown", "neutral");
    box.appendChild(status);
    var rounds = el("p");
    rounds.className = "meta";
    var rlabel = el("span");
    txt(rlabel, "Rounds ");
    var rval = el("span");
    rval.className = "tabular";
    rounds.appendChild(rlabel);
    rounds.appendChild(rval);
    box.appendChild(rounds);
    var review = el("p");
    review.className = "meta";
    box.appendChild(review);
    var pub = renderPublish(box, unit.publish);
    box._name = name;
    box._chip = status;
    box._rounds = rval;
    box._review = review;
    box._publish = pub;
    updateUnit(box, unit);
    return box;
  }

  function updateUnit(box, unit) {
    txt(box._name, unit.unit || "unknown");
    setChip(box._chip, unit.status || "unknown", wordVariant(unit.status));
    txt(box._rounds, unit.rounds == null ? "0" : String(unit.rounds));
    txt(box._review, "Review " + reviewLabel(unit.review));
    fillPublishFacts(box._publish, unit.publish);
  }

  function createDispatchRow(item) {
    var tr = el("tr");
    appendCell(tr, "", "mono");
    appendCell(tr, "", "");
    appendCell(tr, "", "");
    appendCell(tr, "", "");
    appendCell(tr, "", "tabular");
    updateDispatchRow(tr, item);
    return tr;
  }

  function updateDispatchRow(tr, item) {
    var cells = tr.children;
    txt(cells[0], item.dispatch_id || "unknown");
    txt(cells[1], item.backend || "unknown");
    txt(cells[2], item.mode || "unknown");
    txt(cells[3], item.state || "unknown");
    txt(cells[4], item.exit == null ? "" : String(item.exit));
  }

  function ensureRunSkeleton(root) {
    if (root._mode === "run") {
      return root._parts;
    }
    wipe(root);
    root._mode = "run";
    var parts = {};
    parts.head = el("div");
    parts.head.className = "run-head";
    parts.runId = el("p");
    parts.runId.className = "mono run-id";
    parts.status = chip("unknown", "neutral");
    parts.head.appendChild(parts.runId);
    parts.head.appendChild(parts.status);
    root.appendChild(parts.head);
    parts.unitHead = el("h3");
    txt(parts.unitHead, "Units");
    root.appendChild(parts.unitHead);
    parts.unitBody = el("div");
    root.appendChild(parts.unitBody);
    parts.dispHead = el("h3");
    txt(parts.dispHead, "Dispatches");
    root.appendChild(parts.dispHead);
    parts.dispBody = el("div");
    root.appendChild(parts.dispBody);
    parts.gateHead = el("h3");
    txt(parts.gateHead, "Gates");
    root.appendChild(parts.gateHead);
    parts.gateBody = el("div");
    root.appendChild(parts.gateBody);
    root._parts = parts;
    return parts;
  }

  function ensureDispatchTable(body) {
    if (body._mode === "table" && body._tbody) {
      return body._tbody;
    }
    wipe(body);
    body._mode = "table";
    setClass(body, "table-wrap");
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
    table.appendChild(tbody);
    body.appendChild(table);
    body._tbody = tbody;
    return tbody;
  }

  function renderThisRun(state) {
    var root = document.getElementById("run-root");
    if (!root) {
      return;
    }
    var runs = state.runs || [];
    if (!runs.length) {
      showEmpty(root);
      return;
    }
    var run = pickRun(state);
    if (!run) {
      showEmpty(root);
      return;
    }
    var parts = ensureRunSkeleton(root);
    txt(parts.runId, run.run_id || "unknown");
    setChip(parts.status, run.status || "unknown", wordVariant(run.status));
    var units = run.units || [];
    if (!units.length) {
      showHint(parts.unitBody, "No units recorded.");
    } else {
      var unitGrid = ensureHost(parts.unitBody, "grid", "card-grid");
      syncKeyed(
        unitGrid,
        units,
        function (unit) {
          return unit.unit || "unknown";
        },
        createUnit,
        updateUnit
      );
    }
    var items = run.dispatches || [];
    if (!items.length) {
      showHint(parts.dispBody, "No dispatches recorded.");
    } else {
      var tbody = ensureDispatchTable(parts.dispBody);
      syncKeyed(
        tbody,
        items,
        function (item) {
          return item.dispatch_id;
        },
        createDispatchRow,
        updateDispatchRow
      );
    }
    var gates = run.gates || [];
    if (!gates.length) {
      showHint(parts.gateBody, "No gates recorded.");
    } else {
      var gateRow = ensureHost(parts.gateBody, "gates", "gate-row");
      syncKeyed(
        gateRow,
        gates,
        function (_gate, index) {
          return String(index);
        },
        createGate,
        updateGate
      );
    }
  }

  function isPermissionKey(key) {
    return PERMISSION_KEYS.indexOf(key) !== -1;
  }

  function setDisabled(node, disabled) {
    var isDisabled = node.getAttribute("disabled") === "disabled";
    if (disabled && !isDisabled) {
      node.setAttribute("disabled", "disabled");
    } else if (!disabled && isDisabled) {
      node.removeAttribute("disabled");
    }
  }

  function dialMetaText(record) {
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
    return bits.join(" · ");
  }

  function applySelectValue(select, value) {
    if (document.activeElement === select) {
      return;
    }
    var next = value == null ? "" : String(value);
    if (select.value !== next) {
      select.value = next;
    }
  }

  function createDial(item) {
    var key = item.key;
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
    box.appendChild(head);
    var value = el("p");
    value.className = "dial-value mono";
    box.appendChild(value);
    var meta = el("p");
    meta.className = "meta dial-meta";
    box.appendChild(meta);
    var controls = el("div");
    controls.className = "dial-controls";
    var select = el("select");
    select.setAttribute("id", selectId);
    select.setAttribute("data-dial", key);
    var options = DIAL_OPTIONS[key] || [];
    var i;
    for (i = 0; i < options.length; i += 1) {
      var option = el("option");
      option.setAttribute("value", options[i]);
      txt(option, options[i]);
      select.appendChild(option);
    }
    select.addEventListener("focusout", function () {
      applySelectValue(select, select._want);
    });
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
    box._key = key;
    box._head = head;
    box._grant = null;
    box._value = value;
    box._meta = meta;
    box._select = select;
    box._apply = apply;
    box._reset = reset;
    updateDial(box, item);
    return box;
  }

  function updateDial(box, item) {
    var record = item.record;
    var locked = item.locked;
    var options = DIAL_OPTIONS[item.key] || [];
    var current = record && record.value ? String(record.value) : options[0] || "";
    var grant = record && record.scope === "permission";
    txt(box._value, record && record.value ? record.value : "");
    txt(box._meta, dialMetaText(record));
    if (grant) {
      if (!box._grant) {
        box._grant = chip("grants authority", "caution");
        box._head.appendChild(box._grant);
      }
    } else if (box._grant) {
      box._head.removeChild(box._grant);
      box._grant = null;
    }
    box._select._want = current;
    applySelectValue(box._select, current);
    setDisabled(box._select, locked);
    setDisabled(box._apply, locked);
    setDisabled(box._reset, locked);
  }

  function renderDialRow(parent, key, record, locked) {
    var box = createDial({ key: key, record: record, locked: locked });
    parent.appendChild(box);
    return box;
  }

  function dialItems(keys, dials, locked) {
    var items = [];
    var i;
    for (i = 0; i < keys.length; i += 1) {
      items.push({
        key: keys[i],
        record: dials[keys[i]],
        locked: locked,
      });
    }
    return items;
  }

  function policyKeys() {
    var keys = [];
    var i;
    for (i = 0; i < DIAL_ORDER.length; i += 1) {
      if (!isPermissionKey(DIAL_ORDER[i])) {
        keys.push(DIAL_ORDER[i]);
      }
    }
    return keys;
  }

  function noticeText(doc) {
    if (doc.store === "rejected") {
      return (
        "The calibration store was rejected: " +
        (doc.reason ? String(doc.reason) : "unknown reason") +
        ". Repair or remove the store file. Controls are disabled."
      );
    }
    if (doc.store === "absent") {
      return "The calibration store is absent. Safe defaults are in effect; nothing was imported from memory. Confirming a value here records it. Permission dials recorded here are granted via this console.";
    }
    return "";
  }

  function noticeClass(doc) {
    if (doc.store === "rejected") {
      return "dials-notice is-rejected";
    }
    if (doc.store === "absent") {
      return "dials-notice is-absent";
    }
    return "dials-notice";
  }

  function placeBefore(parent, node, before) {
    if (node.parentNode === parent && (!before || node.nextSibling === before)) {
      return;
    }
    parent.insertBefore(node, before || null);
  }

  function updateOptional(parent, slot, className, text, before) {
    if (!text) {
      if (slot && slot.parentNode === parent) {
        parent.removeChild(slot);
      }
      return null;
    }
    if (!slot) {
      slot = el("p");
    }
    setClass(slot, className);
    txt(slot, text);
    placeBefore(parent, slot, before);
    return slot;
  }

  function ensureDialsSkeleton(root) {
    if (root._mode === "dials" && root._parts) {
      return root._parts;
    }
    wipe(root);
    root._mode = "dials";
    var parts = {};
    parts.permBox = el("div");
    parts.permBox.className = "dials-permission";
    parts.permHead = el("h3");
    txt(parts.permHead, "Permission dials");
    parts.permBox.appendChild(parts.permHead);
    parts.permNote = el("p");
    parts.permNote.className = "dials-section-note";
    txt(
      parts.permNote,
      "These dials grant standing authorization when set beyond their default. At their default value they carry no authority."
    );
    parts.permBox.appendChild(parts.permNote);
    parts.permList = el("div");
    parts.permList.className = "dial-list";
    parts.permBox.appendChild(parts.permList);
    root.appendChild(parts.permBox);
    parts.polHead = el("h3");
    txt(parts.polHead, "Policy");
    root.appendChild(parts.polHead);
    parts.polBox = el("div");
    parts.polBox.className = "dials-policy";
    root.appendChild(parts.polBox);
    parts.notice = null;
    parts.store = null;
    root._parts = parts;
    return parts;
  }

  function showDialsInert(root) {
    if (root._mode === "inert" && root.firstChild) {
      txt(root.firstChild, "Authenticate to read and set the workspace dials.");
      return;
    }
    wipe(root);
    root._mode = "inert";
    var inert = el("p");
    inert.className = "empty-hint";
    txt(inert, "Authenticate to read and set the workspace dials.");
    root.appendChild(inert);
  }

  function renderDials(doc) {
    var root = document.getElementById("dials-root");
    if (!root) {
      return;
    }
    bindLiveRegions();
    if (!doc) {
      showDialsInert(root);
      return;
    }
    lastDials = doc;
    var parts = ensureDialsSkeleton(root);
    var rejected = doc.store === "rejected";
    var locked = rejected || dialsBusy;
    var dials = doc.dials || {};
    parts.notice = updateOptional(
      root,
      parts.notice,
      noticeClass(doc),
      noticeText(doc),
      parts.store && parts.store.parentNode === root ? parts.store : parts.permBox
    );
    parts.store = updateOptional(
      root,
      parts.store,
      "meta",
      doc.store ? "Store " + String(doc.store) : "",
      parts.permBox
    );
    syncKeyed(
      parts.permList,
      dialItems(PERMISSION_KEYS, dials, locked),
      function (item) {
        return item.key;
      },
      createDial,
      updateDial
    );
    syncKeyed(
      parts.polBox,
      dialItems(policyKeys(), dials, locked),
      function (item) {
        return item.key;
      },
      createDial,
      updateDial
    );
  }

  function setDialError(message) {
    var node = document.getElementById("dials-error");
    if (node) {
      if (node.getAttribute("role") !== "status") {
        node.setAttribute("role", "status");
      }
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
    stampUpdated();
    renderVitals(state);
    renderNow(state);
    renderFlow(state);
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
    var heading = document.getElementById("transcript-heading");
    if (!pre || !dispatchId) {
      return;
    }
    if (pre.getAttribute("data-dispatch") !== dispatchId) {
      setAttr(pre, "data-dispatch", dispatchId);
      txt(pre, "");
      if (heading) {
        txt(heading, "Transcript");
      }
    }
    fetch("/api/transcript?dispatch=" + encodeURIComponent(dispatchId), {
      credentials: "same-origin",
      headers: apiHeaders(),
    })
      .then(function (response) {
        if (!response.ok) {
          txt(pre, "Transcript unavailable.");
          if (heading) {
            txt(heading, "Transcript");
          }
          return null;
        }
        return response.json();
      })
      .then(function (payload) {
        if (!payload) {
          return;
        }
        if (heading) {
          txt(heading, transcriptHeadingText(payload.path));
        }
        txt(pre, payload.tail == null ? "" : String(payload.tail));
      })
      .catch(function () {
        txt(pre, "Transcript unavailable.");
        if (heading) {
          txt(heading, "Transcript");
        }
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
    pollId = setInterval(function () {
      pullState();
      pullDials();
    }, POLL_MS);
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
