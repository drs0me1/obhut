/* Konsol's layout audit: measures one page state in the browser and returns what breaks the layout.
   - sayfa-tasmasi:   the document is wider than the window (a horizontal page scroll);
   - pencere-disinda: a visible element reaches past the window's left or right edge outside any
                      horizontally scrolling container (cut off on screen);
   - tasma:           an element's content is wider or taller than its box and spills over its edge;
   - kirpilma:        content cut by `overflow: hidden/clip` without an ellipsis (lost, not shortened);
   - ezilme:          a text box squeezed so narrow that an ordinary word (12 characters or fewer) breaks
                      across lines; a longer token (an address, a digest) wrapping is the intended fallback
                      and only counted (`uzun`);
   - cakisma:         two pieces of text (measured where their glyphs are drawn, so text spilling out of a
                      narrow cell into the next one counts) or controls in the same layer drawn over each other;
   - pencere:         an open dialog or sheet that does not fit the window and cannot scroll.
   Truncation with an ellipsis is intentional and only counted (`shortened`). Hidden, screen-reader-only,
   inert and decorative (SVG) elements and the content of a closed <details> are skipped. Pure measurement:
   changes nothing on the page. The suites run it on every screenshot (yeni-harness.cjs); giris-ui.cjs at each
   of its widths. */

