import { createRoot } from "react-dom/client";
import { App } from "./App";
import { APP_NAME } from "./config";
import "./styles.css";

document.title = APP_NAME;
createRoot(document.getElementById("root")!).render(<App />);
