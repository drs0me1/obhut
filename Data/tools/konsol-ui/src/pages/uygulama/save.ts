// Saving a container's settings (DD-211): POST /api/konsol/konteynerler/islem, then its job followed in the
// live jobs to its end. A 409 that says the settings changed meanwhile is a stale revision: the page offers
// the current definition instead of resending. The editors on an application's Ayarlar share this.
import { onBeforeUnmount, ref } from "vue";
import { ApiError } from "../../api/http";
import { startContainerAction } from "../../api/podman";
import { refreshApps } from "../../live";
import { followJob } from "./follow";
import { message } from "./flows";

export function useContainerSave() {
  const state = ref<"" | "sending" | "running" | "failed">("");
  const step = ref("");
  const error = ref("");
  const stale = ref(false);
  let following: { stop: () => void } | null = null;

  function stop(): void {
    following?.stop();
    following = null;
  }

  function clear(): void {
    stop();
    state.value = "";
    step.value = "";
    error.value = "";
    stale.value = false;
  }

  /** True once the job is done; otherwise the reason is in `error` (and `stale` for a changed revision). */
  async function send(request: Record<string, unknown>, first: string): Promise<boolean> {
    if (state.value === "sending" || state.value === "running") return false;
    state.value = "sending";
    error.value = "";
    stale.value = false;
    let id = "";
    try {
      id = (await startContainerAction(request)).id;
    } catch (err) {
      state.value = "";
      error.value = message(err);
      stale.value = err instanceof ApiError && err.status === 409 && /değiş/i.test(error.value);
      return false;
    }
    state.value = "running";
    step.value = first;
    void refreshApps();
    const f = followJob("konteyner", id, (job) => {
      if (job.adim) step.value = job.adim;
    });
    following = f;
    try {
      const job = await f.done;
      following = null;
      if (job.durum === "hata") {
        state.value = "failed";
        error.value = job.adim ? `Uygulanamadı: ${job.adim}` : "Uygulanamadı.";
        return false;
      }
    } catch (err) {
      following = null;
      state.value = "failed";
      error.value = message(err);
      return false;
    }
    state.value = "";
    void refreshApps();
    return true;
  }

  onBeforeUnmount(stop);
  return { state, step, error, stale, send, clear };
}