function measure() {
  const vw = document.documentElement.clientWidth, vh = innerHeight;
  const findings = [];
  let shortened = 0, long = 0;
  const name = (el) => {
    const id = el.getAttribute("data-testid") || el.id;
    const cls = typeof el.className === "string" ? el.className.trim().split(/\s+/).slice(0, 2).join(".") : "";
    const text = (el.innerText || el.value || el.getAttribute("aria-label") || "").replace(/\s+/g, " ").trim().slice(0, 40);
    return `${el.tagName.toLowerCase()}${id ? "#" + id : ""}${cls ? "." + cls : ""}${text ? ` “${text}”` : ""}`;
  };
  const add = (kind, el, detail) => findings.push({ kind, el: name(el), detail });
  const styles = new Map();
  const style = (el) => { let s = styles.get(el); if (!s) { s = getComputedStyle(el); styles.set(el, s); } return s; };
  // The part of an element that is really drawn: its box cut by every ancestor that clips (overflow other
  // than visible, or a clip/clip-path that hides it). null when nothing of it shows.
  // `clip` is the region the ancestors leave visible (text spilling out of its own box is still drawn there).
  const clips = new Map();
  const drawn = (el) => {
    if (el.closest("svg, [inert], [aria-hidden='true'], template, noscript")) return null;
    // Content a closed <details> or content-visibility hides is laid out but never painted.
    if (el.checkVisibility && !el.checkVisibility({ contentVisibilityAuto: true, opacityProperty: true, visibilityProperty: true })) return null;
    let r = el.getBoundingClientRect();
    let box = { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
    let clip = { left: -1e6, top: -1e6, right: 1e6, bottom: 1e6 };
    for (let e = el; e && e !== document.documentElement; e = e.parentElement) {
      const s = style(e);
      if (s.display === "none" || s.visibility === "hidden" || s.visibility === "collapse" || Number(s.opacity) === 0) return null;
      if (e !== el && (s.overflowX !== "visible" || s.overflowY !== "visible" || (s.clip && s.clip !== "auto") || (s.clipPath && s.clipPath !== "none"))) {
        const c = e.getBoundingClientRect();
        box = { left: Math.max(box.left, c.left), top: Math.max(box.top, c.top), right: Math.min(box.right, c.right), bottom: Math.min(box.bottom, c.bottom) };
        clip = { left: Math.max(clip.left, c.left), top: Math.max(clip.top, c.top), right: Math.min(clip.right, c.right), bottom: Math.min(clip.bottom, c.bottom) };
      }
      if ((s.clip && s.clip.startsWith("rect(0")) || (s.clipPath && /inset\(50%/.test(s.clipPath))) return null;
    }
    clips.set(el, clip);
    return box.right - box.left > 1 && box.bottom - box.top > 1 ? box : null;
  };
  const cut = (c, clip) => ({ left: Math.max(c.left, clip.left), top: Math.max(c.top, clip.top), right: Math.min(c.right, clip.right), bottom: Math.min(c.bottom, clip.bottom) });
  const real = (c) => c.right - c.left > 1 && c.bottom - c.top > 1;
  // Where the element's own text is drawn: one box per line fragment, wherever it ends up.
  const textParts = (el) => {
    const parts = [];
    let clip = clips.get(el);
    const s = style(el);
    // A box that hides its own overflow does not draw the lines past its edge either.
    if (s.overflowX !== "visible" || s.overflowY !== "visible") clip = cut(el.getBoundingClientRect(), clip);
    for (const n of textNodes(el)) {
      const range = document.createRange();
      range.selectNodeContents(n);
      for (const c of range.getClientRects()) parts.push(cut(c, clip));
    }
    return parts.filter(real);
  };
  const scrollsX = (el) => {
    for (let e = el.parentElement; e && e !== document.documentElement; e = e.parentElement) {
      const s = style(e);
      if ((s.overflowX === "auto" || s.overflowX === "scroll") && e.scrollWidth > e.clientWidth) return true;
    }
    return false;
  };
  const textNodes = (el) => [...el.childNodes].filter((n) => n.nodeType === 3 && n.textContent.trim());
  const ownText = (el) => textNodes(el).map((n) => n.textContent).join(" ").replace(/\s+/g, " ").trim();
  // The lines the element's own text is laid out on (from the text's own boxes, padding and icons aside).
  const lineCount = (el) => {
    const tops = new Set();
    for (const n of textNodes(el)) {
      const range = document.createRange();
      range.selectNodeContents(n);
      for (const rect of range.getClientRects()) if (rect.width > 0.5) tops.add(Math.round(rect.top));
    }
    return tops.size;
  };
  const layer = (el) => {
    for (let e = el; e; e = e.parentElement) {
      if (e.matches?.("[role=dialog], [role=alertdialog], .layer, dialog")) return e;
      const p = style(e).position;
      if (p === "fixed" || p === "sticky") return e;
    }
    return document.body;
  };

  if (document.documentElement.scrollWidth > vw + 1) {
    findings.push({ kind: "sayfa-tasmasi", el: "html", detail: `${document.documentElement.scrollWidth} > ${vw}` });
  }
  const leaves = [];
  for (const el of document.body.querySelectorAll("*")) {
    const box = drawn(el);
    if (!box) continue;
    const s = style(el);
    const text = ownText(el);
    // Past the window edge, outside a scroll box: the drawn part reaches beyond the window.
    if ((box.right > vw + 1 || box.left < -1) && !scrollsX(el)) add("pencere-disinda", el, `${Math.round(box.left)}…${Math.round(box.right)} / ${vw}`);
    // Content wider or taller than the box.
    const wide = el.scrollWidth > el.clientWidth + 1 && el.clientWidth > 0;
    const tall = el.scrollHeight > el.clientHeight + 1 && el.clientHeight > 0 && !el.matches("textarea, select");
    if (wide || tall) {
      const ox = wide ? s.overflowX : s.overflowY;
      if (ox === "visible") {
        if (text && wide && !["BODY", "HTML"].includes(el.tagName)) {
          add("tasma", el, `${el.scrollWidth} > ${el.clientWidth} (overflow-wrap ${s.overflowWrap}, white-space ${s.whiteSpace}, ${s.display})`);
        }
      } else if (ox === "hidden" || ox === "clip") {
        if (s.textOverflow === "ellipsis" && wide && !tall) shortened += 1;
        else if (s.webkitLineClamp && s.webkitLineClamp !== "none") shortened += 1;
        else if (!["BODY", "HTML"].includes(el.tagName) && !el.matches("input, textarea, select, img, video, canvas, iframe")) {
          add("kirpilma", el, wide ? `genişlik ${el.scrollWidth} > ${el.clientWidth}` : `yükseklik ${el.scrollHeight} > ${el.clientHeight}`);
        }
      }
    }
    // Squeezed text: more lines than words means a word was broken across lines.
    if (text.length >= 3 && !el.matches("input, textarea, select")) {
      const lines = lineCount(el);
      const words = text.split(" ");
      if (lines >= 2 && lines > words.length) {
        if (Math.max(...words.map((w) => w.length)) > 12) long += 1;
        else add("ezilme", el, `${Math.round(box.right - box.left)} px genişlikte ${lines} satır, ${words.length} sözcük`);
      }
    }
    const control = el.matches("button, a[href], input:not([type=hidden]):not([type=checkbox]):not([type=radio]), select, textarea, [role=switch], [role=tab]");
    if ((text && s.position !== "absolute") || control) {
      // Text is compared where its glyphs are (line fragments, even when they spill out of the box); a control
      // without text of its own by its box.
      const parts = text ? textParts(el) : [box];
      if (parts.length) leaves.push({ el, parts, layer: layer(el) });
    }
  }
  // Overlaps: two leaves in the same layer, neither inside the other, sharing more than a sliver.
  for (let i = 0; i < leaves.length; i++) {
    for (let j = i + 1; j < leaves.length; j++) {
      const a = leaves[i], b = leaves[j];
      if (a.layer !== b.layer || a.el.contains(b.el) || b.el.contains(a.el)) continue;
      let worst = null;
      for (const x of a.parts) for (const y of b.parts) {
        const w = Math.min(x.right, y.right) - Math.max(x.left, y.left);
        const h = Math.min(x.bottom, y.bottom) - Math.max(x.top, y.top);
        if (w > 2 && h > 2 && w * h > 16 && (!worst || w * h > worst[0] * worst[1])) worst = [w, h];
      }
      if (worst) findings.push({ kind: "cakisma", el: name(a.el), detail: `${name(b.el)} ile ${Math.round(worst[0])}×${Math.round(worst[1])} px` });
    }
  }
  // Open dialogs and sheets fit the window, or their body scrolls.
  for (const d of document.querySelectorAll("[role=dialog], [role=alertdialog]")) {
    if (!drawn(d)) continue;
    const r = d.getBoundingClientRect();
    if (r.left < -1 || r.right > vw + 1) add("pencere", d, `yatay ${Math.round(r.left)}…${Math.round(r.right)} / ${vw}`);
    if (r.top < -1 || r.bottom > vh + 1) {
      const scroller = [d, ...d.querySelectorAll("*")].some((e) => {
        const s = style(e);
        return (s.overflowY === "auto" || s.overflowY === "scroll") && e.scrollHeight > e.clientHeight;
      });
      if (!scroller) add("pencere", d, `dikey ${Math.round(r.top)}…${Math.round(r.bottom)} / ${vh}, kaydırılamıyor`);
    }
  }
  return { width: vw, height: vh, findings, shortened, long };
}

/** Audits the page at its own size and, with `widths`, at each of those widths (the viewport is restored). */
async function audit(page, widths = []) {
  const original = page.viewportSize();
  // The phone menu belongs to the phone layout and closes on a wider window (MenuSheet): keep to phones then.
  if (await page.locator(".layer-sheet").count()) widths = widths.filter((w) => w <= 760);
  const focused = await page.evaluateHandle(() => document.activeElement);
  const results = [{ ...(await page.evaluate(measure)) }];
  for (const width of widths) {
    if (!original || width === original.width) continue;
    await page.setViewportSize({ width, height: original.height });
    await page.waitForTimeout(150);
    await page.waitForFunction(() => !document.querySelector('[class*="-enter-"], [class*="-leave-"]') &&
      document.getAnimations().every((a) => a.playState !== "running" || a.effect?.getComputedTiming().iterations === Infinity));
    results.push(await page.evaluate(measure));
  }
  if (original && widths.length) {
    await page.setViewportSize(original);
    await page.waitForTimeout(150);
    // Resizing can move the focus; give it back to what had it, when that is still on the page.
    await focused.evaluate((el) => { if (el && el.isConnected && el !== document.body) el.focus({ preventScroll: true }); }).catch(() => {});
  }
  await focused.dispose();
  return results;
}

module.exports = { audit, measure };
