// Theme (DD-258; A7): Sistem follows prefers-color-scheme; Açık and Koyu set data-theme on <html>. The top bar's
// button steps through the three and the palette chooses one. The choice is this browser's only, in localStorage
// "konsol.tema"; public/tema.js applies it before the first paint.
import { ref } from "vue";

export type ThemeChoice = "sistem" | "acik" | "koyu";

export const THEMES: readonly { id: ThemeChoice; label: string }[] = [
  { id: "sistem", label: "sistem" },
  { id: "acik", label: "açık" },
  { id: "koyu", label: "koyu" },
];

/** "Tema: açık": the choice in words, as the top bar and the palette name it. */
export const themeText = (choice: ThemeChoice): string => "Tema: " + (THEMES.find((t) => t.id === choice)?.label ?? choice);

/** The choice after this one: sistem → açık → koyu → sistem. */
export function nextTheme(choice: ThemeChoice): ThemeChoice {
  const at = THEMES.findIndex((t) => t.id === choice);
  return (THEMES[(at + 1) % THEMES.length] as (typeof THEMES)[number]).id;
}

const KEY = "konsol.tema";
const isChoice = (v: unknown): v is ThemeChoice => v === "sistem" || v === "acik" || v === "koyu";

function stored(): ThemeChoice {
  try {
    const value = localStorage.getItem(KEY);
    if (isChoice(value)) return value;
  } catch {
    // Storage is off (private window, blocked site data): follow the system.
  }
  return "sistem";
}

function apply(choice: ThemeChoice): void {
  const root = document.documentElement;
  if (choice === "acik") root.setAttribute("data-theme", "light");
  else if (choice === "koyu") root.setAttribute("data-theme", "dark");
  else root.removeAttribute("data-theme");
}

export const theme = ref<ThemeChoice>(stored());

export function initTheme(): void {
  apply(theme.value);
  // Another tab changed the choice.
  window.addEventListener("storage", (event) => {
    if (event.key !== KEY) return;
    theme.value = isChoice(event.newValue) ? event.newValue : "sistem";
    apply(theme.value);
  });
}

export function setTheme(choice: ThemeChoice): void {
  theme.value = choice;
  apply(choice);
  try {
    localStorage.setItem(KEY, choice);
  } catch {
    // Not kept: this page still shows the choice.
  }
}
