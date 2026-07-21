import { PresenterView } from "./components/PresenterView";
import { useStepper } from "./hooks/useStepper";
import { CHAPTERS } from "./registry/chapters";

/**
 * Mounted at `?presenter` (a separate window) — the speaker's private console.
 * Runs the SAME stepper as the audience window; the BroadcastChannel sync in
 * useStepper keeps the two cursors locked together. Share ONLY the audience
 * window in the call; keep this one to yourself.
 */
export default function PresenterApp() {
  const stepper = useStepper(CHAPTERS);
  return <PresenterView stepper={stepper} />;
}
