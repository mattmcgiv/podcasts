import { Component, type ReactNode } from "react";
import { postPodsLifecycleEvent } from "./podsLifecycle";

type Props = {
  children: ReactNode;
};

type State = {
  failed: boolean;
};

export class PodsLifecycleBoundary extends Component<Props, State> {
  state: State = { failed: false };

  static getDerivedStateFromError(): State {
    return { failed: true };
  }

  componentDidCatch(): void {
    postPodsLifecycleEvent("ui-failed");
  }

  render(): ReactNode {
    if (!this.state.failed) return this.props.children;

    return (
      <div
        role="alert"
        style={{
          alignItems: "center",
          background: "#f7f7f5",
          boxSizing: "border-box",
          color: "#171716",
          display: "flex",
          fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
          justifyContent: "center",
          minHeight: "100vh",
          padding: "32px 24px",
          textAlign: "center",
        }}
      >
        <div style={{ maxWidth: "320px" }}>
          <h1 style={{ fontSize: "24px", margin: "0 0 12px" }}>Pods couldn’t start</h1>
          <p style={{ fontSize: "16px", lineHeight: 1.5, margin: 0 }}>
            Close and reopen the app. If the problem continues, try again in a moment.
          </p>
        </div>
      </div>
    );
  }
}
