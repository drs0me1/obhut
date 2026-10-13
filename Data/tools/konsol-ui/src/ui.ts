// Which modal surface is open: the command palette, the activity drawer or the phone menu sheet. Only one
// at a time; the rest of the page is inert meanwhile, and closing returns focus to the control that opened
// it (unless the user went somewhere else, e.g. chose a page in the palette).
import { computed, nextTick, reactive } from "vue";

export type Surface = "palette" | "drawer" | "sheet";

export const ui = reactive({ open: null as Surface | null });

export const anyOpen = computed(() => ui.open !== null);

let opener: HTMLElement | null = null;

export function openSurface(which: Surface): void {
  if (ui.open === which) return;
  if (ui.open === null) {
    const active = document.activeElement;
    opener = active instanceof HTMLElement && active !== document.body ? active : null;
  }
  // Switching from one surface to another keeps the first opener.
  ui.open = which;
}

export function closeSurface(returnFocus = true): void {
  if (ui.open === null) return;
  ui.open = null;
  const target = opener;
  opener = null;
  if (returnFocus && target) {
    void nextTick(() => {
      if (target.isConnected) target.focus();
    });
  }
}

export function toggleSurface(which: Surface): void {
  if (ui.open === which) closeSurface();
  else openSurface(which);
}
