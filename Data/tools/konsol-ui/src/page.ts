// What a page tells the shell's page head (App.vue): its own title (an application's name), a description
// that replaces the section's (Uygulamalar' summary line), for a page below a section the trail back to it and,
// for a page other sections link into (Dosyalar from an application's Depolama), the back and home buttons
// before its title. A page sets these while it is shown; the shell falls back to the section's title and description.
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
  /** "Geri" (the page before, when there is one) and "Genel Bakış" before the title. */
  nav: boolean;
}

export const pageHead = reactive<PageHead>({ title: null, description: null, parent: null, nav: false });

export function usePageHead(read: () => Partial<PageHead>): void {
  const stop = watchEffect(() => {
    const next = read();
    pageHead.title = next.title ?? null;
    pageHead.description = next.description ?? null;
    pageHead.parent = next.parent ?? null;
    pageHead.nav = next.nav ?? false;
  });
  onBeforeUnmount(() => {
    stop();
    pageHead.title = null;
    pageHead.description = null;
    pageHead.parent = null;
    pageHead.nav = false;
  });
}
