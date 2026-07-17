const CONTROL_SELECTOR = [
  "button",
  "a[href]",
  'input[type="checkbox"]',
  'input[type="radio"]',
  '[role="button"]',
  '[role="switch"]',
].join(",");

const MAX_TAP_MOVEMENT_PX = 12;
const DUPLICATE_CLICK_WINDOW_MS = 750;

type TapSession = {
  pointerId: number;
  control: HTMLElement;
  startX: number;
  startY: number;
};

function eligibleControl(target: EventTarget | null): HTMLElement | null {
  if (!(target instanceof Element)) return null;
  const control = target.closest<HTMLElement>(CONTROL_SELECTOR);
  if (!control) return null;
  if (control.matches(":disabled") || control.getAttribute("aria-disabled") === "true") return null;
  return control;
}

/**
 * iOS WebKit can cancel its synthesized click after a valid touch pointerdown
 * when an ancestor participates in scrolling. Activate short, uncancelled touch
 * gestures directly on pointerup, then discard WebKit's delayed duplicate click.
 */
export function installReliableTapActivation(root: Document): () => void {
  let session: TapSession | null = null;
  let activating: HTMLElement | null = null;
  let suppressClick: { control: HTMLElement; until: number } | null = null;

  const onPointerDown = (event: PointerEvent) => {
    if (event.pointerType !== "touch" && event.pointerType !== "pen") return;
    const control = eligibleControl(event.target);
    if (!control) return;
    session = {
      pointerId: event.pointerId,
      control,
      startX: event.clientX,
      startY: event.clientY,
    };
  };

  const onPointerCancel = (event: PointerEvent) => {
    if (session?.pointerId === event.pointerId) session = null;
  };

  const onPointerUp = (event: PointerEvent) => {
    const pending = session;
    session = null;
    if (!pending || pending.pointerId !== event.pointerId) return;
    if (eligibleControl(event.target) !== pending.control) return;
    if (Math.hypot(event.clientX - pending.startX, event.clientY - pending.startY) > MAX_TAP_MOVEMENT_PX) return;

    event.preventDefault();
    activating = pending.control;
    try {
      pending.control.click();
    } finally {
      activating = null;
      suppressClick = {
        control: pending.control,
        until: performance.now() + DUPLICATE_CLICK_WINDOW_MS,
      };
    }
  };

  const onClick = (event: MouseEvent) => {
    const control = eligibleControl(event.target);
    if (!control || control === activating) return;
    if (suppressClick?.control !== control || performance.now() > suppressClick.until) return;
    suppressClick = null;
    event.preventDefault();
    event.stopImmediatePropagation();
  };

  root.addEventListener("pointerdown", onPointerDown, true);
  root.addEventListener("pointerup", onPointerUp, true);
  root.addEventListener("pointercancel", onPointerCancel, true);
  root.addEventListener("click", onClick, true);

  return () => {
    root.removeEventListener("pointerdown", onPointerDown, true);
    root.removeEventListener("pointerup", onPointerUp, true);
    root.removeEventListener("pointercancel", onPointerCancel, true);
    root.removeEventListener("click", onClick, true);
  };
}
