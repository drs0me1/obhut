// Copying to the clipboard (DD-266). Konsol opens over plain HTTP on the tailnet, where
// navigator.clipboard does not exist; a hidden, read-only textarea and execCommand("copy") still work
// there. The textarea is placed through the CSSOM (no style attribute: the CSP has no unsafe-inline).

/** Copies `text`; false when neither way worked (the caller says so and leaves the value selectable). */
export async function copyText(text: string): Promise<boolean> {
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // the older way below
  }
  const area = document.createElement("textarea");
  area.value = text;
  area.readOnly = true;
  area.setAttribute("aria-hidden", "true");
  area.tabIndex = -1;
  area.style.position = "fixed";
  area.style.top = "0";
  area.style.left = "0";
  area.style.opacity = "0";
  const focused = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  document.body.append(area);
  area.select();
  let ok = false;
  try {
    ok = document.execCommand("copy");
  } catch {
    ok = false;
  }
  area.remove();
  focused?.focus();
  return ok;
}
