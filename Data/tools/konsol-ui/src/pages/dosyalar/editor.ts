// The text editor (DD-249): the CodeMirror bundle the console already ships (Data/console/duzenleyici.js,
// served at /duzenleyici.js from the same origin, so the CSP's script-src 'self' allows it). It is loaded on
// the first file opened, with a <script> element, and used through window.KonsolEditor only. A failed load
// is not kept: the next file tries again, and the page shows the file read-only meanwhile.

export interface EditorHandle {
  text(): string;
  dirty(): boolean;
  /** After a save: the current text is the new clean state. */
  markSaved(): void;
  focus(): void;
  destroy(): void;
}

export interface EditorOptions {
  doc: string;
  name: string;
  label: string;
  onChange(dirty: boolean): void;
  onCursor(line: number, column: number): void;
  onSave(): void;
}

export interface KonsolEditor {
  /** The language the editor picks for a file name ("YAML", "Kabuk", "Düz metin"). */
  language(name: string): string;
  create(parent: HTMLElement, options: EditorOptions): EditorHandle;
}

declare global {
  interface Window {
    KonsolEditor?: KonsolEditor;
  }
}

const SRC = "/duzenleyici.js";
let loading: Promise<KonsolEditor> | null = null;

export function loadEditor(): Promise<KonsolEditor> {
  if (window.KonsolEditor) return Promise.resolve(window.KonsolEditor);
  loading ??= new Promise<KonsolEditor>((resolve, reject) => {
    const script = document.createElement("script");
    script.src = SRC;
    const fail = () => {
      loading = null;
      script.remove();
      reject(new Error("Düzenleyici yüklenemedi."));
    };
    script.addEventListener("load", () => (window.KonsolEditor ? resolve(window.KonsolEditor) : fail()));
    script.addEventListener("error", fail);
    document.head.append(script);
  });
  return loading;
}
