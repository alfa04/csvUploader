import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { Amplify } from "aws-amplify";
import { amplifyConfig } from "./aws-config";
import App from "./App";
// Imported last so its :root overrides win the cascade against Amplify's own default theme
// (imported inside App.tsx, which is evaluated above).
import "./index.css";

Amplify.configure(amplifyConfig);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
