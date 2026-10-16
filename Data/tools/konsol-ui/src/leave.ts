// Leaving with an unsaved draft (DD-266): while a page holds a draft, closing or reloading the browser
// tab asks first. A draft is never saved by leaving; moving to
// another section inside Konsol keeps today's behaviour (the draft is dropped with its page).
import { onBeforeUnmount, watch, type WatchSource } from "vue";

const drafts = new Set<symbol>();

function onLeave(event: BeforeUnloadEvent): void {
  if (!drafts.size) return;
  event.preventDefault();
  event.returnValue = "";
}

/** Call in a page's setup with a getter or ref that is true while the page holds a draft. */
export function useLeaveGuard(dirty: WatchSource<boolean>): void {
  const key = Symbol("taslak");
  const set = (on: boolean) => {
    const had = drafts.size > 0;
    if (on) drafts.add(key);
    else drafts.delete(key);
    if (!had && drafts.size) window.addEventListener("beforeunload", onLeave);
    if (had && !drafts.size) window.removeEventListener("beforeunload", onLeave);
  };
  watch(dirty, (on) => set(Boolean(on)), { immediate: true });
  onBeforeUnmount(() => set(false));
}
