import { useRef } from "react";
import { useFitScale } from "../hooks/useFitScale";
import { CHAPTERS } from "../registry/chapters";

interface Props {
  chapterIndex: number;
  step: number;
}

/**
 * A live, non-interactive miniature of the actual slide — renders the real
 * chapter component (same theme CSS, same reveal state) inside a scaled
 * 1920×1080 frame. Used in the presenter view so the speaker sees exactly
 * what the audience window is showing.
 *
 * Only ONE instance lives in the presenter document (the current slide), so
 * there is no risk of duplicate-SVG-id collisions with the audience window —
 * that's a different document.
 */
export function SlidePreview({ chapterIndex, step }: Props) {
  const boxRef = useRef<HTMLDivElement>(null);
  const scale = useFitScale(boxRef);
  const ch = CHAPTERS[chapterIndex];
  if (!ch) return <div ref={boxRef} className="pv-preview-box" />;
  const Cmp = ch.Component;
  return (
    <div ref={boxRef} className="pv-preview-box">
      <div
        className="pv-preview-fitter"
        style={{ width: 1920 * scale, height: 1080 * scale }}
      >
        <div
          className="stage-frame pv-preview-frame"
          style={{ transform: `scale(${scale})` }}
        >
          <div className="scene">
            <Cmp step={step} />
          </div>
        </div>
      </div>
    </div>
  );
}
