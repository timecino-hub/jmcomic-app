import Foundation

/// 前端页面。移动优先：先按手机窄屏排版，宽屏再放开列数。
///
/// 内联在二进制里而不是打包静态文件，省掉 Resources 打包和路径解析。
/// 页面很小（不到 20KB），不值得为它引入构建步骤。
enum WebUI {

    /// HTML 转义。所有插入页面的动态文本都必须过这里，否则标题里的引号或
    /// <script> 会直接破坏页面结构。
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let baseCSS = """
    *,*::before,*::after{box-sizing:border-box}
    :root{
      --bg:#141416; --surface:#1d1d20; --surface2:#26262b;
      --text:#f2f2f4; --dim:#9a9aa2; --accent:#e05a7d; --line:#32323a;
      --safe-b:env(safe-area-inset-bottom,0px);
    }
    html,body{margin:0;padding:0;background:var(--bg);color:var(--text);
      font:16px/1.5 -apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;
      -webkit-text-size-adjust:100%;overscroll-behavior-y:none}
    a{color:inherit;text-decoration:none}
    button{font:inherit;color:inherit;background:none;border:none;cursor:pointer}
    /* 44px 是触摸目标的可用下限，比这更小手指点不准 */
    .tap{min-height:44px;min-width:44px;display:inline-flex;align-items:center;
      justify-content:center;-webkit-tap-highlight-color:transparent}
    """

    // MARK: - 登录页

    static func loginPage(error: String?) -> String {
        let err = error.map { "<p class=err>\(esc($0))</p>" } ?? ""
        return """
        <!doctype html><html lang=zh-CN><head>
        <meta charset=utf-8>
        <meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>登录</title><style>\(baseCSS)
        .wrap{min-height:100dvh;display:grid;place-items:center;padding:24px}
        form{width:100%;max-width:320px;background:var(--surface);padding:28px 22px;
          border-radius:16px;border:1px solid var(--line)}
        h1{margin:0 0 4px;font-size:19px}
        p.sub{margin:0 0 20px;color:var(--dim);font-size:13px}
        input{width:100%;padding:13px 14px;margin-bottom:14px;background:var(--surface2);
          border:1px solid var(--line);border-radius:10px;color:var(--text);font-size:16px}
        input:focus{outline:none;border-color:var(--accent)}
        button.go{width:100%;padding:13px;background:var(--accent);border-radius:10px;
          font-weight:600;color:#fff}
        .err{color:#ff8095;font-size:13px;margin:0 0 14px}
        </style></head><body><div class=wrap>
        <form method=post action=/login>
          <h1>JMComic</h1><p class=sub>局域网访问需要密码</p>
          \(err)
          <input type=password name=password placeholder=访问密码 autocomplete=current-password
                 autofocus required>
          <button class=go type=submit>进入</button>
        </form></div></body></html>
        """
    }

    // MARK: - 主应用

    static func appShell() -> String {
        """
        <!doctype html><html lang=zh-CN><head>
        <meta charset=utf-8>
        <meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
        <meta name=theme-color content="#141416">
        <title>JMComic</title><style>\(baseCSS)\(appCSS)</style></head>
        <body>
        <header id=bar>
          <button class="tap" id=back hidden>‹</button>
          <div id=title>JMComic</div>
          <button class="tap" id=searchBtn>搜索</button>
        </header>
        <div id=searchRow hidden>
          <input id=q type=search placeholder="书名、作者，或直接粘贴漫画 ID"
                 enterkeyhint=search autocomplete=off>
        </div>
        <nav id=tabs>
          <button class="tab tap" data-kind=hot>推荐</button>
          <button class="tab tap" data-kind=latest>最新</button>
          <button class="tab tap" data-kind=history>历史</button>
          <button class="tab tap" data-kind=favorites>收藏</button>
          <button class="tab tap" data-kind=recent>最近</button>
          <button class="tab tap" data-kind=personalized>为你推荐</button>
        </nav>
        <main id=main></main>
        <div id=spin hidden>载入中…</div>
        <script>\(appJS)</script>
        </body></html>
        """
    }

