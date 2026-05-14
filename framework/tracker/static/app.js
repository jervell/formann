"use strict";

// Tracker viewer client. Sidebar lists features and (per feature) the PRD plus
// issues with a status dot; detail panes render markdown via marked, with the
// leading metadata block stripped, status pills shown above the body, and
// cross-references (#NN, <feature>/NN, <feature>/PRD) turned into hash links.

const sidebarEl = document.getElementById("sidebar");
const contentEl = document.getElementById("content");

let tree = [];
let knownSlugs = new Set();
// Sidebar tab state. The hash route doesn't carry section information
// (archived features use the same #/<feature>/... format as active ones),
// so the tab lives in client state. Hash navigation forces the tab to the
// route's section; clicking a tab button overrides without touching the hash.
let currentTab = "active";

async function init() {
  try {
    const res = await fetch("/api/tree");
    if (!res.ok) throw new Error(`tree fetch failed: ${res.status}`);
    tree = await res.json();
    knownSlugs = new Set(tree.map(f => f.slug));
  }
  catch (err) {
    sidebarEl.replaceChildren(makeError(`Could not load tree: ${err.message}`));
    return;
  }
  syncTabToRoute();
  renderRoute();
}

window.addEventListener("hashchange", () => {
  syncTabToRoute();
  renderRoute();
});

function syncTabToRoute() {
  const { feature: slug } = currentRoute();
  if (!slug) return;
  const feat = findFeature(slug);
  if (feat) currentTab = feat.section;
}

// ---------- Routing ----------

