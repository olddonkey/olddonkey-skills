import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
// Global theme styles — loaded here so BOTH the audience window and the
// presenter window (?presenter) render with identical styling / source order.
// tokens.css MUST come after base.css so theme personality tokens win.
import "./styles/fonts.css"; // Google Fonts for built-in themes
import "./styles/base.css";
import "./styles/tokens.css"; // active theme — see THEMES.md
import "./styles/animations.css";
import App from "./App";
import PresenterApp from "./PresenterApp";

// `?presenter` opens the speaker console in its own window; everything else is
// the audience deck. The two stay in sync over a BroadcastChannel (useStepper).
const isPresenter = new URLSearchParams(window.location.search).has("presenter");

createRoot(document.getElementById("root")!).render(
  <StrictMode>{isPresenter ? <PresenterApp /> : <App />}</StrictMode>,
);
