import { createRoot } from "react-dom/client";
import { App } from "./App";
import { APP_NAME } from "./config";
import { PodsLifecycleBoundary } from "./PodsLifecycleBoundary";
import { installReliableTapActivation } from "./reliableTap";
import "./styles.css";
import { bootstrapOffline } from "./offline/bootstrap";

document.title = APP_NAME;
installReliableTapActivation(document);
void bootstrapOffline().catch(error => {
  console.warn("Offline setup unavailable", error instanceof Error ? error.message : "Unknown error");
}).finally(() => createRoot(document.getElementById("root")!).render(
  <PodsLifecycleBoundary>
    <App />
  </PodsLifecycleBoundary>,
));
