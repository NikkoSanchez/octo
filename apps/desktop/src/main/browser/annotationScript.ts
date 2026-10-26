/**
 * The picker, run in an isolated world so page scripts can neither see its state nor forge its
 * result. `start()` resolves with the pick, or `{ kind: "cancel" }` on Escape or `stop()`.
 */
export const ANNOTATION_WORLD = 1717;

export const ANNOTATION_SCRIPT = String.raw`
(() => {
  if (window.__octoAnnotate) return;
  let overlay = null, box = null, label = null, origin = null, dragging = false, resolve = null;
  const escape = (value) => (window.CSS && CSS.escape) ? CSS.escape(value) : value.replace(/[^\w-]/g, '\\$&');
  const unique = (el) => el.id && document.querySelectorAll('#' + escape(el.id)).length === 1;
  function selectorFor(el) {
    const parts = [];
    while (el && el.nodeType === 1 && el !== document.documentElement && parts.length < 8) {
      if (unique(el)) { parts.unshift('#' + escape(el.id)); break; }
      let part = el.localName;
      const parent = el.parentElement;
      if (parent) {
        const same = Array.from(parent.children).filter((child) => child.localName === el.localName);
        if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
      }
      parts.unshift(part); el = parent;
    }
    return parts.join(' > ');
  }
  function describe(el) {
    let text = el.localName;
    if (el.id) text += '#' + el.id;
    const classes = Array.from(el.classList || []).slice(0, 3);
    if (classes.length) text += '.' + classes.join('.');
    return text;
  }
  const target = (x, y) => document.elementsFromPoint(x, y).find((el) => !overlay.contains(el)) || null;
  const region = (a, e) => ({ x: Math.min(a.x, e.clientX), y: Math.min(a.y, e.clientY), width: Math.abs(e.clientX - a.x), height: Math.abs(e.clientY - a.y) });
  function show(r, text) {
    Object.assign(box.style, { display: 'block', left: r.x + 'px', top: r.y + 'px', width: r.width + 'px', height: r.height + 'px' });
    label.textContent = text;
    Object.assign(label.style, { display: 'block', left: r.x + 'px', top: Math.max(0, r.y - 24) + 'px' });
  }
  function move(e) {
    if (origin) {
      if (Math.abs(e.clientX - origin.x) > 5 || Math.abs(e.clientY - origin.y) > 5) dragging = true;
      if (dragging) { const r = region(origin, e); show(r, Math.round(r.width) + ' × ' + Math.round(r.height)); }
      return;
    }
    const el = target(e.clientX, e.clientY);
    if (el) { const b = el.getBoundingClientRect(); show({ x: b.left, y: b.top, width: b.width, height: b.height }, describe(el)); }
  }
  function down(e) { if (e.button !== 0) return; e.preventDefault(); e.stopPropagation(); origin = { x: e.clientX, y: e.clientY }; dragging = false; }
  function finish(payload) { const done = resolve; resolve = null; teardown(); if (done) done(payload); }
  function up(e) {
    if (!origin) return;
    e.preventDefault(); e.stopPropagation();
    const start = origin, wasDragging = dragging;
    origin = null; dragging = false;
    let payload;
    if (wasDragging) {
      const r = region(start, e);
      if (r.width < 4 || r.height < 4) return;
      const el = target(r.x + r.width / 2, r.y + r.height / 2);
      payload = { kind: 'region', rect: r, selector: el ? selectorFor(el) : '', element: el ? describe(el) : '', text: '', html: '' };
    } else {
      const el = target(e.clientX, e.clientY);
      if (!el) return;
      const b = el.getBoundingClientRect();
      payload = { kind: 'element', rect: { x: b.left, y: b.top, width: b.width, height: b.height }, selector: selectorFor(el),
                  element: describe(el), text: (el.innerText || el.textContent || '').trim().slice(0, 2000), html: el.outerHTML.slice(0, 4000) };
    }
    payload.viewport = { width: innerWidth, height: innerHeight };
    // The overlay is removed before main captures the page.
    finish(payload);
  }
  function key(e) {
    if (e.key !== 'Escape') return;
    e.preventDefault(); finish({ kind: 'cancel' });
  }
  function teardown() {
    window.removeEventListener('keydown', key, true);
    if (overlay) overlay.remove();
    overlay = null; origin = null; dragging = false;
  }
  function start() {
    if (resolve) finish({ kind: 'cancel' });
    overlay = document.createElement('div');
    overlay.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;cursor:crosshair;';
    box = document.createElement('div');
    box.style.cssText = 'all:initial;position:fixed;pointer-events:none;display:none;border:2px solid #7c8cff;background:rgba(124,140,255,.16);border-radius:3px;box-sizing:border-box;';
    label = document.createElement('div');
    label.style.cssText = 'all:initial;position:fixed;pointer-events:none;display:none;font:12px -apple-system,system-ui,sans-serif;color:#fff;background:#3b4261;padding:3px 7px;border-radius:4px;white-space:nowrap;';
    overlay.append(box, label);
    overlay.addEventListener('mousemove', move, true);
    overlay.addEventListener('mousedown', down, true);
    overlay.addEventListener('mouseup', up, true);
    overlay.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); }, true);
    window.addEventListener('keydown', key, true);
    document.documentElement.appendChild(overlay);
    return new Promise((done) => { resolve = done; });
  }
  window.__octoAnnotate = { start, stop: () => finish({ kind: 'cancel' }) };
})();
`;
