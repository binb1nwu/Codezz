// Codezz document viewer: the app streams a desktop file in with
// codezz.begin / append, then codezz.render draws it the way ZCode's preview
// pane does (pdf.js, pptx-preview, docx-preview, SheetJS). Status goes back
// over the `Codezz` JavaScript channel.
(function () {
  'use strict';

  const root = document.getElementById('root');
  const indicator = document.getElementById('indicator');

  function post(msg) {
    const text = JSON.stringify(msg);
    if (window.Codezz) window.Codezz.postMessage(text);
    else window.parent.postMessage(text, '*'); // browser test harness
  }

  const scripts = {};
  function load(src) {
    if (!scripts[src]) {
      scripts[src] = new Promise((resolve, reject) => {
        const s = document.createElement('script');
        s.src = src;
        s.onload = resolve;
        s.onerror = () => reject(new Error('failed to load ' + src));
        document.head.appendChild(s);
      });
    }
    return scripts[src];
  }

  // Links inside documents never navigate the viewer; in-page anchors still
  // scroll.
  document.addEventListener('click', (e) => {
    const a = e.target instanceof Element ? e.target.closest('a') : null;
    if (!a) return;
    const href = a.getAttribute('href') || a.getAttribute('xlink:href') || '';
    if (!href.startsWith('#')) e.preventDefault();
  }, true);

  let showTimer = null;
  function showIndicator(text) {
    indicator.textContent = text;
    indicator.classList.add('on');
    clearTimeout(showTimer);
    showTimer = setTimeout(() => indicator.classList.remove('on'), 1200);
  }

  // Page "n / total" while scrolling a stack of pages.
  function trackPages(pages) {
    if (pages.length < 2) return;
    let last = -1;
    window.addEventListener('scroll', () => {
      const mid = window.scrollY + window.innerHeight / 2;
      let i = 0;
      while (i < pages.length - 1 && pages[i + 1].offsetTop <= mid) i++;
      if (i !== last || indicator.classList.contains('on')) showIndicator((i + 1) + ' / ' + pages.length);
      last = i;
    }, { passive: true });
  }

  function width() {
    return Math.max(160, document.documentElement.clientWidth - 24);
  }

  // ── data from the app ──
  let buffer = null;
  let filled = 0;

  function decode(b64) {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }

  // ── PDF ──
  const cmapWaiters = {};

  // Built-in CMaps (CJK PDFs without embedded fonts) come from the app's
  // assets: file:// pages cannot fetch them themselves.
  class AppCMapReader {
    constructor() {}
    fetch({ name }) {
      return new Promise((resolve, reject) => {
        (cmapWaiters[name] = cmapWaiters[name] || []).push({ resolve, reject });
        post({ type: 'cmap', name });
      }).then((data) => ({ cMapData: data, compressionType: 1 /* BINARY */ }));
    }
  }

  async function renderPdf(data) {
    await load('pdf.min.js');
    await load('pdf.worker.min.js'); // runs on this thread: no Worker from file://
    const pdfjs = window.pdfjsLib;
    pdfjs.GlobalWorkerOptions.workerSrc = 'pdf.worker.min.js';
    const doc = await pdfjs.getDocument({
      data,
      cMapUrl: 'cmaps/',
      cMapPacked: true,
      CMapReaderFactory: AppCMapReader,
      isEvalSupported: false,
    }).promise;
    const pages = [];
    for (let n = 1; n <= doc.numPages; n++) {
      const page = await doc.getPage(n);
      const vp = page.getViewport({ scale: 1 });
      const div = document.createElement('div');
      div.className = 'page';
      div.style.width = '100%';
      div.style.aspectRatio = vp.width + ' / ' + vp.height;
      div._page = page;
      root.appendChild(div);
      pages.push(div);
    }
    const dpr = Math.min(3, (window.devicePixelRatio || 1) * 1.5);
    const draw = (div) => {
      if (div._canvas) return;
      const page = div._page;
      const vp1 = page.getViewport({ scale: 1 });
      const scale = (div.clientWidth * dpr) / vp1.width;
      const vp = page.getViewport({ scale });
      const canvas = document.createElement('canvas');
      canvas.width = Math.floor(vp.width);
      canvas.height = Math.floor(vp.height);
      div._canvas = canvas;
      div.appendChild(canvas);
      div._task = page.render({ canvasContext: canvas.getContext('2d'), viewport: vp });
      div._task.promise.catch(() => {});
    };
    const drop = (div) => {
      if (!div._canvas) return;
      div._task?.cancel();
      div._canvas.width = div._canvas.height = 0;
      div._canvas.remove();
      div._canvas = null;
    };
    // Draw pages near the viewport; free the bitmaps of far-away ones.
    const near = new IntersectionObserver((es) => es.forEach((e) => e.isIntersecting && draw(e.target)), { rootMargin: '100% 0px' });
    const far = new IntersectionObserver((es) => es.forEach((e) => !e.isIntersecting && drop(e.target)), { rootMargin: '400% 0px' });
    pages.forEach((p) => { near.observe(p); far.observe(p); });
    trackPages(pages);
    if (!pages.length) throw new Error('empty');
  }

  // ── PPTX ──
  async function slideSize(data) {
    try {
      const zip = await window.JSZip.loadAsync(data);
      const xml = await zip.file('ppt/presentation.xml')?.async('string');
      const m = xml && /<p:sldSz\b[^>]*\bcx="(\d+)"[^>]*\bcy="(\d+)"/.exec(xml);
      if (m) return { cx: +m[1], cy: +m[2] };
    } catch (_) {}
    return { cx: 16, cy: 9 };
  }

  let pptxWidth = 0;
  async function renderPptx(data) {
    await load('pptx-preview.umd.js');
    const size = await slideSize(data);
    const draw = async () => {
      pptxWidth = width();
      root.innerHTML = '';
      const viewer = window.pptxPreview.init(root, {
        width: pptxWidth,
        height: Math.round((pptxWidth * size.cy) / size.cx),
        mode: 'list',
      });
      await viewer.preview(data.slice().buffer);
      const slides = Array.from(root.querySelectorAll('.pptx-preview-slide-wrapper'));
      if (!slides.length) throw new Error('no slides');
      trackPages(slides);
    };
    await draw();
    // Rotation: lay the slides out again at the new width.
    let t = null;
    window.addEventListener('resize', () => {
      clearTimeout(t);
      t = setTimeout(() => { if (Math.abs(width() - pptxWidth) > 8) draw().catch(() => {}); }, 300);
    });
  }

  // ── DOCX ──
  async function renderDocx(data) {
    await load('docx-preview.min.js');
    root.className = 'docx';
    const body = document.createElement('div');
    const styles = document.createElement('div');
    root.append(styles, body);
    await window.docx.renderAsync(data, body, styles, {
      inWrapper: true,
      breakPages: true,
      ignoreLastRenderedPageBreak: true,
      useBase64URL: false,
      renderComments: false,
    });
    const pages = Array.from(body.querySelectorAll('.docx-wrapper > section.docx'));
    const fit = () => {
      const widest = pages.reduce((m, p) => Math.max(m, p.offsetWidth), 0);
      body.style.zoom = widest > 0 ? String(Math.min(1, width() / widest)) : '1';
    };
    fit();
    window.addEventListener('resize', fit);
    trackPages(pages);
  }

  // ── XLSX / XLS ──
  function colName(c) {
    let s = '';
    for (c++; c > 0; c = Math.floor((c - 1) / 26)) s = String.fromCharCode(65 + ((c - 1) % 26)) + s;
    return s;
  }

  function sheetTable(XLSX, ws) {
    const div = document.createElement('div');
    div.className = 'sheet';
    if (!ws || !ws['!ref']) {
      div.innerHTML = '<div class="empty"></div>';
      return div;
    }
    const range = XLSX.utils.decode_range(ws['!ref']);
    // Keep the phone responsive on huge sheets.
    const lastRow = Math.min(range.e.r, range.s.r + 4999);
    const lastCol = Math.min(range.e.c, range.s.c + 199);
    const skip = new Set();
    const spans = {};
    for (const m of ws['!merges'] || []) {
      spans[m.s.r + ':' + m.s.c] = { rows: m.e.r - m.s.r + 1, cols: m.e.c - m.s.c + 1 };
      for (let r = m.s.r; r <= m.e.r; r++) for (let c = m.s.c; c <= m.e.c; c++) if (r !== m.s.r || c !== m.s.c) skip.add(r + ':' + c);
    }
    const table = document.createElement('table');
    const head = table.insertRow();
    const corner = document.createElement('th');
    corner.className = 'corner';
    head.appendChild(corner);
    for (let c = range.s.c; c <= lastCol; c++) {
      const th = document.createElement('th');
      th.className = 'ch';
      th.textContent = colName(c);
      head.appendChild(th);
    }
    for (let r = range.s.r; r <= lastRow; r++) {
      const tr = table.insertRow();
      const rh = document.createElement('th');
      rh.className = 'rh';
      rh.textContent = String(r + 1);
      tr.appendChild(rh);
      for (let c = range.s.c; c <= lastCol; c++) {
        const key = r + ':' + c;
        if (skip.has(key)) continue;
        const td = tr.insertCell();
        const span = spans[key];
        if (span) { td.rowSpan = span.rows; td.colSpan = span.cols; }
        const cell = ws[XLSX.utils.encode_cell({ r, c })];
        if (cell) {
          td.textContent = cell.w != null ? cell.w : cell.v != null ? String(cell.v) : '';
          if (cell.t === 'n') td.style.textAlign = 'right';
        }
      }
    }
    div.appendChild(table);
    return div;
  }

  async function renderXlsx(data) {
    await load('xlsx.full.min.js');
    const XLSX = window.XLSX;
    const wb = XLSX.read(data, { type: 'array', cellDates: true, dense: false });
    root.className = 'xlsx';
    const tabs = document.createElement('div');
    tabs.id = 'tabs';
    const show = (i) => {
      root.innerHTML = '';
      root.appendChild(sheetTable(XLSX, wb.Sheets[wb.SheetNames[i]]));
      Array.from(tabs.children).forEach((b, j) => b.classList.toggle('on', i === j));
      window.scrollTo(0, 0);
    };
    wb.SheetNames.forEach((name, i) => {
      const b = document.createElement('button');
      b.textContent = name;
      b.onclick = () => show(i);
      tabs.appendChild(b);
    });
    if (!wb.SheetNames.length) throw new Error('no sheets');
    document.body.appendChild(tabs);
    show(0);
  }

  window.codezz = {
    /** Starts a file of [total] bytes. */
    begin(total) {
      buffer = new Uint8Array(total);
      filled = 0;
    },
    /** Appends a base64 chunk. */
    append(b64) {
      const bytes = decode(b64);
      if (filled + bytes.length > buffer.length) {
        const grown = new Uint8Array(Math.max(buffer.length * 2, filled + bytes.length));
        grown.set(buffer.subarray(0, filled));
        buffer = grown;
      }
      buffer.set(bytes, filled);
      filled += bytes.length;
    },
    /** A CMap the PDF renderer asked for; null when there is none. */
    cmap(name, b64) {
      const waiters = cmapWaiters[name] || [];
      delete cmapWaiters[name];
      waiters.forEach((w) => (b64 == null ? w.reject(new Error('missing CMap ' + name)) : w.resolve(decode(b64))));
    },
    /**
     * Draws the received bytes as [kind] (pdf | pptx | docx | xlsx) with the
     * app's theme colours.
     */
    render(kind, theme) {
      const css = document.documentElement.style;
      for (const [k, v] of Object.entries(theme || {})) css.setProperty('--' + k, v);
      root.className = kind;
      const data = buffer.subarray(0, filled);
      buffer = null;
      const run = { pdf: renderPdf, pptx: renderPptx, docx: renderDocx, xlsx: renderXlsx }[kind];
      Promise.resolve()
        .then(() => run(data))
        .then(() => post({ type: 'done' }))
        .catch((e) => post({ type: 'error', message: String((e && e.message) || e) }));
    },
  };

  post({ type: 'ready' });
})();
