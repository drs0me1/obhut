// A job followed through İşlemler (live.islemler): an application's (tur "uygulama": an install, a lifecycle action,
// a definition change, a removal) or Podman's cleanup (tur "konteyner"): its steps while it runs, and its end
// once — finished or failed, or gone from the list after it was seen running (it ended a while ago). A job not
// listed yet is waited for.
import { watch } from "vue";
import { live } from "../../live";
import type { Islem } from "../../api/sema";

/** Calls `step` with each running state and `done` once at the end (null: it ended unseen); returns the stop. */
export function watchJob(id: string, done: (job: Islem | null) => void, step?: (job: Islem) => void, tur: Islem["tur"] = "uygulama"): () => void {
  let seen = false;
  let ended = false;
  const stop = watch(
    () => live.islemler,
    (jobs) => {
      if (ended || !jobs) return;
      const job = jobs.find((j) => j.tur === tur && j.id === id);
      if (job?.durum === "calisiyor") {
        seen = true;
        step?.(job);
        return;
      }
      if (!job && !seen) return;
      ended = true;
      queueMicrotask(() => stop());
      done(job ?? null);
    },
    { immediate: true },
  );
  return () => {
    ended = true;
    stop();
  };
}
