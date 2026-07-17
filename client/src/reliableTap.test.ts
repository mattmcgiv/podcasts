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

    button.click();
    expect(activations).toBe(1);
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
