// View state in the URL (DD-258 goal 7): a tab, a filter, a search or an open detail is a query parameter
// of the hash route, so a reload, a shared link or Back shows the same view. The default value is left out
// of the URL. Changes replace the current history entry (a view is not a new page).
import { computed, type WritableComputedRef } from "vue";
import { useRoute, useRouter, type LocationQuery, type LocationQueryRaw, type Router } from "vue-router";

function first(query: LocationQuery | LocationQueryRaw, name: string): string | null {
  const value = query[name];
  const text = Array.isArray(value) ? value[0] : value;
  return typeof text === "string" ? text : null;
}

// The query the last change asked for, until the router has moved there: two changes in a row (clearing the
// search and the filter at once) build on each other instead of on the address the router still shows.
let intended: LocationQueryRaw | null = null;

function base(router: Router): LocationQueryRaw {
  return intended ?? router.currentRoute.value.query;
}

/** Sets query parameters of the current page (null removes one). */
export function updateQuery(router: Router, changes: Record<string, string | null>): void {
  const query: LocationQueryRaw = { ...base(router) };
  for (const [name, value] of Object.entries(changes)) {
    if (value === null) delete query[name];
    else query[name] = value;
  }
  intended = query;
  const settle = () => {
    if (intended === query) intended = null;
  };
  router.replace({ query }).then(settle, settle);
}

/** A query parameter limited to `allowed` (any text when null), `fallback` when absent or not allowed. */
export function useQueryParam<T extends string>(name: string, allowed: readonly T[] | null, fallback: T): WritableComputedRef<T> {
  const route = useRoute();
  const router = useRouter();
  return computed<T>({
    get() {
      const value = first(route.query, name);
      if (value === null) return fallback;
      if (allowed && !(allowed as readonly string[]).includes(value)) return fallback;
      return value as T;
    },
    set(value) {
      const next = value === fallback ? null : value;
      if (first(base(router), name) === next) return;
      updateQuery(router, { [name]: next });
    },
  });
}

/** A yes/no query parameter ("1" when on). */
export function useQueryFlag(name: string): WritableComputedRef<boolean> {
  const value = useQueryParam<"" | "1">(name, ["", "1"], "");
  return computed({
    get: () => value.value === "1",
    set: (on) => (value.value = on ? "1" : ""),
  });
}