    private static let appCSS = """
    #bar{position:sticky;top:0;z-index:10;display:flex;align-items:center;gap:8px;
      padding:8px 10px;padding-top:calc(8px + env(safe-area-inset-top,0px));
      background:rgba(20,20,22,.92);backdrop-filter:blur(12px);
      border-bottom:1px solid var(--line)}
    #title{flex:1;font-weight:600;font-size:16px;white-space:nowrap;overflow:hidden;
      text-overflow:ellipsis}
    #bar button{font-size:15px;color:var(--dim);padding:0 6px}
    #back{font-size:26px;line-height:1}
    #searchRow{padding:8px 10px;border-bottom:1px solid var(--line)}
    #q{width:100%;padding:11px 13px;background:var(--surface2);border:1px solid var(--line);
      border-radius:10px;color:var(--text);font-size:16px}
    #q:focus{outline:none;border-color:var(--accent)}
    #tabs{display:flex;gap:4px;padding:8px 10px;border-bottom:1px solid var(--line);
      overflow-x:auto;scrollbar-width:none}
    .tab{padding:7px 15px;border-radius:999px;background:var(--surface2);
      color:var(--dim);font-size:14px}
    .tab.on{background:var(--accent);color:#fff}
    main{padding:12px 10px calc(28px + var(--safe-b))}

    /* 手机 2 列，往上按空间加列 */
    .grid{display:grid;grid-template-columns:repeat(2,1fr);gap:12px}
    @media(min-width:560px){.grid{grid-template-columns:repeat(3,1fr)}}
    @media(min-width:820px){.grid{grid-template-columns:repeat(4,1fr)}}
    @media(min-width:1100px){.grid{grid-template-columns:repeat(5,1fr)}}
    .card{background:var(--surface);border-radius:12px;overflow:hidden;
      border:1px solid var(--line)}
    .card img{width:100%;aspect-ratio:2/3;object-fit:cover;display:block;
      background:var(--surface2)}
    .card .t{padding:7px 8px;font-size:12.5px;line-height:1.35;
      display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
    .card .a{padding:0 8px 8px;font-size:11px;color:var(--dim);
      white-space:nowrap;overflow:hidden;text-overflow:ellipsis}

    .detail h2{margin:4px 0 6px;font-size:17px;line-height:1.4}
    .detail .meta{color:var(--dim);font-size:13px;margin-bottom:10px}
    .tags{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:14px}
    .tags span{background:var(--surface2);padding:4px 9px;border-radius:999px;font-size:12px}
    .desc{color:var(--dim);font-size:13.5px;margin-bottom:16px;white-space:pre-wrap}
    .chap{display:flex;align-items:center;justify-content:space-between;
      padding:13px 12px;background:var(--surface);border:1px solid var(--line);
      border-radius:10px;margin-bottom:8px;font-size:14px;width:100%;text-align:left}

    /* 阅读器：全屏纵向连续滚动 */
    #reader{position:fixed;inset:0;z-index:50;background:#000;overflow-y:auto;
      overflow-x:hidden;-webkit-overflow-scrolling:touch}
    #reader img{width:100%;max-width:1000px;margin:0 auto;display:block;
      /* 占位高度按典型页面比例，避免图未到时整页跳动 */
      min-height:40vh;background:#0a0a0a}
    /* 单页模式：整页 fit 视口，点左右翻页 */
    #reader.single img{height:100vh;width:auto;max-width:none;object-fit:contain;
      min-height:100vh}
    /* 双击放大（看小字） */
    #reader img.zoom{transform:scale(1.8);transform-origin:50% 50%}
    #rbar{position:fixed;left:0;right:0;bottom:0;z-index:51;display:flex;
      align-items:center;gap:10px;padding:10px 14px;
      padding-bottom:calc(10px + var(--safe-b));
      background:rgba(0,0,0,.82);backdrop-filter:blur(10px);
      transition:transform .22s;font-size:13px;color:#ddd}
    #rbar.hide{transform:translateY(110%)}
    #spin{position:fixed;bottom:calc(18px + var(--safe-b));left:50%;
      transform:translateX(-50%);background:rgba(0,0,0,.8);color:#fff;
      padding:8px 16px;border-radius:999px;font-size:13px;z-index:60}
    .empty{padding:44px 16px;text-align:center;color:var(--dim);font-size:14px}
    """

