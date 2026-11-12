/* ==========================================================================
   全栈面试知识库 · 静态站逻辑
   设计约束：无 emoji 图标、无渐变、无阴影、无卡片；只用文字、表格与留白。
   依赖：marked（Markdown 渲染，CDN）
   数据：manifest.json（tools/build-manifest.ps1 生成）
   路由：#/<文档相对路径>
   ========================================================================== */

(function () {
  'use strict';

  /* ---------------- 分区（顺序即侧栏顺序：后端在前，前端在后） ---------------- */
  var SECTIONS = [
    { id: 'start', title: '开始' },
    { id: 'plan', title: '学习计划' },
    { id: 'deep-index', title: '深度追问总览' },
    { id: 'deep-java', title: 'Java 底层' },
    { id: 'deep-spring', title: 'Spring' },
    { id: 'deep-mysql', title: 'MySQL' },
    { id: 'deep-redis', title: 'Redis' },
    { id: 'deep-middleware', title: '消息与中间件' },
    { id: 'deep-distributed', title: '分布式' },
    { id: 'deep-network', title: '网络协议' },
    { id: 'deep-ops', title: '运维与可观测' },
    { id: 'deep-backend', title: '后端优化' },
    { id: 'deep-js', title: 'JS / ES6' },
    { id: 'breadth-java', title: 'Java / Spring 八股' },
    { id: 'breadth-db', title: '数据库八股' },
    { id: 'breadth-net', title: '网络八股' },
    { id: 'breadth-design', title: '系统设计' },
    { id: 'breadth-algo', title: '算法与手写' },
    { id: 'breadth-js', title: 'JS / TS 八股' },
    { id: 'breadth-vue', title: 'Vue' },
    { id: 'breadth-project', title: '项目与简历' },
    { id: 'breadth-mock', title: '模拟面试' },
    { id: 'other', title: '其他' }
  ];

  /* ---------------- 首页推荐顺序（后端优先） ---------------- */
  var RECOMMENDED = [
    { path: '10-deep-dive/spring/03-事务传播与失效.md', why: 'Java 后端必问，且最容易答不到第二层' },
    { path: '10-deep-dive/java/01-HashMap.md', why: 'Java 基础是否扎实的分水岭' },
    { path: '10-deep-dive/mysql/01-B+树索引.md', why: '简历写了 SQL 优化，必被追问执行计划' },
    { path: '10-deep-dive/redis/03-缓存三件套与一致性.md', why: '穿透、击穿、雪崩混为一谈是常见扣分点' },
    { path: '10-deep-dive/spring/05-SpringMVC请求链路.md', why: '一次请求怎么走完 Spring，追问的入口' },
    { path: '10-deep-dive/java/08-线程池.md', why: '线程池参数与执行流程，后端高频' },
    { path: '10-deep-dive/middleware/04-MyBatis原理.md', why: '实习简历写了 MyBatis，几乎没有应届生能讲清' }
  ];

  var REPO_URL = 'https://github.com/NJHTR/baguwen';
  var REPO_BRANCH = 'main';

  /* ---------------- 工具 ---------------- */
  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function debounce(fn, ms) {
    var t; return function () { var a = arguments, c = this; clearTimeout(t); t = setTimeout(function () { fn.apply(c, a); }, ms); };
  }
  function store(key, val) {
    try {
      if (val === undefined) return localStorage.getItem(key);
      localStorage.setItem(key, val);
    } catch (e) { /* 忽略隐私模式异常 */ }
    return null;
  }
  function sectionOf(id) {
    for (var i = 0; i < SECTIONS.length; i++) if (SECTIONS[i].id === id) return SECTIONS[i];
    return { id: id, title: '其他' };
  }

  var state = { manifest: null, files: [], byPath: {}, flat: [], current: null, mdCache: {} };

  /* ---------------- 路由 ---------------- */
  function currentHashPath() {
    var h = location.hash || '';
    if (h.indexOf('#/') !== 0) return '';
    var raw = h.slice(2);
    try { return decodeURIComponent(raw); } catch (e) { return raw; }
  }
  function routeTo(path) { location.hash = '#/' + encodeURI(path); }

  /* ---------------- 相对路径 ---------------- */
  function resolveRel(basePath, rel) {
    if (/^[a-z][a-z0-9+.-]*:/i.test(rel)) return { external: true, url: rel };
    if (rel.charAt(0) === '#') return { anchor: rel.slice(1) };
    if (rel.charAt(0) === '/') return { path: rel.slice(1) };
    var stack = basePath.split('/').slice(0, -1);
    rel.split('/').forEach(function (p) {
      if (p === '.' || p === '') return;
      if (p === '..') stack.pop(); else stack.push(p);
    });
    return { path: stack.join('/') };
  }

  /* ---------------- 侧栏 ---------------- */
  function buildSidebar() {
    var groups = {};
    state.files.forEach(function (f) { (groups[f.section] = groups[f.section] || []).push(f); });
    var html = '';
    SECTIONS.forEach(function (sec) {
      var items = groups[sec.id];
      if (!items || !items.length) return;
      html += '<div class="nav-group" data-section="' + sec.id + '">' +
        '<button type="button"><span>' + esc(sec.title) + '</span>' +
        '<span class="count">' + items.length + '</span></button>' +
        '<div class="nav-items">';
      items.forEach(function (f) {
        html += '<a class="nav-item" href="#/' + encodeURI(f.path) + '" data-path="' + esc(f.path) + '">' + esc(f.title) + '</a>';
      });
      html += '</div></div>';
    });
    var sidebar = $('#sidebar');
    sidebar.innerHTML = html;
    sidebar.addEventListener('click', function (e) {
      var btn = e.target.closest('.nav-group > button');
      if (btn) btn.parentNode.classList.toggle('collapsed');
    });
  }

  function markActiveNav(path) {
    $$('.nav-item').forEach(function (a) {
      var on = a.getAttribute('data-path') === path;
      a.classList.toggle('active', on);
      if (on) {
        var g = a.closest('.nav-group');
        if (g) g.classList.remove('collapsed');
        a.scrollIntoView({ block: 'nearest' });
      }
    });
  }

  /* ---------------- 搜索 ---------------- */
  function initSearch() {
    var input = $('#search');
    var doFilter = debounce(function () {
      var q = input.value.trim().toLowerCase();
      var shown = 0;
      $$('.nav-item').forEach(function (a) {
        var meta = state.byPath[a.getAttribute('data-path')] || {};
        var hit = !q || a.textContent.toLowerCase().indexOf(q) >= 0 ||
          String(meta.summary || '').toLowerCase().indexOf(q) >= 0;
        a.style.display = hit ? '' : 'none';
        if (hit) shown++;
      });
      $$('.nav-group').forEach(function (g) {
        var visible = $$('.nav-item', g).filter(function (a) { return a.style.display !== 'none'; }).length;
        g.style.display = visible ? '' : 'none';
        if (q) g.classList.remove('collapsed');
        var cnt = $('.count', g);
        if (cnt) cnt.textContent = q ? visible : $$('.nav-item', g).length;
      });
      var hint = $('#searchHint');
      if (hint) hint.textContent = q ? '匹配 ' + shown + ' 条' : '';
    }, 120);
    input.addEventListener('input', doFilter);
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') {
        var first = $$('.nav-item').filter(function (a) { return a.style.display !== 'none'; })[0];
        if (first) { routeTo(first.getAttribute('data-path')); input.blur(); }
      }
      if (e.key === 'Escape') { input.value = ''; doFilter(); input.blur(); }
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === '/' && document.activeElement !== input) { e.preventDefault(); input.focus(); }
    });
  }

  /* ---------------- 首页 ---------------- */
  function renderHome() {
    state.current = null;
    markActiveNav(null);
    buildToc([]);
    document.title = '全栈面试知识库';

    var stats = (state.manifest && state.manifest.stats) || { files: state.files.length, lines: 0 };
    var last = store('lastDoc');
    var lastFile = last && state.byPath[last];

    var html = '<div class="home-head">' +
      '<h1>全栈面试知识库</h1>' +
      '<p>以后端为主的全栈面试资料。每个知识点单独一个文件，从一句话答案（L1）逐层追问到源码与内核（L5），每个文件附 10 层以上追问树与名词拆解表。</p>' +
      '<div class="home-stats">' +
        '<span><b>' + stats.files + '</b> 篇</span>' +
        '<span><b>' + (stats.lines || 0).toLocaleString() + '</b> 行</span>' +
        '<span><b>' + deepCount() + '</b> 个深度知识点</span>' +
        '<span>最长追问 <b>' + 15 + '</b> 层</span>' +
      '</div>' +
      (lastFile ? '<div class="home-stats" style="margin-top:14px"><span>上次读到 <a href="#/' + encodeURI(lastFile.path) + '">' + esc(lastFile.title) + '</a></span></div>' : '') +
      '</div>';

    html += '<div class="block"><div class="block-title">从哪里开始</div><div class="start-list">';
    var n = 0;
    RECOMMENDED.forEach(function (r) {
      var f = state.byPath[r.path];
      if (!f) return;
      n += 1;
      html += '<a class="start-item" href="#/' + encodeURI(f.path) + '">' +
        '<span class="rank">' + (n < 10 ? '0' + n : n) + '</span>' +
        '<span><span class="s-title">' + esc(f.title) + '</span>' +
        '<span class="s-why">' + esc(r.why) + '</span></span>' +
        '<span class="s-meta">' + f.lines + ' 行</span></a>';
    });
    html += '</div></div>';

    SECTIONS.forEach(function (sec) {
      var items = state.files.filter(function (f) { return f.section === sec.id; });
      if (!items.length) return;
      html += '<div class="block"><div class="block-title">' + esc(sec.title) + ' · ' + items.length + ' 篇</div>' +
        '<table class="index-table"><thead><tr><th>标题</th><th class="col-desc">摘要</th><th class="col-lines">行数</th></tr></thead><tbody>';
      items.forEach(function (f) {
        html += '<tr><td><a href="#/' + encodeURI(f.path) + '">' + esc(f.title) + '</a></td>' +
          '<td class="col-desc">' + esc(f.summary || '') + '</td>' +
          '<td class="col-lines">' + f.lines + '</td></tr>';
      });
      html += '</tbody></table></div>';
    });

    $('#content').innerHTML = html;
    window.scrollTo(0, 0);
    updateProgress();
  }

  function deepCount() {
    return state.files.filter(function (f) {
      return f.section.indexOf('deep-') === 0 && f.section !== 'deep-index';
    }).length;
  }

  /* ---------------- 目录 ---------------- */
  function buildToc(items) {
    var toc = $('#toc');
    if (!items.length) { toc.innerHTML = ''; return; }
    var html = '<div class="toc-title">本页目录</div>';
    items.forEach(function (it) {
      html += '<a href="#' + encodeURI(it.id) + '" class="' + (it.level === 3 ? 'lv3' : '') + '" data-target="' + esc(it.id) + '">' + esc(it.text) + '</a>';
    });
    toc.innerHTML = html;
    toc.onclick = function (e) {
      var a = e.target.closest('a[data-target]');
      if (!a) return;
      e.preventDefault();
      var el = document.getElementById(a.getAttribute('data-target'));
      if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
    };
  }

  function slugify(text, used) {
    var base = text.trim().toLowerCase()
      .replace(/[`*_~\[\]()#>]/g, '')
      .replace(/[^\w\u4e00-\u9fa5\- ]/g, '')
      .replace(/\s+/g, '-')
      .slice(0, 60) || 'section';
    var id = base, n = 2;
    while (used[id]) { id = base + '-' + n++; }
    used[id] = true;
    return id;
  }

  function enhanceContent(root, basePath) {
    var firstH1 = root.querySelector('h1');
    if (firstH1 && root.firstElementChild === firstH1) firstH1.remove();

    var used = {}, tocItems = [];
    $$('h2, h3', root).forEach(function (h) {
      var id = slugify(h.textContent, used);
      h.id = id;
      var a = document.createElement('a');
      a.className = 'anchor';
      a.href = '#' + encodeURI(id);
      a.textContent = '#';
      h.appendChild(a);
      tocItems.push({ id: id, text: h.textContent.replace(/#$/, '').trim(), level: h.tagName === 'H3' ? 3 : 2 });
    });

    $$('table', root).forEach(function (t) {
      var wrap = document.createElement('div');
      wrap.className = 'table-wrap';
      t.parentNode.insertBefore(wrap, t);
      wrap.appendChild(t);
    });

    $$('pre', root).forEach(function (pre) {
      var btn = document.createElement('button');
      btn.className = 'copy-btn';
      btn.type = 'button';
      btn.textContent = '复制';
      btn.addEventListener('click', function () {
        var code = pre.querySelector('code');
        var text = code ? code.innerText : pre.innerText;
        if (navigator.clipboard) {
          navigator.clipboard.writeText(text).then(function () {
            btn.textContent = '已复制'; btn.classList.add('done');
            setTimeout(function () { btn.textContent = '复制'; btn.classList.remove('done'); }, 1400);
          });
        }
      });
      pre.appendChild(btn);
    });

    $$('a[href]', root).forEach(function (a) {
      var href = a.getAttribute('href');
      if (!href || /^[a-z][a-z0-9+.-]*:/i.test(href)) return;
      if (href.charAt(0) === '#') return;
      var r = resolveRel(basePath, href);
      if (r.path) a.setAttribute('href', '#/' + encodeURI(r.path));
    });
    $$('img[src]', root).forEach(function (img) {
      var src = img.getAttribute('src');
      if (!src || /^[a-z][a-z0-9+.-]*:/i.test(src)) return;
      var r = resolveRel(basePath, src);
      if (r.path) img.setAttribute('src', r.path);
    });

    return tocItems;
  }

  /* ---------------- 文档 ---------------- */
  function renderDoc(path) {
    var file = state.byPath[path];
    if (!file) { renderError('找不到这篇文档：' + path, '可能被重命名，请回首页重新选择。'); return; }
    state.current = path;
    store('lastDoc', path);
    markActiveNav(path);
    document.title = file.title + ' · 全栈面试知识库';
    closeSidebar();

    var sec = sectionOf(file.section);
    var idx = state.flat.indexOf(path);
    var prev = idx > 0 ? state.byPath[state.flat[idx - 1]] : null;
    var next = idx >= 0 && idx < state.flat.length - 1 ? state.byPath[state.flat[idx + 1]] : null;
    var ghUrl = REPO_URL + '/blob/' + REPO_BRANCH + '/' + file.path.split('/').map(encodeURIComponent).join('/');

    $('#content').innerHTML =
      '<div class="crumbs"><a href="#/">首页</a><span class="sep">/</span>' + esc(sec.title) + '</div>' +
      '<div class="doc-head"><h1>' + esc(file.title) + '</h1>' +
        '<div class="doc-meta"><span>' + esc(sec.title) + '</span><span class="dot">·</span>' +
        '<span>' + file.lines + ' 行</span><span class="dot">·</span>' +
        '<a href="' + ghUrl + '" target="_blank" rel="noopener">GitHub 原文</a></div></div>' +
      '<article class="prose" id="prose"><div class="loading">加载中</div></article>' +
      '<nav class="pager">' +
        (prev ? '<a class="prev" href="#/' + encodeURI(prev.path) + '"><span class="dir">上一篇</span><span class="p-title">' + esc(prev.title) + '</span></a>' : '<span class="spacer"></span>') +
        (next ? '<a class="next" href="#/' + encodeURI(next.path) + '"><span class="dir">下一篇</span><span class="p-title">' + esc(next.title) + '</span></a>' : '<span class="spacer"></span>') +
      '</nav>';

    if (state.mdCache[path]) { paintDoc(state.mdCache[path], path); return; }

    fetch(encodeURI(path), { cache: 'no-cache' })
      .then(function (res) {
        if (!res.ok) throw new Error('HTTP ' + res.status);
        return res.text();
      })
      .then(function (text) {
        state.mdCache[path] = text;
        if (state.current === path) paintDoc(text, path);
      })
      .catch(function (err) {
        var hint = location.protocol === 'file:'
          ? '当前以 file:// 打开，浏览器禁止本地 fetch。请用静态服务器（如 python -m http.server）或直接访问线上站点。'
          : '请确认该文件已提交到仓库。';
        renderError('加载失败：' + err.message, hint);
      });
  }

  function paintDoc(text, path) {
    var prose = $('#prose');
    if (!prose) return;
    var html;
    try { html = window.marked ? marked.parse(text) : '<pre>' + esc(text) + '</pre>'; }
    catch (e) { html = '<pre>' + esc(text) + '</pre>'; }
    prose.innerHTML = html;
    var tocItems = enhanceContent(prose, path);
    buildToc(tocItems);
    bindDocumentEvents(prose);
    window.scrollTo(0, 0);
    updateProgress();
  }

  function bindDocumentEvents(root) {
    root.addEventListener('click', function (e) {
      var anchor = e.target.closest('a');
      if (!anchor) return;
      var href = anchor.getAttribute('href') || '';
      if (href.indexOf('#/') === 0) return;
      if (href.charAt(0) === '#') {
        e.preventDefault();
        var el = document.getElementById(decodeURIComponent(href.slice(1)));
        if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }
    });
  }

  function renderError(msg, hint) {
    $('#content').innerHTML = '<div class="error-box"><strong>' + esc(msg) + '</strong><p>' + esc(hint || '') + '</p></div>';
  }

  /* ---------------- 滚动：进度线 + 目录高亮 ---------------- */
  function bindScrollSpy() {
    window.addEventListener('scroll', function () {
      updateProgress();
      var headings = $$('#prose h2, #prose h3');
      if (!headings.length) return;
      var currentId = headings[0].id;
      for (var i = 0; i < headings.length; i++) {
        if (headings[i].getBoundingClientRect().top <= 88) currentId = headings[i].id;
        else break;
      }
      $$('.toc a').forEach(function (a) {
        a.classList.toggle('active', a.getAttribute('data-target') === currentId);
      });
    }, { passive: true });
  }

  function updateProgress() {
    var h = document.documentElement;
    var max = h.scrollHeight - h.clientHeight;
    var bar = $('#progress');
    if (bar) bar.style.width = (max > 0 ? Math.min(100, (h.scrollTop / max) * 100) : 0) + '%';
  }

  /* ---------------- 移动端侧栏 ---------------- */
  function initMobileMenu() {
    var backdrop = document.createElement('div');
    backdrop.className = 'backdrop';
    document.body.appendChild(backdrop);
    var btn = $('#menuBtn');
    if (btn) btn.addEventListener('click', function () {
      $('#sidebar').classList.add('open');
      backdrop.classList.add('show');
    });
    backdrop.addEventListener('click', closeSidebar);
  }
  function closeSidebar() {
    var sb = $('#sidebar');
    if (sb) sb.classList.remove('open');
    var b = $('.backdrop');
    if (b) b.classList.remove('show');
  }

  /* ---------------- 启动 ---------------- */
  function boot() {
    initMobileMenu();
    initSearch();
    bindScrollSpy();
    window.addEventListener('hashchange', function () {
      var p = currentHashPath();
      if (p) renderDoc(p); else renderHome();
    });

    fetch('manifest.json', { cache: 'no-cache' })
      .then(function (r) {
        if (!r.ok) throw new Error('manifest.json HTTP ' + r.status);
        return r.json();
      })
      .then(function (data) {
        state.manifest = data;
        state.files = data.files || [];
        state.files.forEach(function (f) { state.byPath[f.path] = f; });
        state.flat = state.files.map(function (f) { return f.path; });
        buildSidebar();
        var p = currentHashPath();
        if (p) renderDoc(p); else renderHome();
      })
      .catch(function (err) {
        $('#content').innerHTML = '<div class="error-box"><strong>初始化失败：' + esc(err.message) + '</strong>' +
          '<p>请确认 manifest.json 已生成（pwsh -File tools/build-manifest.ps1），并通过 http(s) 访问页面。</p></div>';
      });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
