import { useEffect, useState, type RefObject } from "react";

/**
 * Scale a 1920×1080 stage to fit (contain) inside a measured container — used
 * by the presenter view's live slide preview, which renders a real chapter
 * component into a small box. Mirrors useStageScale but measures an ELEMENT
 * (via ResizeObserver) instead of the whole window.
 */
export function useFitScale(
  ref: RefObject<HTMLElement | null>,
  baseW = 1920,
  baseH = 1080,
) {
  const [scale, setScale] = useState(0.1);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      const w = el.clientWidth;
      const h = el.clientHeight;
      if (w > 0 && h > 0) setScale(Math.min(w / baseW, h / baseH));
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, [ref, baseW, baseH]);

  return scale;
}
