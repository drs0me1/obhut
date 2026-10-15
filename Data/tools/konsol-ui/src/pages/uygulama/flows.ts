// Small pieces the add flows and the application page's settings share: a query parameter as text (the
// flows are opened over Uygulamalar with ?ekle=… and the parameters beside it) and an error's words.
import { computed, type ComputedRef } from "vue";
import { useRoute } from "vue-router";

export function useQueryText(name: string): ComputedRef<string> {
  const route = useRoute();
  return computed(() => {
    const value = route.query[name];
    const text = Array.isArray(value) ? value[0] : value;
    return typeof text === "string" ? text : "";
  });
}

/** The backend's or the browser's message of an error, as the page shows it. */
export const message = (err: unknown): string => (err instanceof Error ? err.message : String(err));
