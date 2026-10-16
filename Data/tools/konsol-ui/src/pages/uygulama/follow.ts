// Following the job a request just started, in the live "islemler" topic: a container operation, by the
// id its reply named (every operation has its own).
import { watch } from "vue";
import { live } from "../../live";
import type { Islem } from "../../api/sema";

export class JobLost extends Error {}

/** Resolves with the job once it ends ("tamam" or "hata"); `progress` gets each running step. `stop()`
    gives up quietly (the page went away); after `ms` without an end it rejects. */
export function followJob(
  tur: Islem["tur"],
  id: string,
  progress: (job: Islem) => void = () => undefined,
  ms = 15 * 60_000,
): { done: Promise<Islem>; stop: () => void } {
  let stopWatch: (() => void) | null = null;
  let timer = 0;
  let finished = false;
  const end = () => {
    finished = true;
    clearTimeout(timer);
    stopWatch?.();
  };
  const done = new Promise<Islem>((resolve, reject) => {
    timer = window.setTimeout(() => {
      end();
      reject(new JobLost("İşlemin sonu görülemedi; İşlemler'den bakın."));
    }, ms);
    stopWatch = watch(
      () => (live.islemler ?? []).find((j) => j.tur === tur && j.id === id),
      (job) => {
        if (finished || !job) return;
        if (job.durum === "calisiyor") {
          progress(job);
          return;
        }
        end();
        resolve(job);
      },
      { immediate: true },
    );
    if (finished) stopWatch();
  });
  return { done, stop: end };
}
