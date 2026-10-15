// Following the job a request just started, in the live "islemler" topic: a container operation (its own
// id) or an App Store package's engine job (the package's id). A finished job of an earlier operation on
// the same package stays listed for 120 s and is not this one's end: the job counts once it has been seen
// running or once its end time differs from the one listed before the request.
import { watch } from "vue";
import { live } from "../../live";
import type { Islem } from "../../api/sema";

export class JobLost extends Error {}

/** The end time of a finished job listed now (null when none): call it before sending the request. */
export function listedEnd(tur: Islem["tur"], id: string): number | null {
  const job = (live.islemler ?? []).find((j) => j.tur === tur && j.id === id);
  return job && job.durum !== "calisiyor" ? (job.bitis ?? 0) : null;
}

/** Resolves with the job once it ends ("tamam" or "hata"); `progress` gets each running step. `stop()`
    gives up quietly (the page went away); after `ms` without an end it rejects. */
export function followJob(
  tur: Islem["tur"],
  id: string,
  before: number | null,
  progress: (job: Islem) => void = () => undefined,
  ms = 15 * 60_000,
): { done: Promise<Islem>; stop: () => void } {
  let stopWatch: (() => void) | null = null;
  let timer = 0;
  let finished = false;
  let seen = false;
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
          seen = true;
          progress(job);
          return;
        }
        if (!seen && before !== null && (job.bitis ?? 0) === before) return;
        end();
        resolve(job);
      },
      { immediate: true },
    );
    if (finished) stopWatch();
  });
  return { done, stop: end };
}
