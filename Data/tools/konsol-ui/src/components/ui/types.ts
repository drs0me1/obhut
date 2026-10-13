// Shared vocabulary of the base components (DD-258 goal 5: one implementation per component).

/** A status colour: the pill, an access chip, a problem row. */
export type Tone = "ok" | "warning" | "danger" | "accent" | "neutral";

export interface TabItem {
  id: string;
  label: string;
}
