import type { StepNote } from "../../registry/types";

/**
 * Per-step speaker notes for this chapter (presenter talking points).
 *
 * Length === number of steps the chapter component renders.
 * Index i === the note shown in the presenter overlay for `step === i`.
 *
 * ★ This array is the SINGLE SOURCE OF TRUTH for the chapter's step count.
 *   The largest N in the chapter's `if (step === N)` + 1 MUST equal
 *   notes.length — keep them in sync.
 *
 * Notes are NEVER rendered on the slide — they only show in the presenter
 * overlay (press "N" while presenting). Empty string ("") = no note for
 * that step (it still counts as a step).
 */
export const notes: StepNote[] = [
  // step 0 — magazine cover
  "开场白：这一步你想说的话写在这里。按 N 在放映时看到，观众 / 投屏看不到。",
  // step 1 — split layout
  "第二步。数组每个元素对应章节里 step === N 的那一屏，长度必须 = step 数。",
  // step 2 — pull-quote close
  "第三步。这个数组是 step 数的唯一真相源 —— 和章节代码永远不会漂。",
];
