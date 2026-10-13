// What a page tells the shell's page head (App.vue): its own title (an application's name), a description
// that replaces the section's (Uygulamalar' summary line) and, for a page below a section, the trail back
// to it. A page sets these while it is shown; the shell falls back to the section's title and description.
import { onBeforeUnmount, reactive, watchEffect } from "vue";

export interface Crumb {
  label: string;
  to: string;
}

export interface PageHead {
  title: string | null;
  description: string | null;
  /** When set, the head shows "parent › title" and the page renders its own <h1>. */
  parent: Crumb | null;
}

export const pageHead = reactive<PageHead>({ title: null, description: null, parent: null });

export function usePageHead(read: () => Partial<PageHead>): void {
  const stop = watchEffect(() => {
    const next = read();
    pageHead.title = next.title ?? null;
    pageHead.description = next.description ?? null;
    pageHead.parent = next.parent ?? null;
  });
  onBeforeUnmount(() => {
    stop();
    pageHead.title = null;
    pageHead.description = null;
    pageHead.parent = null;
  });
}
