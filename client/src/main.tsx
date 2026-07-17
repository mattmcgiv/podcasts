import { createRoot } from "react-dom/client";
import { App } from "./App";
import { APP_NAME } from "./config";
import { installReliableTapActivation } from "./reliableTap";
import "./styles.css";

document.title = APP_NAME;
installReliableTapActivation(document);
createRoot(document.getElementById("root")!).render(<App />);
