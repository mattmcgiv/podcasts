import { afterEach, describe, expect, it } from "vitest";
import { installReliableTapActivation } from "./reliableTap";

function pointer(target: Element, type: string, x: number, y: number, pointerId = 1) {
  const event = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y });
  Object.defineProperties(event, {
    pointerId: { value: pointerId },
    pointerType: { value: "touch" },
  });
  target.dispatchEvent(event);
}

function delayedTouchClick(target: Element, x: number, y: number) {
  target.dispatchEvent(new MouseEvent("click", {
    bubbles: true,
    cancelable: true,
    clientX: x,
    clientY: y,
    detail: 1,
  }));
}

describe("reliable tap activation", () => {
  let uninstall: (() => void) | undefined;

  afterEach(() => {
    uninstall?.();
    uninstall = undefined;
    document.body.replaceChildren();
  });

  it("activates every button on a guarded touch pointerup and suppresses the later click", () => {
    const button = document.createElement("button");
    document.body.append(button);
    let activations = 0;
    button.addEventListener("click", () => activations++);
    uninstall = installReliableTapActivation(document);

    pointer(button, "pointerdown", 20, 20);
    pointer(button, "pointerup", 22, 21);
    expect(activations).toBe(1);

    delayedTouchClick(button, 22, 21);
    expect(activations).toBe(1);
  });

  it("suppresses a delayed click retargeted to a newly exposed control", () => {
    const first = document.createElement("button");
    const exposed = document.createElement("button");
    document.body.append(first, exposed);
    let firstActivations = 0;
    let exposedActivations = 0;
    first.addEventListener("click", () => {
      firstActivations++;
      first.remove();
    });
    exposed.addEventListener("click", () => exposedActivations++);
    uninstall = installReliableTapActivation(document);

    pointer(first, "pointerdown", 20, 20);
    pointer(first, "pointerup", 20, 20);
    delayedTouchClick(exposed, 20, 20);

    expect(firstActivations).toBe(1);
    expect(exposedActivations).toBe(0);
  });

  it("allows a genuine second touch gesture inside the delayed-click window", () => {
    const first = document.createElement("button");
    const second = document.createElement("button");
    document.body.append(first, second);
    let firstActivations = 0;
    let secondActivations = 0;
    first.addEventListener("click", () => firstActivations++);
    second.addEventListener("click", () => secondActivations++);
    uninstall = installReliableTapActivation(document);

    pointer(first, "pointerdown", 20, 20);
    pointer(first, "pointerup", 20, 20);
    pointer(second, "pointerdown", 20, 20, 2);
    pointer(second, "pointerup", 20, 20, 2);
    // Both synthesized clicks may arrive only after both gestures completed;
    // the first can be retargeted to the newly exposed second button.
    delayedTouchClick(second, 20, 20);
    delayedTouchClick(second, 20, 20);

    expect(firstActivations).toBe(1);
    expect(secondActivations).toBe(1);
  });

  it("preserves an active second gesture when the first delayed click arrives between down and up", () => {
    const first = document.createElement("button");
    const exposed = document.createElement("button");
    document.body.append(first, exposed);
    let firstActivations = 0;
    let exposedActivations = 0;
    first.addEventListener("click", () => {
      firstActivations++;
      first.remove();
    });
    exposed.addEventListener("click", () => exposedActivations++);
    uninstall = installReliableTapActivation(document);

    pointer(first, "pointerdown", 20, 20);
    pointer(first, "pointerup", 20, 20);
    pointer(exposed, "pointerdown", 20, 20, 2);

    // WebKit can deliver the first gesture's retargeted click while the next
    // finger is still down. It must consume only the first gesture's token.
    delayedTouchClick(exposed, 20, 20);
    expect(exposedActivations).toBe(0);

    pointer(exposed, "pointerup", 20, 20, 2);
    expect(exposedActivations).toBe(1);

    delayedTouchClick(exposed, 20, 20);
    expect(firstActivations).toBe(1);
    expect(exposedActivations).toBe(1);
  });

  it("does not suppress keyboard, VoiceOver, or programmatic click activation", () => {
    const button = document.createElement("button");
    document.body.append(button);
    let activations = 0;
    button.addEventListener("click", () => activations++);
    uninstall = installReliableTapActivation(document);

    pointer(button, "pointerdown", 20, 20);
    pointer(button, "pointerup", 20, 20);
    button.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, detail: 0 }));
    button.click();
    // Neither detail-0 activation consumes the outstanding touch token.
    delayedTouchClick(button, 20, 20);

    expect(activations).toBe(3);
  });

  it("does not activate a dragged, cancelled, or disabled control", () => {
    const button = document.createElement("button");
    document.body.append(button);
    let activations = 0;
    button.addEventListener("click", () => activations++);
    uninstall = installReliableTapActivation(document);

    pointer(button, "pointerdown", 10, 10);
    pointer(button, "pointerup", 40, 10);
    pointer(button, "pointerdown", 10, 10, 2);
    pointer(button, "pointercancel", 10, 10, 2);
    pointer(button, "pointerup", 10, 10, 2);
    button.disabled = true;
    pointer(button, "pointerdown", 10, 10, 3);
    pointer(button, "pointerup", 10, 10, 3);

    expect(activations).toBe(0);
  });

  it("also activates checkbox, radio, link, and ARIA button controls", () => {
    const controls = [
      Object.assign(document.createElement("input"), { type: "checkbox" }),
      Object.assign(document.createElement("input"), { type: "radio" }),
      Object.assign(document.createElement("a"), { href: "#test" }),
      Object.assign(document.createElement("div"), { role: "button" }),
    ];
    document.body.append(...controls);
    const activations = controls.map(() => 0);
    controls.forEach((control, index) => control.addEventListener("click", (event) => {
      event.preventDefault();
      activations[index]++;
    }));
    uninstall = installReliableTapActivation(document);

    controls.forEach((control, index) => {
      pointer(control, "pointerdown", index, index, index + 1);
      pointer(control, "pointerup", index, index, index + 1);
    });

    expect(activations).toEqual([1, 1, 1, 1]);
  });
});