    /// 前端逻辑。刻意不用框架：整个应用几个视图，手写比引 CDN 依赖更快也更可控。
    private static let appJS = #"""
    const $ = s => document.querySelector(s);
    const main = $('#main'), spin = $('#spin');
    let kind = 'hot', page = 1, loading = false, hasMore = true, view = 'list';

    const esc = s => String(s ?? '').replace(/[&<>"']/g,
      c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

    async function api(path) {
      const r = await fetch(path, {credentials:'same-origin'});
      // 无 token / 会话失效时服务端一律 404，登录页不可达，不回跳
      if (r.status === 401 || r.status === 404) {
        main.innerHTML = '<div class=empty>会话已失效，请回 Mac 重新扫码进入</div>';
        throw new Error('unauth');
      }
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    }

    function setBusy(b) { loading = b; spin.hidden = !b; }

    // ---- 列表 ----
    const localKinds = ['favorites', 'history', 'recent', 'personalized'];
    async function loadFeed(reset) {
      if (loading || (!reset && !hasMore)) return;
      if (reset) { page = 1; hasMore = true; main.innerHTML = '<div class=grid></div>'; }
      setBusy(true);
      try {
        const q = $('#q').value.trim();
        const url = localKinds.includes(kind) ? `/api/${kind}`
          : q ? `/api/feed?kind=search&q=${encodeURIComponent(q)}&page=${page}`
              : `/api/feed?kind=${kind}&page=${page}`;
        const d = await api(url);
        if (d.error) throw new Error(d.error);
        const grid = main.querySelector('.grid') || main;
        if (!d.items.length && page === 1) {
          main.innerHTML = '<div class=empty>没有结果</div>';
        } else {
          grid.insertAdjacentHTML('beforeend', d.items.map(it => `
            <a class=card href="#/album/${encodeURIComponent(it.id)}">
              <img loading=lazy src="/img/cover?id=${encodeURIComponent(it.id)}" alt="">
              <div class=t>${esc(it.title)}</div>
              <div class=a>${esc(it.author)}</div>
            </a>`).join(''));
        }
        hasMore = d.hasMore; page++;
      } catch (e) {
        if (page === 1) main.innerHTML = `<div class=empty>加载失败：${esc(e.message)}</div>`;
      } finally { setBusy(false); }
    }

    // 触底续加载。rootMargin 提前 600px 触发，滑到底时下一批往往已经就位
    const sentinel = new IntersectionObserver(es => {
      if (es[0].isIntersecting && view === 'list') loadFeed(false);
    }, {rootMargin:'600px'});

    // ---- 详情 ----
    async function loadAlbum(id) {
      view = 'detail'; setBusy(true);
      $('#tabs').hidden = true; $('#back').hidden = false; $('#searchRow').hidden = true;
      try {
        const a = await api('/api/album?id=' + encodeURIComponent(id));
        if (a.error) throw new Error(a.error);
        $('#title').textContent = a.title;
        main.innerHTML = `<div class=detail>
          <h2>${esc(a.title)}</h2>
          <div class=meta>${esc(a.author)} · ${esc(a.views)} 次观看 · ${esc(a.likes)} 赞</div>
          ${a.position ? `<button class="chap tap" id=resume data-cid="${esc(a.position.chapterId)}" data-sort="${a.position.chapterSort}" data-page="${a.position.pageIndex}">
            <span>继续阅读：第 ${a.position.pageIndex + 1} 页</span><span>›</span></button>` : ''}
          <div style="margin:12px 0">
            <button class="tap" id=favBtn style="border:1px solid var(--line);border-radius:999px;padding:7px 16px;font-size:13px;color:${a.favorited ? 'var(--accent)' : 'var(--dim)'}">
              ${a.favorited ? '♥ 已收藏' : '♡ 收藏'}</button>
          </div>
          <div class=tags>${a.tags.map(t => `<span>${esc(t)}</span>`).join('')}</div>
          ${a.description ? `<div class=desc>${esc(a.description)}</div>` : ''}
          ${a.chapters.map(c => `<button class="chap tap"
              data-cid="${esc(c.id)}" data-sort="${c.sort}">
              <span>${esc(c.title)}</span><span>›</span></button>`).join('')}
        </div>`;
        main.querySelectorAll('.chap:not(#resume)').forEach(b => b.onclick =
          () => openReader(b.dataset.cid, +b.dataset.sort, a.title, null, a.id));
        const resume = $('#resume');
        if (resume) resume.onclick = () =>
          openReader(resume.dataset.cid, +resume.dataset.sort, a.title, +resume.dataset.page, a.id);
        $('#favBtn').onclick = async () => {
          const r = await fetch('/api/favorites/toggle', {
            method:'POST', credentials:'same-origin',
            headers:{'Content-Type':'application/x-www-form-urlencoded'},
            body: 'id=' + encodeURIComponent(a.id) + '&title=' + encodeURIComponent(a.title),
          });
          if (!r.ok) return alert('操作失败');
          const d = await r.json();
          const btn = $('#favBtn');
          btn.textContent = d.favorited ? '♥ 已收藏' : '♡ 收藏';
          btn.style.color = d.favorited ? 'var(--accent)' : 'var(--dim)';
        };
      } catch (e) {
        main.innerHTML = `<div class=empty>加载失败：${esc(e.message)}</div>`;
      } finally { setBusy(false); }
    }

    // ---- 阅读器 ----
    let readerState = null;
    let progressTimer = null;
    // 翻页进度写回（节流 800ms；未受信任设备 403 会被忽略）
    function reportProgress(page) {
      const st = readerState; if (!st) return;
      clearTimeout(progressTimer);
      progressTimer = setTimeout(async () => {
        try {
          await fetch('/api/progress', {method:'POST', credentials:'same-origin',
            headers:{'Content-Type':'application/x-www-form-urlencoded'},
            body: 'albumId=' + encodeURIComponent(st.albumId)
                + '&title=' + encodeURIComponent(st.title)
                + '&chapterId=' + encodeURIComponent(st.cid)
                + '&sort=' + st.sort + '&page=' + page});
        } catch (e) {}
      }, 800);
    }
    function gotoPage(n) {
      const st = readerState; if (!st) return;
      const target = Math.max(0, Math.min(n, st.imgs.length - 1));
      st.imgs[target].scrollIntoView({behavior:'smooth', block:'start'});
      st.pos.textContent = `${target + 1} / ${st.imgs.length}`;
      reportProgress(target);
    }

    async function openReader(cid, sort, albumTitle, startPage, albumId) {
      setBusy(true);
      try {
        const c = await api(`/api/chapter?id=${encodeURIComponent(cid)}&sort=${sort}`);
        if (c.error) throw new Error(c.error);

        const r = document.createElement('div');
        r.id = 'reader';
        r.innerHTML = c.pages.map((p, i) =>
          `<img loading=lazy data-i="${i}" src="${p.src}" alt="第 ${i+1} 页">`).join('');

        const bar = document.createElement('div');
        bar.id = 'rbar';
        bar.innerHTML = `<button class="tap" id=rclose>‹ 返回</button>
          <button class="tap" id=rmode style="font-size:12px;border:1px solid #444;border-radius:999px;padding:4px 10px">单页</button>
          <div style="flex:1;text-align:center" id=rpos>1 / ${c.pages.length}</div>`;

        document.body.append(r, bar);
        document.body.style.overflow = 'hidden';

        const imgs = [...r.querySelectorAll('img')];
        const pos = bar.querySelector('#rpos');
        readerState = { r, bar, imgs, pos, single: false, albumId, title: albumTitle || '', cid, sort };

        // 用视口中线所在的图判断当前页
        r.addEventListener('scroll', () => {
          const st = readerState; if (!st) return;
          const mid = r.scrollTop + r.clientHeight / 2;
          let n = 1;
          for (let i = 0; i < st.imgs.length; i++) {
            if (st.imgs[i].offsetTop <= mid) n = i + 1; else break;
          }
          st.pos.textContent = `${n} / ${st.imgs.length}`;
          if (!st.single) { bar.classList.add('hide'); clearTimeout(r._t);
            r._t = setTimeout(() => bar.classList.remove('hide'), 900);
            reportProgress(n - 1); }
        }, {passive:true});

        // 单页模式：整页 fit 视口，点击左/右半屏翻页
        bar.querySelector('#rmode').onclick = e => {
          const st = readerState; if (!st) return;
          st.single = !st.single;
          e.currentTarget.textContent = st.single ? '连续' : '单页';
          r.classList.toggle('single', st.single);
          r.scrollTop = 0;
        };
        r.addEventListener('click', e => {
          const st = readerState; if (!st || e.target.closest('button')) return;
          if (st.single) {
            const mid = r.clientWidth / 2;
            const midV = r.clientHeight / 2;
            const cur = Math.floor((r.scrollTop + midV) / (r.clientHeight || 1));
            if (e.clientX > mid) gotoPage(cur + 1); else gotoPage(cur - 1);
          } else {
            // 连续模式：点击唤出/隐藏工具栏
            bar.classList.toggle('hide');
          }
        });

        // 双击放大局部（看小字）
        imgs.forEach(img => img.addEventListener('dblclick', () => {
          img.classList.toggle('zoom');
        }));

        const close = () => {
          readerState = null;
          r.remove(); bar.remove();
          document.body.style.overflow = '';
        };
        bar.querySelector('#rclose').onclick = close;

        // 续读：从指定页开始
        if (startPage != null && startPage > 0) {
          setTimeout(() => gotoPage(startPage), 60);
        }
      } catch (e) {
        alert('章节加载失败：' + e.message);
      } finally { setBusy(false); }
    }

    // ---- 路由 ----
    function render() {
      const h = location.hash;
      const m = h.match(/^#\/album\/(.+)$/);
      if (m) { loadAlbum(decodeURIComponent(m[1])); return; }
      view = 'list';
      $('#tabs').hidden = false; $('#back').hidden = true;
      $('#title').textContent = 'JMComic';
      main.innerHTML = '<div class=grid></div>';
      loadFeed(true);
      let s = document.createElement('div');
      main.append(s); sentinel.observe(s);
    }

    window.addEventListener('hashchange', render);
    $('#back').onclick = () => history.back();
    $('#searchBtn').onclick = () => {
      const row = $('#searchRow');
      row.hidden = !row.hidden;
      if (!row.hidden) $('#q').focus();
    };
    let timer;
    $('#q').addEventListener('input', () => {
      clearTimeout(timer);
      timer = setTimeout(() => { if (view === 'list') loadFeed(true); }, 400);
    });
    $('#q').addEventListener('keydown', e => {
      if (e.key !== 'Enter') return;
      e.preventDefault(); $('#q').blur();
      const q = $('#q').value.trim();
      // 纯数字 = 专辑 ID，直接打开详情
      if (/^\d+$/.test(q)) { location.hash = '#/album/' + encodeURIComponent(q); return; }
      loadFeed(true);
    });
    document.querySelectorAll('.tab').forEach(t => t.onclick = () => {
      document.querySelectorAll('.tab').forEach(x => x.classList.remove('on'));
      t.classList.add('on');
      kind = t.dataset.kind;
      $('#q').value = '';
      loadFeed(true);
    });
    document.querySelector('.tab').classList.add('on');
    render();
    """#
}
