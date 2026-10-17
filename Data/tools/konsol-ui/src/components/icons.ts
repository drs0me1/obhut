// One icon set (DD-258): 24-unit stroke icons drawn inline (no icon font, no image requests), from the
// approved prototype. Rendered with h() so the markup never goes through innerHTML.
import { h, type FunctionalComponent, type PropType } from "vue";

type Shape =
  | { d: string }
  | { cx: number; cy: number; r: number }
  | { x: number; y: number; width: number; height: number; rx: number };

interface IconDef {
  shapes: Shape[];
  filled?: boolean;
}

const ICONS = {
  home: { shapes: [{ d: "M3.5 11 12 4l8.5 7" }, { d: "M6 9.5V20h12V9.5" }] },
  apps: {
    shapes: [
      { x: 4, y: 4, width: 6.5, height: 6.5, rx: 1.6 },
      { x: 13.5, y: 4, width: 6.5, height: 6.5, rx: 1.6 },
      { x: 4, y: 13.5, width: 6.5, height: 6.5, rx: 1.6 },
      { x: 13.5, y: 13.5, width: 6.5, height: 6.5, rx: 1.6 },
    ],
  },
  globe: {
    shapes: [
      { cx: 12, cy: 12, r: 8.5 },
      { d: "M3.5 12h17" },
      { d: "M12 3.5c2.4 2.5 3.6 5.3 3.6 8.5s-1.2 6-3.6 8.5c-2.4-2.5-3.6-5.3-3.6-8.5s1.2-6 3.6-8.5z" },
    ],
  },
  folder: { shapes: [{ d: "M3.5 7.5a2 2 0 0 1 2-2h4l2 2.2h7a2 2 0 0 1 2 2V17.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z" }] },
  server: {
    shapes: [
      { x: 4, y: 4, width: 16, height: 6.5, rx: 1.6 },
      { x: 4, y: 13.5, width: 16, height: 6.5, rx: 1.6 },
      { d: "M7.5 7.25h.01" },
      { d: "M7.5 16.75h.01" },
    ],
  },
  sliders: {
    shapes: [
      { d: "M4 7h10" },
      { d: "M18 7h2" },
      { cx: 16, cy: 7, r: 2 },
      { d: "M4 17h4" },
      { d: "M12 17h8" },
      { cx: 10, cy: 17, r: 2 },
    ],
  },
  search: { shapes: [{ cx: 11, cy: 11, r: 6.5 }, { d: "m16 16 4 4" }] },
  alert: { shapes: [{ d: "M12 4 2.8 19.5h18.4z" }, { d: "M12 10v4.5" }, { d: "M12 17.2h.01" }] },
  check: { shapes: [{ cx: 12, cy: 12, r: 8.5 }, { d: "m8.5 12.2 2.4 2.4 4.8-5" }] },
  unknown: { shapes: [{ cx: 12, cy: 12, r: 8.5 }, { d: "M8.5 12h7" }] },
  pulse: { shapes: [{ d: "M3 12h4l2.5-6 5 12 2.5-6h4" }] },
  clock: { shapes: [{ cx: 12, cy: 12, r: 8.5 }, { d: "M12 7.5V12l3 2" }] },
  close: { shapes: [{ d: "M6.5 6.5l11 11" }, { d: "M17.5 6.5l-11 11" }] },
  open: {
    shapes: [
      { d: "M14 5h5v5" },
      { d: "M19 5l-8 8" },
      { d: "M18 13.5V18a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h4.5" },
    ],
  },
  box: { shapes: [{ d: "M4 8l8-4 8 4v8l-8 4-8-4z" }, { d: "M4 8l8 4 8-4" }, { d: "M12 12v8" }] },
  theme: { shapes: [{ d: "M20 14.6A8.5 8.5 0 0 1 9.4 4a8.5 8.5 0 1 0 10.6 10.6z" }] },
  more: { filled: true, shapes: [{ cx: 5.5, cy: 12, r: 1.8 }, { cx: 12, cy: 12, r: 1.8 }, { cx: 18.5, cy: 12, r: 1.8 }] },
  xcircle: { shapes: [{ cx: 12, cy: 12, r: 8.5 }, { d: "m9.2 9.2 5.6 5.6" }, { d: "m14.8 9.2-5.6 5.6" }] },
  chevron: { shapes: [{ d: "m9 6 6 6-6 6" }] },
  plus: { shapes: [{ d: "M12 5v14" }, { d: "M5 12h14" }] },
  refresh: { shapes: [{ d: "M19.5 12a7.5 7.5 0 1 1-2.2-5.3" }, { d: "M19.5 4.5v4h-4" }] },
  stop: { shapes: [{ x: 7, y: 7, width: 10, height: 10, rx: 1.5 }] },
  play: { shapes: [{ d: "M8 5.5v13l10.5-6.5z" }] },
  update: { shapes: [{ d: "M12 15V4" }, { d: "m7.5 8.5 4.5-4.5 4.5 4.5" }, { d: "M5 19.5h14" }] },
  trash: { shapes: [{ d: "M4.5 7h15" }, { d: "M9.5 7V4.5h5V7" }, { d: "M6.5 7l1 12.5h9l1-12.5" }] },
  download: { shapes: [{ d: "M12 4v11" }, { d: "m7.5 10.5 4.5 4.5 4.5-4.5" }, { d: "M5 19.5h14" }] },
  shield: { shapes: [{ d: "M12 3.5 5 6v5.5c0 4.2 3 7.6 7 9 4-1.4 7-4.8 7-9V6z" }] },
  share: {
    shapes: [
      { cx: 6.5, cy: 12, r: 2.5 },
      { cx: 17.5, cy: 6, r: 2.5 },
      { cx: 17.5, cy: 18, r: 2.5 },
      { d: "m8.7 10.8 6.6-3.6" },
      { d: "m8.7 13.2 6.6 3.6" },
    ],
  },
  tailnet: {
    shapes: [
      { cx: 6, cy: 6, r: 2 },
      { cx: 18, cy: 6, r: 2 },
      { cx: 12, cy: 18, r: 2 },
      { d: "M8 6h8" },
      { d: "m7 8 4 8" },
      { d: "m17 8-4 8" },
    ],
  },
  lines: { shapes: [{ d: "M5 7h14" }, { d: "M5 12h14" }, { d: "M5 17h9" }] },
  info: { shapes: [{ cx: 12, cy: 12, r: 8.5 }, { d: "M12 11v5" }, { d: "M12 7.8h.01" }] },
  lock: { shapes: [{ x: 5.5, y: 10.5, width: 13, height: 9, rx: 2 }, { d: "M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5" }] },
  pencil: { shapes: [{ d: "M4.5 19.5l1-4L15.8 5.2a1.8 1.8 0 0 1 2.5 0l.5.5a1.8 1.8 0 0 1 0 2.5L8.5 18.5z" }, { d: "M13.5 7.5l3 3" }] },
  qr: {
    shapes: [
      { x: 4, y: 4, width: 6, height: 6, rx: 1 },
      { x: 14, y: 4, width: 6, height: 6, rx: 1 },
      { x: 4, y: 14, width: 6, height: 6, rx: 1 },
      { d: "M14 14h2.5v2.5H14z" },
      { d: "M18.5 18.5H20V20h-1.5z" },
      { d: "M14 19.5h2" },
      { d: "M19.5 14v2" },
    ],
  },
  key: { shapes: [{ cx: 8, cy: 15.5, r: 3.5 }, { d: "M10.5 13 19 4.5" }, { d: "M16 7.5l2.5 2.5" }] },
  power: { shapes: [{ d: "M12 4v7" }, { d: "M7.5 6.8a7 7 0 1 0 9 0" }] },
  copy: { shapes: [{ x: 8.5, y: 8.5, width: 11, height: 11, rx: 2 }, { d: "M15.5 8.5V6.5a2 2 0 0 0-2-2h-7a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h2" }] },
  eye: { shapes: [{ d: "M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z" }, { cx: 12, cy: 12, r: 3 }] },
  eyeOff: { shapes: [{ d: "M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z" }, { cx: 12, cy: 12, r: 3 }, { d: "M4 4l16 16" }] },
  // Dosyalar (phase 4b): a file, an upload, moving into a folder, restoring from the trash, a new name.
  file: { shapes: [{ d: "M7 3.5h7l4.5 4.5v11a1.5 1.5 0 0 1-1.5 1.5H7a1.5 1.5 0 0 1-1.5-1.5v-14A1.5 1.5 0 0 1 7 3.5z" }, { d: "M14 3.5V8h4.5" }] },
  upload: { shapes: [{ d: "M12 16V5" }, { d: "m7.5 9.5 4.5-4.5 4.5 4.5" }, { d: "M5 19.5h14" }] },
  move: {
    shapes: [
      { d: "M3.5 7.5a2 2 0 0 1 2-2h4l2 2.2h7a2 2 0 0 1 2 2V17.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z" },
      { d: "M8.5 13.5h6.5" },
      { d: "m12.5 11 2.5 2.5-2.5 2.5" },
    ],
  },
  restore: { shapes: [{ d: "M4.5 12a7.5 7.5 0 1 0 2.2-5.3" }, { d: "M4.5 4.5v4h4" }] },
  rename: { shapes: [{ d: "M11 7H5.5a1.5 1.5 0 0 0-1.5 1.5v7A1.5 1.5 0 0 0 5.5 17H11" }, { d: "M17 7h1.5A1.5 1.5 0 0 1 20 8.5v7a1.5 1.5 0 0 1-1.5 1.5H17" }, { d: "M14 4.5v15" }, { d: "M12 4.5h4" }, { d: "M12 19.5h4" }] },
} satisfies Record<string, IconDef>;

export type IconName = keyof typeof ICONS;

function shape(s: Shape) {
  if ("d" in s) return h("path", { d: s.d });
  if ("r" in s) return h("circle", { cx: s.cx, cy: s.cy, r: s.r });
  return h("rect", { x: s.x, y: s.y, width: s.width, height: s.height, rx: s.rx });
}

export const Icon: FunctionalComponent<{ name: IconName; size?: number }> = (props) => {
  const def: IconDef = ICONS[props.name];
  const size = props.size ?? 20;
  return h(
    "svg",
    {
      class: "icon",
      width: size,
      height: size,
      viewBox: "0 0 24 24",
      fill: def.filled ? "currentColor" : "none",
      stroke: def.filled ? "none" : "currentColor",
      "stroke-width": 1.8,
      "stroke-linecap": "round",
      "stroke-linejoin": "round",
      "aria-hidden": "true",
      focusable: "false",
    },
    def.shapes.map(shape),
  );
};
Icon.props = { name: { type: String as PropType<IconName>, required: true }, size: { type: Number, required: false } };
Icon.displayName = "Icon";
