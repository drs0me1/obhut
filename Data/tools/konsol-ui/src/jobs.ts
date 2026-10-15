// Waiting for a background job the page started (a container save of the Yayınla flow, DD-211): the job
// appears in the live "islemler" topic (or GET /api/konsol/etkinlik while polling) and stays listed for
// 120 s after it ends, so its end is seen even when it was quick.
import { watch } from "vue";
import { live } from "./live";
import type { Islem } from "./api/sema";

export class JobTimeout extends Error {}

/** Resolves with the job once it is no longer running ("tamam" or "hata"); `progress` gets each running
    step. Rejects after `ms` without an end. */
export function waitForJob(tur: Islem["tur"], id: string, progress: (job: Islem) => void = () => undefined, ms = 15 * 60_000): Promise<Islem> {
  return new Promise((resolve, reject) => {
    let stop: (() => void) | null = null;
    let finished = false;
    const timer = window.setTimeout(() => {
      finish();
      reject(new JobTimeout("İşlemin sonu görülemedi; İşlemler'den bakın."));
    }, ms);
    function finish(): void {
      finished = true;
      clearTimeout(timer);
      stop?.();
    }
    stop = watch(
      () => (live.islemler ?? []).find((j) => j.tur === tur && j.id === id),
      (job) => {
        if (finished || !job) return;
        if (job.durum === "calisiyor") {
          progress(job);
          return;
        }
        finish();
        resolve(job);
      },
      { immediate: true },
    );
    if (finished) stop();
  });
}
