(function () {
  "use strict";

  var STORE_KEY = "markdownReader.v2";
  var DEFAULT_STATE = {
    version: 2,
    lastPage: null,
    bookmarks: {},
    keyWords: {},
    notes: {},
  };

  function $(sel, root) { return (root || document).querySelector(sel); }
  function $$(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }
  function escapeHtml(text) {
    return String(text).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function loadState() {
    try {
      var raw = localStorage.getItem(STORE_KEY);
      if (!raw) return Object.assign({}, DEFAULT_STATE);
      var parsed = JSON.parse(raw);
      return {
        version: 2,
        lastPage: parsed.lastPage || null,
        bookmarks: parsed.bookmarks && typeof parsed.bookmarks === "object" ? parsed.bookmarks : {},
        keyWords: parsed.keyWords && typeof parsed.keyWords === "object" ? parsed.keyWords : {},
        notes: parsed.notes && typeof parsed.notes === "object" ? parsed.notes : {},
      };
    } catch (e) {
      return Object.assign({}, DEFAULT_STATE);
    }
  }

  var state = loadState();
  function saveState() {
    try { localStorage.setItem(STORE_KEY, JSON.stringify(state)); } catch (e) { /* file:// or private mode */ }
  }

  var pages = $$(".reader-page");
  var pageById = {};
  pages.forEach(function (p) { pageById[p.id] = p; });
  var wordEls = $$(".word-section");
  var wordById = {};
  wordEls.forEach(function (w) { wordById[w.id] = w; });

  var currentPage = null;
  var searchIndex = null;

  var topbarCrumb = $("#topbar-crumb");
  var pageIndicator = $("#page-indicator");
  var prevBtn = $("#page-prev");
  var nextBtn = $("#page-next");
  var continueBtn = $("#continue-btn");
  var bookmarkCount = $("#bookmark-count");
  var searchOverlay = $("#search-overlay");
  var searchInput = $("#search-input");
  var searchResults = $("#search-results");
  var bookmarksOverlay = $("#bookmarks-overlay");
  var bookmarkList = $("#bookmark-list");
  var dataOverlay = $("#data-overlay");
  var dataStatus = $("#data-status");
  var sidebar = $("#sidebar");

  function pageMeta(page) {
    return {
      unit: page.dataset.unit || "",
      p: page.dataset.p || "",
      group: page.dataset.group || "",
    };
  }

  function wordMeta(el) {
    var page = el.closest(".reader-page");
    return {
      id: el.id,
      word: ((el.querySelector(".word-heading") || {}).textContent || "").trim(),
      pageId: page ? page.id : "",
      unit: page ? (page.dataset.unit || "") : "",
      p: page ? (page.dataset.p || "") : "",
      group: page ? (page.dataset.group || "") : "",
    };
  }

  function updateChrome() {
    if (!currentPage) return;
    var isCover = currentPage.id === "page-cover";
    topbarCrumb.textContent = isCover
      ? "封面"
      : [currentPage.dataset.unit, currentPage.dataset.p].filter(Boolean).join(" · ");
    var idx = pages.indexOf(currentPage);
    pageIndicator.textContent = (idx + 1) + " / " + pages.length;
    prevBtn.disabled = idx <= 0;
    nextBtn.disabled = idx >= pages.length - 1;
    var hasLast = state.lastPage && pageById[state.lastPage] && currentPage.id !== state.lastPage;
    continueBtn.hidden = !hasLast;
    if (hasLast) {
      var lp = pageById[state.lastPage];
      continueBtn.textContent = "继续阅读";
      continueBtn.title = "继续阅读：" + [lp.dataset.unit, lp.dataset.p].filter(Boolean).join(" · ");
    }
    var count = Object.keys(state.bookmarks).filter(function (id) { return wordById[id]; }).length;
    bookmarkCount.textContent = String(count);
  }

  function openToc(page, wordId) {
    $$(".toc-unit, .toc-p, .toc-group-details").forEach(function (d) { d.open = false; });
    $$(".toc-page, .toc-word").forEach(function (a) { a.classList.remove("active"); });
    if (!page || page.id === "page-cover") return;
    var p = page.dataset.p;
    var pNode = p ? $('.toc-p[data-p="' + p + '"]') : null;
    if (pNode) {
      pNode.open = true;
      var unit = pNode.closest(".toc-unit");
      if (unit) unit.open = true;
      var groupDetails = pNode.querySelector('.toc-group-details[data-page="' + page.id + '"]');
      if (groupDetails) groupDetails.open = true;
    }
    var groupLink = $('.toc-page[data-page="' + page.id + '"]');
    if (groupLink) groupLink.classList.add("active");
    if (wordId) {
      var wordLink = $('.toc-word[data-word="' + wordId + '"]');
      if (wordLink) wordLink.classList.add("active");
    }
  }

  function enhanceToc() {
    $$(".toc-p").forEach(function (p) {
      p.addEventListener("toggle", function () {
        if (!p.open) return;
        if (p.querySelector(".toc-group-details[open]")) return;
        var firstGroup = p.querySelector(".toc-group-details");
        if (firstGroup) firstGroup.open = true;
      });
    });
    $$(".toc-group-link").forEach(function (a) {
      a.addEventListener("click", function (e) {
        e.preventDefault();
        e.stopPropagation();
        showPage(a.getAttribute("data-page"));
      });
    });
  }

  function showPage(id, wordId) {
    var page = pageById[id];
    if (wordId && wordById[wordId]) {
      var wp = wordById[wordId].closest(".reader-page");
      if (wp) page = wp;
    }
    if (!page) page = pageById["page-cover"] || pages[0];
    if (!page) return;
    pages.forEach(function (p) { p.classList.toggle("active", p === page); });
    currentPage = page;
    if (page.id !== "page-cover") {
      state.lastPage = page.id;
      saveState();
    }
    updateChrome();
    openToc(page, wordId);
    try { history.replaceState(null, "", "#" + page.id); } catch (e) { /* file:// */ }
    window.scrollTo({ top: 0, behavior: "auto" });
    if (wordId && wordById[wordId]) {
      setTimeout(function () {
        var el = wordById[wordId];
        if (!el) return;
        var bar = document.querySelector(".reader-topbar");
        var offset = (bar ? bar.offsetHeight : 0) + 10;
        var target = el.querySelector(".core-meaning") || el.querySelector(".word-note-display") || el;
        var y = target.getBoundingClientRect().top + window.scrollY - offset;
        window.scrollTo({ top: Math.max(0, y), behavior: "auto" });
        el.classList.add("flash");
        setTimeout(function () { el.classList.remove("flash"); }, 1300);
      }, 30);
    }
    closeDrawers();
    closeSidebar();
  }

  function closeSidebar() { sidebar.classList.remove("open"); }
  function closeDrawers() {
    [searchOverlay, bookmarksOverlay, dataOverlay].forEach(function (el) { if (el) el.hidden = true; });
    closeSidebar();
  }

  function firstReadingPage() {
    var first = pages.filter(function (p) { return p.id !== "page-cover"; })[0];
    return first ? first.id : "page-cover";
  }

  /* ---- navigation ---- */
  if (prevBtn) prevBtn.addEventListener("click", function () {
    var idx = pages.indexOf(currentPage);
    if (idx > 0) showPage(pages[idx - 1].id);
  });
  if (nextBtn) nextBtn.addEventListener("click", function () {
    var idx = pages.indexOf(currentPage);
    if (idx >= 0 && idx < pages.length - 1) showPage(pages[idx + 1].id);
  });
  if (continueBtn) continueBtn.addEventListener("click", function () {
    if (state.lastPage && pageById[state.lastPage]) showPage(state.lastPage);
  });
  var coverBtn = $("#cover-btn");
  if (coverBtn) coverBtn.addEventListener("click", function () { showPage("page-cover"); });
  var startBtn = $("#start-reading");
  if (startBtn) startBtn.addEventListener("click", function () { showPage(firstReadingPage()); });
  var menuBtn = $("#menu-btn");
  if (menuBtn) menuBtn.addEventListener("click", function () {
    if (window.matchMedia && window.matchMedia("(max-width: 790px)").matches) {
      sidebar.classList.toggle("open");
    } else {
      var app = document.querySelector(".app");
      if (app) app.classList.toggle("sidebar-collapsed");
    }
  });

  document.addEventListener("click", function (e) {
    var target = e.target.closest("[data-page]");
    if (!target) return;
    var pageId = target.getAttribute("data-page");
    if (!pageId || !pageById[pageId]) return;
    e.preventDefault();
    showPage(pageId, target.getAttribute("data-word") || null);
  });

  /* ---- search ---- */
  function cleanText(root) {
    var clone = root.cloneNode(true);
    clone.querySelectorAll(".word-tools, .word-note, .word-note-display").forEach(function (el) { el.remove(); });
    return clone.textContent || "";
  }
  function buildSearchIndex() {
    if (searchIndex) return searchIndex;
    var entries = { pages: [], words: [] };
    pages.forEach(function (page) {
      if (page.id === "page-cover") return;
      var meta = pageMeta(page);
      var heading = page.querySelector(".chapter-heading");
      var title = heading ? heading.textContent.trim() : page.id;
      var text = cleanText(page);
      entries.pages.push({ id: page.id, title: title, text: text, lower: text.toLowerCase(), unit: meta.unit, p: meta.p, group: meta.group });
      $$(".word-section", page).forEach(function (wordEl) {
        var wm = wordMeta(wordEl);
        var wt = cleanText(wordEl);
        entries.words.push({ id: wm.id, word: wm.word, text: wt, lower: wt.toLowerCase(), pageId: page.id, unit: meta.unit, p: meta.p, group: meta.group });
      });
    });
    searchIndex = entries;
    return searchIndex;
  }

  function snippet(text, query) {
    var lower = text.toLowerCase();
    var at = lower.indexOf(query.toLowerCase());
    if (at < 0) at = 0;
    var start = Math.max(0, at - 34);
    var end = Math.min(text.length, at + query.length + 64);
    return (start > 0 ? "…" : "") + text.slice(start, end) + (end < text.length ? "…" : "");
  }

  function markedSnippet(text, query) {
    var lower = text.toLowerCase();
    var at = lower.indexOf(query.toLowerCase());
    if (at < 0) return escapeHtml(text);
    var before = text.slice(0, at);
    var hit = text.slice(at, at + query.length);
    var after = text.slice(at + query.length);
    return escapeHtml(before) + "<mark>" + escapeHtml(hit) + "</mark>" + escapeHtml(after);
  }

  function resultButton(hit, kind) {
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "search-result";
    btn.setAttribute("data-page", hit.pageId || hit.id);
    if (kind === "word") btn.setAttribute("data-word", hit.id);
    var title = document.createElement("span");
    title.className = "sr-title";
    title.textContent = kind === "word" ? hit.word : hit.title;
    var meta = document.createElement("span");
    meta.className = "sr-meta";
    meta.textContent = [hit.unit, hit.p, hit.group].filter(Boolean).join(" · ");
    var snip = document.createElement("span");
    snip.className = "sr-snippet";
    snip.innerHTML = markedSnippet(snippet(hit.text, currentQuery), currentQuery);
    btn.appendChild(title);
    btn.appendChild(meta);
    btn.appendChild(snip);
    return btn;
  }

  var currentQuery = "";
  function runSearch() {
    var query = searchInput.value.trim();
    currentQuery = query;
    searchResults.innerHTML = "";
    if (!query) {
      searchResults.innerHTML = '<div class="search-empty">输入英文或中文关键词，例如 novel、精确、保证。</div>';
      return;
    }
    var idx = buildSearchIndex();
    var tokens = query.toLowerCase().split(/\s+/).filter(Boolean);
    var wordHits = idx.words.filter(function (w) {
      return tokens.every(function (t) { return w.lower.indexOf(t) >= 0; });
    });
    var exact = query.toLowerCase();
    wordHits.sort(function (a, b) {
      function score(w) {
        var word = (w.word || "").toLowerCase();
        if (word === exact) return 0;
        if (word.indexOf(exact) === 0) return 1;
        if (word.indexOf(exact) >= 0) return 2;
        return 3;
      }
      return score(a) - score(b) || a.word.localeCompare(b.word);
    });
    wordHits = wordHits.slice(0, 20);
    var wordPageIds = {};
    wordHits.forEach(function (w) { wordPageIds[w.pageId] = true; });
    var pageHits = idx.pages.filter(function (p) {
      if (wordPageIds[p.id]) return false;
      return tokens.every(function (t) { return p.lower.indexOf(t) >= 0; });
    }).slice(0, 15);
    if (!wordHits.length && !pageHits.length) {
      searchResults.innerHTML = '<div class="search-empty">没有找到匹配内容。</div>';
      return;
    }
    wordHits.forEach(function (w) { searchResults.appendChild(resultButton(w, "word")); });
    pageHits.forEach(function (p) { searchResults.appendChild(resultButton(p, "page")); });
  }

  function openSearch() {
    buildSearchIndex();
    searchOverlay.hidden = false;
    if (searchInput.value.trim()) runSearch();
    setTimeout(function () { searchInput.focus(); }, 20);
  }
  var searchOpen = $("#search-open");
  if (searchOpen) searchOpen.addEventListener("click", openSearch);
  if (searchInput) {
    var searchTimer = null;
    searchInput.addEventListener("input", function () {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(runSearch, 80);
    });
    searchInput.addEventListener("keydown", function (e) {
      if (e.key === "Enter") { clearTimeout(searchTimer); runSearch(); }
    });
  }

  /* ---- bookmarks, key marks, notes ---- */
  function applyWordState(meta) {
    var el = wordById[meta.id];
    if (!el) return;
    var bookmark = $(".word-tool.bookmark", el);
    var key = $(".word-tool.key", el);
    var display = $(".word-note-display", el);
    var note = state.notes[meta.id] || "";
    if (bookmark) {
      bookmark.textContent = state.bookmarks[meta.id] ? "★" : "☆";
      bookmark.classList.toggle("on", !!state.bookmarks[meta.id]);
      bookmark.title = state.bookmarks[meta.id] ? "取消书签" : "加入书签";
    }
    if (key) {
      key.classList.toggle("on", !!state.keyWords[meta.id]);
      key.title = state.keyWords[meta.id] ? "取消重点" : "标记重点";
    }
    el.classList.toggle("is-key", !!state.keyWords[meta.id]);
    if (display) {
      display.textContent = note;
      display.hidden = !note;
    }
  }

  function enhanceWord(el) {
    if (el.dataset.enhanced) return;
    el.dataset.enhanced = "1";
    var meta = wordMeta(el);
    var tools = document.createElement("div");
    tools.className = "word-tools";
    tools.innerHTML = '<button type="button" class="word-tool bookmark" title="加入书签">☆</button>' +
      '<button type="button" class="word-tool key" title="标记重点">重点</button>' +
      '<button type="button" class="word-tool note" title="写批注">批注</button>';
    el.appendChild(tools);

    var display = document.createElement("div");
    display.className = "word-note-display";
    display.hidden = true;
    var editor = document.createElement("div");
    editor.className = "word-note";
    editor.hidden = true;
    editor.innerHTML = '<textarea placeholder="写一句短批注，只保存在本机阅读数据中。"></textarea>' +
      '<div class="word-note-actions"><button type="button" class="primary note-save">保存</button>' +
      '<button type="button" class="note-cancel">取消</button>' +
      '<button type="button" class="note-delete">删除</button></div>';
    var heading = el.querySelector(".word-heading");
    if (heading && heading.nextSibling) {
      el.insertBefore(display, heading.nextSibling);
      el.insertBefore(editor, heading.nextSibling);
    } else {
      el.appendChild(display);
      el.appendChild(editor);
    }

    var bookmark = $(".bookmark", tools);
    var key = $(".key", tools);
    var noteBtn = $(".note", tools);
    var textarea = editor.querySelector("textarea");

    bookmark.addEventListener("click", function () {
      if (state.bookmarks[meta.id]) delete state.bookmarks[meta.id];
      else state.bookmarks[meta.id] = meta;
      saveState();
      applyWordState(meta);
      renderBookmarks();
      updateChrome();
    });
    key.addEventListener("click", function () {
      if (state.keyWords[meta.id]) delete state.keyWords[meta.id];
      else state.keyWords[meta.id] = true;
      saveState();
      applyWordState(meta);
    });
    noteBtn.addEventListener("click", function () {
      editor.hidden = false;
      textarea.value = state.notes[meta.id] || "";
      textarea.focus();
    });
    editor.querySelector(".note-cancel").addEventListener("click", function () { editor.hidden = true; });
    editor.querySelector(".note-save").addEventListener("click", function () {
      var value = textarea.value.trim();
      if (value) state.notes[meta.id] = value;
      else delete state.notes[meta.id];
      saveState();
      applyWordState(meta);
      editor.hidden = true;
    });
    editor.querySelector(".note-delete").addEventListener("click", function () {
      delete state.notes[meta.id];
      saveState();
      applyWordState(meta);
      textarea.value = "";
      editor.hidden = true;
    });

    applyWordState(meta);
  }

  function renderBookmarks() {
    if (!bookmarkList) return;
    var items = Object.keys(state.bookmarks).map(function (id) { return state.bookmarks[id]; });
    items = items.filter(function (b) { return b && wordById[b.id]; });
    bookmarkList.innerHTML = "";
    if (!items.length) {
      bookmarkList.innerHTML = '<div class="search-empty">还没有书签。点词条右上角的 ☆ 即可收藏。</div>';
    } else {
      items.forEach(function (b) {
        var row = document.createElement("div");
        row.className = "bookmark-item";
        var open = document.createElement("button");
        open.type = "button";
        open.className = "bookmark-open";
        open.setAttribute("data-page", b.pageId);
        open.setAttribute("data-word", b.id);
        open.innerHTML = "<b>" + escapeHtml(b.word) + "</b><small>" +
          escapeHtml([b.unit, b.p, b.group].filter(Boolean).join(" · ")) + "</small>";
        var remove = document.createElement("button");
        remove.type = "button";
        remove.className = "bookmark-remove";
        remove.textContent = "移除";
        remove.addEventListener("click", function () {
          delete state.bookmarks[b.id];
          saveState();
          applyWordState(b);
          renderBookmarks();
          updateChrome();
        });
        row.appendChild(open);
        row.appendChild(remove);
        bookmarkList.appendChild(row);
      });
    }
    updateChrome();
  }

  /* ---- data backup / restore ---- */
  function refreshDataStatus() {
    if (!dataStatus) return;
    dataStatus.textContent = "数据只保存在本机浏览器，与 Markdown 分离。书签 " +
      Object.keys(state.bookmarks).length + " 个，重点 " +
      Object.keys(state.keyWords).length + " 个，批注 " + Object.keys(state.notes).length + " 条。";
  }
  function openData() {
    refreshDataStatus();
    dataOverlay.hidden = false;
  }
  function downloadData() {
    var docTitle = (document.title || "ebook").replace(/[^\w\u4e00-\u9fff]+/g, "-").replace(/^-+|-+$/g, "") || "ebook";
    var payload = { app: "Markdown·电子教辅", title: docTitle, version: 2, exportedAt: new Date().toISOString(), state: state };
    var blob = new Blob([JSON.stringify(payload, null, 2)], { type: "application/json" });
    var url = URL.createObjectURL(blob);
    var a = document.createElement("a");
    var d = new Date();
    var stamp = d.getFullYear() + String(d.getMonth() + 1).padStart(2, "0") + String(d.getDate()).padStart(2, "0");
    a.href = url;
    a.download = docTitle + "-阅读数据-" + stamp + ".json";
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
  }
  function importData(file) {
    var reader = new FileReader();
    reader.onload = function () {
      try {
        var data = JSON.parse(reader.result);
        if (!data || !data.state || typeof data.state !== "object") throw new Error("bad file");
        state = {
          version: 2,
          lastPage: data.state.lastPage || null,
          bookmarks: data.state.bookmarks || {},
          keyWords: data.state.keyWords || {},
          notes: data.state.notes || {},
        };
        saveState();
        location.reload();
      } catch (e) {
        alert("导入失败：文件不是本阅读器的备份。");
      }
    };
    reader.readAsText(file);
  }
  function resetData() {
    if (!window.confirm("清空本机阅读数据（书签、重点、批注、阅读位置）？Markdown 不会受影响。")) return;
    try { localStorage.removeItem(STORE_KEY); } catch (e) { /* ignore */ }
    location.reload();
  }

  var dataOpen = $("#data-open");
  if (dataOpen) dataOpen.addEventListener("click", openData);
  var exportBtn = $("#data-export");
  if (exportBtn) exportBtn.addEventListener("click", downloadData);
  var importBtn = $("#data-import");
  var importInput = $("#data-import-file");
  if (importBtn && importInput) {
    importBtn.addEventListener("click", function () { importInput.click(); });
    importInput.addEventListener("change", function () {
      if (importInput.files && importInput.files[0]) importData(importInput.files[0]);
      importInput.value = "";
    });
  }
  var resetBtn = $("#data-reset");
  if (resetBtn) resetBtn.addEventListener("click", resetData);

  var bookmarksOpen = $("#bookmarks-open");
  if (bookmarksOpen) bookmarksOpen.addEventListener("click", function () {
    renderBookmarks();
    bookmarksOverlay.hidden = false;
  });

  $$("[data-close]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var id = btn.getAttribute("data-close");
      var el = document.getElementById(id + "-overlay");
      if (el) el.hidden = true;
    });
  });
  $$(".reader-overlay").forEach(function (el) {
    el.addEventListener("click", function (e) { if (e.target === el) el.hidden = true; });
  });

  document.addEventListener("keydown", function (e) {
    var tag = (e.target && e.target.tagName || "").toLowerCase();
    if (tag === "input" || tag === "textarea" || tag === "select") return;
    if (e.key === "/") { e.preventDefault(); openSearch(); return; }
    if (e.key === "Escape") { closeDrawers(); return; }
    if (e.key === "ArrowLeft" && !prevBtn.disabled) { prevBtn.click(); }
    if (e.key === "ArrowRight" && !nextBtn.disabled) { nextBtn.click(); }
  });

  /* ---- initial state ---- */
  enhanceToc();
  wordEls.forEach(enhanceWord);
  renderBookmarks();
  var hash = location.hash ? location.hash.slice(1) : "";
  if (pageById[hash]) showPage(hash);
  else if (wordById[hash]) showPage(wordById[hash].closest(".reader-page").id, hash);
  else if (state.lastPage && pageById[state.lastPage]) showPage(state.lastPage);
  else showPage("page-cover");
  updateChrome();
})();
