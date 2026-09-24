import { useState } from "react";

/** Square artwork with a quiet fallback block when the URL is missing/broken. */
export function Artwork({ src, size, alt = "", article = false }: { src: string; size: number; alt?: string; article?: boolean }) {
  const [brokenSrc, setBrokenSrc] = useState<string | null>(null);
  if (!src || brokenSrc === src) {
    return <div className={`art art-fallback${article ? " art-article" : ""}`} style={{ width: size, height: size }} aria-hidden />;
  }
  return (
    <img
      className="art"
      src={src}
      width={size}
      height={size}
      alt={alt}
      loading="lazy"
      onError={() => setBrokenSrc(src)}
    />
  );
}