function currentRoute() {
  let raw;
  try {
    raw = decodeURIComponent(location.hash.replace(/^#\/?/, ""));
  }
  catch {
    raw = location.hash.replace(/^#\/?/, "");
  }
  if (!raw) return { feature: null, target: null };
  const slash = raw.indexOf("/");
  if (slash === -1) return { feature: raw, target: null };
  return { feature: raw.slice(0, slash), target: raw.slice(slash + 1) };
}

function findFeature(slug) {
  return tree.find(f => f.slug === slug) || null;
}

function findIssue(feature, number) {
  return feature.issues.find(i => i.number === number) || null;
}

// ---------- Sidebar ----------

function renderSidebar() {
  const { feature: activeSlug, target: activeTarget } = currentRoute();

  const tabs = document.createElement("div");
  tabs.className = "sidebar-tabs";
  for (const tab of ["active", "archive"]) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "sidebar-tab";
    if (tab === currentTab) btn.classList.add("active");
    btn.textContent = tab[0].toUpperCase() + tab.slice(1);
    btn.addEventListener("click", () => {
      if (currentTab === tab) return;
      currentTab = tab;
      renderSidebar();
    });
    tabs.appendChild(btn);
  }

  const ul = document.createElement("ul");

  const visible = tree
    .filter(f => f.section === currentTab)
    .sort((a, b) => (b.mtime || 0) - (a.mtime || 0));

  for (const feat of visible) {
    const li = document.createElement("li");
    li.className = "feature";
    if (feat.slug === activeSlug) {
      li.classList.add("expanded", "active-feature");
    }
    const toggle = document.createElement("button");
    toggle.className = "feature-toggle";
    toggle.type = "button";
    toggle.textContent = feat.slug;
    toggle.addEventListener("click", () => {
      if (feat.slug === activeSlug && !activeTarget) {
        location.hash = "#/";
      }
      else {
        location.hash = `#/${feat.slug}`;
      }
    });
    li.appendChild(toggle);

    const childUl = document.createElement("ul");

    if (feat.prd) {
      childUl.appendChild(makePrdRow(feat, activeSlug, activeTarget));
    }
    for (const issue of feat.issues) {
      childUl.appendChild(makeIssueRow(feat, issue, activeSlug, activeTarget));
    }

    li.appendChild(childUl);
    ul.appendChild(li);
  }

  sidebarEl.replaceChildren(tabs, ul);
}

function makePrdRow(feat, activeSlug, activeTarget) {
  const li = document.createElement("li");
  const a = document.createElement("a");
  a.href = `#/${feat.slug}/PRD`;
  if (feat.slug === activeSlug && activeTarget === "PRD") a.classList.add("active");
  a.textContent = "📄 PRD";
  li.appendChild(a);
  return li;
}

function makeIssueRow(feat, issue, activeSlug, activeTarget) {
  const li = document.createElement("li");
  const a = document.createElement("a");
  a.className = "issue-row";
  a.href = `#/${feat.slug}/${issue.number}`;
  if (feat.slug === activeSlug && activeTarget === issue.number) {
    a.classList.add("active");
  }
  if (issue.status === "wontfix") a.classList.add("wontfix");

  if (issue.status) {
    const dot = document.createElement("span");
    dot.className = `status-dot status-${issue.status}`;
    dot.title = issue.status;
    a.appendChild(dot);
  }
  const num = document.createElement("span");
  num.className = "num";
  num.textContent = issue.number;
  a.appendChild(num);

  const title = document.createElement("span");
  title.className = "title";
  title.textContent = issue.title || issue.path;
  a.appendChild(title);

  li.appendChild(a);
  return li;
}

// ---------- Routing dispatch ----------

async function renderRoute() {
  renderSidebar();
  const { feature: slug, target } = currentRoute();
  if (!slug) {
    renderDashboard();
    return;
  }
  const feature = findFeature(slug);
  if (!feature) {
    contentEl.replaceChildren(makeError(`Unknown feature: ${slug}`));
    return;
  }
  if (!target) {
    renderFeatureOverview(feature);
    return;
  }
  if (target === "PRD") {
    if (!feature.prd) {
      contentEl.replaceChildren(makeError(`No PRD for ${slug}`));
      return;
    }
    await renderPrd(feature);
    return;
  }
  const issue = findIssue(feature, target);
  if (!issue) {
    contentEl.replaceChildren(makeError(`Unknown issue: ${slug}/${target}`));
    return;
  }
  await renderIssue(feature, issue);
}

// Lifecycle order for the status-count strip; statuses with zero issues are
// omitted entirely rather than rendered as "0 needs-triage".
const STATUS_ORDER = [
  "needs-triage",
  "needs-info",
  "ready-for-agent",
  "ready-for-human",
  "in-review",
  "done",
  "wontfix",
];

function countStatuses(feature) {
  const counts = new Map();
  for (const issue of feature.issues) {
    if (!issue.status) continue;
    counts.set(issue.status, (counts.get(issue.status) || 0) + 1);
  }
  return counts;
}

function makeStatusCountStrip(feature) {
  const strip = document.createElement("div");
  strip.className = "status-counts";
  const counts = countStatuses(feature);
  for (const status of STATUS_ORDER) {
    const n = counts.get(status);
    if (!n) continue;
    const chip = document.createElement("span");
    chip.className = `pill status status-${status}`;
    chip.textContent = `${n} ${status}`;
    strip.appendChild(chip);
  }
  return strip;
}

function renderDashboard() {
  const h = document.createElement("h1");
  h.textContent = "Tracker";

  const list = document.createElement("ul");
  list.className = "feature-list";
  const dashboardFeatures = tree
    .filter(f => f.section === "active")
    .sort((a, b) => (b.mtime || 0) - (a.mtime || 0));
  for (const feat of dashboardFeatures) {
    const li = document.createElement("li");
    const a = document.createElement("a");
    a.href = `#/${feat.slug}`;
    a.className = "feature-card";

    const name = document.createElement("span");
    name.className = "feature-name";
    name.textContent = feat.slug;
    a.appendChild(name);
    a.appendChild(makeStatusCountStrip(feat));

    li.appendChild(a);
    list.appendChild(li);
  }
  contentEl.replaceChildren(h, list);
}

function renderFeatureOverview(feature) {
  const h = document.createElement("h1");
  h.textContent = feature.slug;

  const strip = makeStatusCountStrip(feature);

  const list = document.createElement("ul");
  list.className = "issue-list";

  if (feature.prd) {
    const li = document.createElement("li");
    li.className = "issue-list-row prd-row";
    const a = document.createElement("a");
    a.href = `#/${feature.slug}/PRD`;
    a.textContent = "📄 PRD";
    li.appendChild(a);
    list.appendChild(li);
  }

  for (const issue of feature.issues) {
    const li = document.createElement("li");
    li.className = "issue-list-row";
    const a = document.createElement("a");
    a.href = `#/${feature.slug}/${issue.number}`;
    if (issue.status === "wontfix") a.classList.add("wontfix");

    if (issue.status) a.appendChild(makePill("status", issue.status));
    if (issue.type) a.appendChild(makePill("type", issue.type));

    const num = document.createElement("span");
    num.className = "num";
    num.textContent = issue.number;
    a.appendChild(num);

    const title = document.createElement("span");
    title.className = "title";
    title.textContent = issue.title || issue.path;
    a.appendChild(title);

    li.appendChild(a);
    list.appendChild(li);
  }

  contentEl.replaceChildren(h, strip, list);
}

function rawPrefix(feature) {
  // Archived features live under .scratch/done/<slug>/. The hash route never
  // includes the `done/` segment (the spec keeps the canonical <feature>/NN
  // form across active and archive), so we add it only at fetch time based
  // on the feature's section.
  return feature.section === "archive" ? `done/${feature.slug}` : feature.slug;
}

async function renderPrd(feature) {
  const md = await fetchMarkdown(`/raw/${rawPrefix(feature)}/PRD.md`);
  if (md == null) return;
  const stripped = stripHeaderBlock(md);
  const title = extractTitle(md) || `${feature.slug} — PRD`;
  const heading = document.createElement("h1");
  heading.textContent = title;
  const body = renderMarkdown(stripped, feature.slug);
  contentEl.replaceChildren(heading, body);
}

async function renderIssue(feature, issue) {
  const md = await fetchMarkdown(`/raw/${rawPrefix(feature)}/${issue.path}`);
  if (md == null) return;
  const stripped = stripHeaderBlock(md);
  const title = extractTitle(md) || issue.title || issue.path;

  const heading = document.createElement("h1");
  heading.textContent = title;

  const strip = makeHeaderStrip(issue);
  const body = renderMarkdown(stripped, feature.slug);

  contentEl.replaceChildren(heading, strip, body);
}

function makeHeaderStrip(issue) {
  const strip = document.createElement("div");
  strip.className = "header-strip";
  if (issue.error) {
    const err = document.createElement("span");
    err.className = "pill error";
    err.textContent = `frontmatter parse error: ${issue.error}`;
    strip.appendChild(err);
    return strip;
  }
  if (issue.status) {
    strip.appendChild(makePill("status", issue.status));
  }
  if (issue.category) {
    strip.appendChild(makePill("category", issue.category));
  }
  if (issue.type) {
    strip.appendChild(makePill("type", issue.type));
  }
  return strip;
}

function makePill(kind, value) {
  const span = document.createElement("span");
  span.className = `pill ${kind} status-${value}`;
  span.textContent = value;
  return span;
}

async function fetchMarkdown(url) {
  let res;
  try {
    res = await fetch(url);
  }
  catch (err) {
    contentEl.replaceChildren(makeError(`Network error: ${err.message}`));
    return null;
  }
  if (!res.ok) {
    contentEl.replaceChildren(makeError(`Could not load ${url} (${res.status})`));
    return null;
  }
  return await res.text();
}

// ---------- Markdown helpers ----------

function extractTitle(md) {
  for (const line of stripFrontmatter(md).split("\n")) {
    if (line.startsWith("## ")) return null;
    if (line.startsWith("# ")) return line.slice(2).trim();
  }
  return null;
}

function stripFrontmatter(md) {
  // Remove a leading YAML frontmatter block (--- ... ---) so it doesn't
  // leak into the rendered body. Files without a leading '---' line are
  // returned unchanged.
  const lines = md.split("\n");
  if (lines[0] !== "---") return md;
  const close = lines.indexOf("---", 1);
  if (close === -1) return md; // unclosed — server flags the parse error
  return lines.slice(close + 1).join("\n");
}

function stripHeaderBlock(md) {
  // Strip the leading frontmatter block (handled by the server too, but
  // the client sees the raw bytes) and the first '# ' heading, since the
  // viewer renders the H1 separately above the pills. Paragraph spacing
  // below the heading is preserved.
  const body = stripFrontmatter(md);
  const out = [];
  let beforeFirstH2 = true;
  let h1Removed = false;
  for (const line of body.split("\n")) {
    if (beforeFirstH2 && line.startsWith("## ")) {
      beforeFirstH2 = false;
    }
    if (beforeFirstH2 && !h1Removed && line.startsWith("# ")) {
      h1Removed = true;
      continue;
    }
    out.push(line);
  }
  while (out.length && out[0].trim() === "") out.shift();
  return out.join("\n");
}

function renderMarkdown(md, currentFeature) {
  const container = document.createElement("div");
  container.className = "rendered";
  container.innerHTML = marked.parse(md);
  insertCommentsRule(container);
  linkifyReferences(container, currentFeature);
  return container;
}

function insertCommentsRule(root) {
  for (const h2 of root.querySelectorAll("h2")) {
    if (h2.textContent.trim().toLowerCase() === "comments") {
      const hr = document.createElement("hr");
      h2.parentNode.insertBefore(hr, h2);
      break;
    }
  }
}

// Combined cross-reference regex.
//   - Group 1+2: <feature-slug>/<NN-or-PRD>
//   - Group 3:   #NN  (NN must be 2+ digits)
// Word-boundary look-arounds keep us out of identifiers, URLs, and #fragments.
const REF_RE = /(?<![A-Za-z0-9_/#-])(?:([a-z][a-z0-9-]*)\/(\d{2,}|PRD)|#(\d{2,}))(?![A-Za-z0-9_])/g;

function linkifyReferences(root, currentFeature) {
  const skip = new Set(["A", "CODE", "PRE"]);
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      let p = node.parentNode;
      while (p && p !== root) {
        if (skip.has(p.nodeName)) return NodeFilter.FILTER_REJECT;
        p = p.parentNode;
      }
      return NodeFilter.FILTER_ACCEPT;
    },
  });
  const targets = [];
  let n;
  while ((n = walker.nextNode())) targets.push(n);

  for (const node of targets) {
    const text = node.nodeValue;
    REF_RE.lastIndex = 0;
    if (!REF_RE.test(text)) continue;
    REF_RE.lastIndex = 0;

    const frag = document.createDocumentFragment();
    let lastIndex = 0;
    let m;
    while ((m = REF_RE.exec(text)) !== null) {
      const [match, slug, target, hashNum] = m;
      let href = null;
      if (slug && target && knownSlugs.has(slug)) {
        href = `#/${slug}/${target}`;
      }
      else if (hashNum && currentFeature) {
        href = `#/${currentFeature}/${hashNum}`;
      }
      if (m.index > lastIndex) {
        frag.appendChild(document.createTextNode(text.slice(lastIndex, m.index)));
      }
      if (href) {
        const a = document.createElement("a");
        a.href = href;
        a.textContent = match;
        frag.appendChild(a);
      }
      else {
        frag.appendChild(document.createTextNode(match));
      }
      lastIndex = m.index + match.length;
    }
    if (lastIndex < text.length) {
      frag.appendChild(document.createTextNode(text.slice(lastIndex)));
    }
    node.parentNode.replaceChild(frag, node);
  }
}

// ---------- Misc ----------

function makeError(msg) {
  const p = document.createElement("p");
  p.textContent = msg;
  return p;
}

init();
