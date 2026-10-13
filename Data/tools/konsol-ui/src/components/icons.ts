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
