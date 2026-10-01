/** How long to wait for a presented frame before nudging layout. */
export const BLACK_FRAME_WAIT_MS = 400;

let revealGeneration = 0;

/**
 * iPhone WebKit can start the audio clock without attaching a video layer.
 * The picture stays black until the element's presentation size changes
 * (rotating the phone does that). If no frame arrives, shrink the width by
 * one pixel for a frame so WebKit creates the layer.
 */
export function recoverBlackVideo(video: HTMLVideoElement): () => void {
  let presented = false;
  const mark = () => {
    presented = true;
  };
  let frameId: number | undefined;
  if (typeof video.requestVideoFrameCallback === "function") {
    frameId = video.requestVideoFrameCallback(mark);
  }
  const mine = ++revealGeneration;
  const timer = window.setTimeout(() => {
    if (presented || video.paused || video.ended) return;
    const width = video.getBoundingClientRect().width;
    if (width < 2) return;
    const previous = video.style.width;
    video.style.width = `${width - 1}px`;
    requestAnimationFrame(() => {
      if (revealGeneration === mine) video.style.width = previous;
    });
  }, BLACK_FRAME_WAIT_MS);
  return () => {
    presented = true;
    window.clearTimeout(timer);
    if (frameId != null && typeof video.cancelVideoFrameCallback === "function") {
      video.cancelVideoFrameCallback(frameId);
    }
  };
}
