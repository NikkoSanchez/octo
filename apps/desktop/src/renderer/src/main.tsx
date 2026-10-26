import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { installScrollbarFade } from "./lib/scrollbars";
import "./styles/global.css";

installScrollbarFade();
createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
