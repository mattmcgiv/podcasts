import { useState } from "react";

/** Square artwork with a quiet fallback block when the URL is missing/broken. */
export function Artwork({ src, size, alt = "" }: { src: string; size: number; alt?: string }) {
  const [broken, setBroken] = useState(false);
  if (!src || broken) {
    return <div className="art art-fallback" style={{ width: size, height: size }} aria-hidden />;
  }
  return (
    <img
      className="art"
      src={src}
      width={size}
      height={size}
      alt={alt}
      loading="lazy"
      onError={() => setBroken(true)}
    />
  );
}
